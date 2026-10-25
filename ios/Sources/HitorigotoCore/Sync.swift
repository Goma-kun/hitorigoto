import Foundation
import CryptoKit

/// iCloud 同期の「記録をどう分けて、どう混ぜるか」。CloudKit には触らない（App 側の CloudSync が使う）。
///
/// - 記録はファイル丸ごとではなく **セッション 1 件・表現カード 1 枚ずつ** に分ける。
///   2 台で別々に録音しても、相手の記録を上書きしない
/// - 表現カードは **文言から名前を作る**。2 台で同じ表現を別々に足しても 1 枚にまとまる
/// - 混ぜ方は「どちらの端末で先に混ぜても同じ答え」になるように決める（2 台が言い合いにならない）
public enum Sync {

    public enum Kind: String, Sendable, CaseIterable {
        case session = "Session", phrase = "Phrase", recurring = "Recurring", today = "Today", candidates = "Candidates"
    }

    /// 1 件ぶん。name が CloudKit のレコード名になる
    public struct Item: Equatable, Sendable {
        public var name: String
        public var kind: Kind
        public var data: Data
        public init(name: String, kind: Kind, data: Data) { self.name = name; self.kind = kind; self.data = data }
        /// 送ったものと今の中身が同じかを見るための指紋
        public var hash: String { Sync.hash(data) }
    }

    public static let recurringName = "recurring"
    public static let todayName = "today"
    public static let candidatesName = "candidates"

    public static func name(session id: String) -> String { "s." + id }

    public static func name(phrase text: String) -> String {
        "p." + hash(Data(PhraseLogic.phraseKey(text).utf8)).prefix(32)
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(v)) ?? Data()
    }

    static func decode<T: Decodable>(_ t: T.Type, _ data: Data) -> T? { try? JSONDecoder().decode(t, from: data) }

    // MARK: - 記録 → 送る単位

    /// 今の記録を、送る単位に分ける（名前 → 中身）
    public static func items(_ s: Snapshot) -> [String: Item] {
        var out: [String: Item] = [:]
        for x in s.sessions where !x.id.isEmpty {
            let n = name(session: x.id); out[n] = Item(name: n, kind: .session, data: encode(x))
        }
        for p in s.phrases where !p.phrase.isEmpty {
            let n = name(phrase: p.phrase); out[n] = Item(name: n, kind: .phrase, data: encode(p))
        }
        if !s.recurring.isEmpty { out[recurringName] = Item(name: recurringName, kind: .recurring, data: encode(s.recurring)) }
        if let t = s.today { out[todayName] = Item(name: todayName, kind: .today, data: encode(t)) }
        if !s.candidates.isEmpty { out[candidatesName] = Item(name: candidatesName, kind: .candidates, data: encode(s.candidates)) }
        return out
    }

    // MARK: - 届いたものを混ぜる

    /// 相手の端末から届いた 1 件を、今の記録に混ぜる
    public static func merge(_ snapshot: Snapshot, _ item: Item) -> Snapshot {
        var s = snapshot
        switch item.kind {
        case .session:
            guard let remote = decode(Session.self, item.data), !remote.id.isEmpty else { return s }
            if let i = s.sessions.firstIndex(where: { $0.id == remote.id }) {
                s.sessions[i] = mergeSession(s.sessions[i], remote)
            } else {
                s.sessions.append(remote)
                s.sessions.sort { $0.id > $1.id }
            }
            s.sessions = Logic.foldSessions(s.sessions)
        case .phrase:
            guard let remote = decode(PhraseCard.self, item.data), !remote.phrase.isEmpty else { return s }
            let key = PhraseLogic.phraseKey(remote.phrase)
            if let i = s.phrases.firstIndex(where: { PhraseLogic.phraseKey($0.phrase) == key }) {
                let local = s.phrases[i]
                let merged = mergePhrase(local, remote)
                s.phrases[i] = merged
                if merged.id != local.id { s.today = renameInToday(s.today, from: local.id, to: merged.id) }
            } else {
                s.phrases.append(PhraseLogic.rebuild(remote))
            }
        case .recurring:
            guard let remote = decode([Recurring].self, item.data) else { return s }
            s.recurring = mergeRecurring(s.recurring, remote)
        case .today:
            guard let remote = decode(Today.self, item.data) else { return s }
            s.today = s.today.map { mergeToday($0, remote) } ?? remote
        case .candidates:
            guard let remote = decode([String: CandidateState].self, item.data) else { return s }
            s.candidates = mergeCandidates(s.candidates, remote)
        }
        return s
    }

    /// 相手の端末で消されたものを、こちらでも消す。今日の表現・候補の記録は消さない（消すのは記録の本体だけ）
    public static func remove(_ snapshot: Snapshot, name: String) -> Snapshot {
        var s = snapshot
        if name.hasPrefix("s.") {
            let id = String(name.dropFirst(2))
            s.sessions.removeAll { $0.id == id }
        } else if name.hasPrefix("p."), let card = s.phrases.first(where: { Self.name(phrase: $0.phrase) == name }) {
            s.phrases.removeAll { $0.id == card.id }
            s.today?.ids.removeAll { $0 == card.id }
            s.today?.results.removeValue(forKey: card.id)
        }
        return s
    }

    // MARK: - 混ぜ方（どちらから混ぜても同じ答えになる）

    /// 同じセッション。畳まれた方が勝つ（畳むのは古くなった順で、2 台とも同じところで畳む）。
    /// 「トラさんに詳しく聞く」は直しごとに、やり取りの多い方を残す
    public static func mergeSession(_ a: Session, _ b: Session) -> Session {
        if (a.folded == true) != (b.folded == true) { return a.folded == true ? a : b }
        var x = a, y = b
        x.explains = nil; y.explains = nil
        var out = larger(x, y)
        var threads: [String: ExplainThread] = [:]
        for t in (a.explains ?? []) + (b.explains ?? []) {
            if let cur = threads[t.key] {
                if t.turns.count != cur.turns.count { threads[t.key] = t.turns.count > cur.turns.count ? t : cur }
                else { threads[t.key] = larger(cur, t) }
            } else { threads[t.key] = t }
        }
        out.explains = threads.isEmpty ? (a.explains ?? b.explains) : threads.values.sorted { $0.key < $1.key }
        if out.folded == true { out.explains = nil }
        return out
    }

    /// 同じ表現。練習の記録は 2 台ぶんを合わせる（同じ日の同じ種類は 1 つに決める）。
    /// id は小さい方に揃える（今日の表現が id で指しているので、2 台で同じ id になるように）
    public static func mergePhrase(_ a: PhraseCard, _ b: PhraseCard) -> PhraseCard {
        let first = a.id <= b.id ? a : b
        var c = first
        // 同じ日の「話した結果」と「覚えてますか」はそれぞれ 1 つ（端末の中でもそう扱っている）
        func slot(_ h: PhraseHistory) -> String { h.d + "|" + ((h.r == "rok" || h.r == "rng") ? "recall" : "speech") }
        var bySlot: [String: PhraseHistory] = [:]
        for h in a.history + b.history {
            let k = slot(h)
            if let cur = bySlot[k] { bySlot[k] = larger(cur, h) } else { bySlot[k] = h }
        }
        c.history = bySlot.values.sorted { $0.d != $1.d ? $0.d < $1.d : encode($0).lexicographicallyPrecedes(encode($1)) }
        c.meaning = pickText(a.meaning, b.meaning)
        c.note = pickText(a.note, b.note)
        c.example = pickOptional(a.example, b.example)
        c.image = pickOptional(a.image, b.image)
        let added = [a.added, b.added].filter { !$0.isEmpty }
        c.added = added.min() ?? first.added
        c.manual = [a.manual, b.manual].compactMap { $0 }.max() ?? nil
        c.status = (a.status == "archived" || b.status == "archived") ? "archived" : first.status
        return PhraseLogic.rebuild(c)
    }

    /// よく出る直し。同じ文言は回数の多い方・最後に出た日の新しい方。並びは文言順に揃える
    public static func mergeRecurring(_ a: [Recurring], _ b: [Recurring]) -> [Recurring] {
        var map: [String: Recurring] = [:]
        for r in a + b where !r.text.isEmpty {
            let k = Merge.normKey(r.text)
            guard var cur = map[k] else { map[k] = r; continue }
            if r.text > cur.text { cur.text = r.text }
            cur.count = max(cur.count, r.count)
            if r.lastSeen > cur.lastSeen { cur.lastSeen = r.lastSeen }
            map[k] = cur
        }
        return map.keys.sorted().compactMap { map[$0] }
    }

    /// 今日の表現。新しい日付の方。同じ日なら 2 台ぶんを合わせ、手で直した判定を優先する
    public static func mergeToday(_ a: Today, _ b: Today) -> Today {
        if a.date != b.date { return a.date > b.date ? a : b }
        var ids = a.ids
        for id in b.ids where !ids.contains(id) { ids.append(id) }
        // 並びは「長い方」を基準に（同じ長さなら辞書順で小さい方）。どちらの端末で混ぜても同じ並びになる
        let base = a.ids.count != b.ids.count ? (a.ids.count > b.ids.count ? a.ids : b.ids) : (a.ids.lexicographicallyPrecedes(b.ids) ? a.ids : b.ids)
        ids = base + ids.filter { !base.contains($0) }.sorted()
        var results = a.results
        for (id, r) in b.results {
            guard let cur = results[id] else { results[id] = r; continue }
            if (cur.judge == "manual") != (r.judge == "manual") { results[id] = cur.judge == "manual" ? cur : r }
            else { results[id] = larger(cur, r) }
        }
        return Today(date: a.date, ids: ids, results: results)
    }

    /// 「前に言えなかった表現」の寝かせ・もう出さない。強い方（出さない・長く寝かせる）を残す
    public static func mergeCandidates(_ a: [String: CandidateState], _ b: [String: CandidateState]) -> [String: CandidateState] {
        var out = a
        for (k, r) in b {
            guard let cur = out[k] else { out[k] = r; continue }
            let until = [cur.until, r.until].compactMap { $0 }.max()
            out[k] = CandidateState(until: until, snoozes: max(cur.snoozes, r.snoozes), dismissed: cur.dismissed || r.dismissed)
        }
        return out
    }

    static func renameInToday(_ today: Today?, from: String, to: String) -> Today? {
        guard var t = today else { return nil }
        t.ids = t.ids.reduce(into: [String]()) { acc, id in
            let n = id == from ? to : id
            if !acc.contains(n) { acc.append(n) }
        }
        if let r = t.results.removeValue(forKey: from), t.results[to] == nil { t.results[to] = r }
        return t
    }

    /// 決め手が無いときの決め方。中身を文字にして大きい方（どちらの端末でも同じ方を選ぶため）
    static func larger<T: Encodable>(_ a: T, _ b: T) -> T {
        let x = encode(a), y = encode(b)
        return x.lexicographicallyPrecedes(y) ? b : a
    }

    /// 片方にしか無ければそれ。両方あれば pickText と同じ決め方
    static func pickOptional(_ a: String?, _ b: String?) -> String? {
        let x = a ?? "", y = b ?? ""
        let v = pickText(x, y)
        return v.isEmpty ? nil : v
    }

    static func pickText(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty || a == b { return a }
        if a.count != b.count { return a.count > b.count ? a : b }
        return max(a, b)
    }
}

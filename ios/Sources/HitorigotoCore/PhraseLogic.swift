import Foundation

/// 拡張機能の extension/phrase-core.js をそのまま移した層（表現集と「今日の表現」）。
/// 考え方はそちらの冒頭コメントに書いてある。答えが同じことを ../test/parity_swift_test.mjs が突き合わせる
public enum PhraseLogic {

    public static let graduateHits = 3
    public static let ladderDays = [7, 21]
    public static let missDays = 1
    public static let partialDays = 1
    public static let skipDays = 2
    public static let recallNgDays = 1
    public static let defaultTotal = 5
    public static let defaultNew = 3
    public static let maxPhrases = 2000
    public static let kinds = ["phrase", "word"]
    public static let results = ["hit", "partial", "miss", "skip", "rok", "rng"]

    // MARK: - 日付（'YYYY-MM-DD' の文字列。暦の日数で計算し、時刻・時差の影響を受けない）

    static func ymd(_ s: String) -> (Int, Int, Int) {
        let p = s.split(separator: "-").map { Int($0) ?? 0 }
        return (p.count > 0 ? p[0] : 0, p.count > 1 ? p[1] : 1, p.count > 2 ? p[2] : 1)
    }

    /// 通算日（グレゴリオ暦）。日付の足し引きと差はすべてこれで行う
    static func dayNumber(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let a = (14 - m) / 12
        let yy = y + 4800 - a
        let mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    static func fromDayNumber(_ n: Int) -> String {
        let a = n + 32044
        let b = (4 * a + 3) / 146097
        let c = a - 146097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        let day = e - (153 * m + 2) / 5 + 1
        let month = m + 3 - 12 * (m / 10)
        let year = 100 * b + d - 4800 + m / 10
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func addDays(_ dateStr: String, _ n: Int) -> String {
        let (y, m, d) = ymd(dateStr)
        return fromDayNumber(dayNumber(y, m, d) + n)
    }

    public static func daysBetween(_ from: String, _ to: String) -> Int {
        let (y1, m1, d1) = ymd(from), (y2, m2, d2) = ymd(to)
        return dayNumber(y2, m2, d2) - dayNumber(y1, m1, d1)
    }

    // MARK: - 正規化・作成

    public static func phraseKey(_ text: String) -> String {
        Logic.collapseSpaces(text.lowercased().replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression))
    }

    public static func newId(_ today: String) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return today + "-" + String((0..<6).map { _ in chars.randomElement()! })
    }

    public static func makePhrase(phrase: String, meaning: String = "", kind: String = "phrase", source: String = "manual",
                                  today: String, note: String = "") -> PhraseCard? {
        let p = Logic.collapseSpaces(phrase)
        guard !p.isEmpty else { return nil }
        return PhraseCard(id: newId(today), phrase: p, meaning: meaning.trimmingCharacters(in: .whitespacesAndNewlines),
                          note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                          kind: kinds.contains(kind) ? kind : "phrase", source: source == "issue" ? "issue" : "manual",
                          added: today, due: today, hits: 0, status: "active", history: [])
    }

    /// まとめて追加の 1 行 → (表現, 意味)。区切りは タブ・｜・|・—・–・「 - 」
    public static func parsePhraseLine(_ line: String) -> (phrase: String, meaning: String)? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let re = try! NSRegularExpression(pattern: "^(.+?)(?:\\t+|\\s*[｜|—–]\\s*|\\s+-\\s+)(.+)$", options: [.dotMatchesLineSeparators])
        let ns = s as NSString
        if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            return (ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                    ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces))
        }
        return (s, "")
    }

    public static func parsePhraseLines(_ text: String) -> [(phrase: String, meaning: String)] {
        text.components(separatedBy: .newlines).compactMap { parsePhraseLine($0) }
    }

    /// 既にある表現（同じ文字列）は増やさない
    public static func addPhrases(_ list: [PhraseCard], _ newOnes: [PhraseCard]) -> (list: [PhraseCard], added: Int) {
        var cur = list
        var seen = Set(cur.map { phraseKey($0.phrase) })
        var added = 0
        for p in newOnes {
            let key = phraseKey(p.phrase)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key); cur.append(p); added += 1
        }
        return (cur, added)
    }

    public static func findPhrase(_ list: [PhraseCard], _ text: String) -> PhraseCard? {
        let key = phraseKey(text)
        return list.first { phraseKey($0.phrase) == key }
    }

    // MARK: - 履歴から状態を組み立て直す

    public static func rebuild(_ card: PhraseCard) -> PhraseCard {
        var c = card
        c.history = card.history.sorted { $0.d < $1.d }
        var hits = 0
        var due: String? = c.added.isEmpty ? c.history.first?.d : c.added
        if due?.isEmpty == true { due = c.history.first?.d }
        var status = "active"
        for h in c.history {
            switch h.r {
            case "hit":
                hits += 1
                if hits >= graduateHits { status = "graduated"; due = nil }
                else { due = addDays(h.d, ladderDays[min(hits - 1, ladderDays.count - 1)]) }
            case "partial": due = addDays(h.d, partialDays)
            case "miss": due = addDays(h.d, missDays)
            case "skip": due = addDays(h.d, skipDays)
            case "rok": break
            case "rng":
                if status == "graduated" { status = "active"; hits = graduateHits - 1 }
                due = addDays(h.d, recallNgDays)
            default: break
            }
        }
        if card.manual == "graduated" { status = "graduated"; due = nil }
        if card.manual == "active" && status == "graduated" {
            status = "active"
            if due == nil { due = c.history.last?.d ?? c.added }
        }
        c.hits = hits
        c.due = due
        c.status = card.status == "archived" ? "archived" : status
        return c
    }

    /// その日の独り言の結果を記録する（同じ日は 1 つ。後から直したら置き換える）
    public static func setSpeechResult(_ card: PhraseCard, today: String, result: String, asSaid: String = "") -> PhraseCard {
        guard results.contains(result) else { return card }
        var c = card
        c.history = card.history.filter { !($0.d == today && $0.r != "rok" && $0.r != "rng") }
        c.history.append(PhraseHistory(d: today, r: result, as: asSaid.isEmpty ? nil : asSaid.trimmingCharacters(in: .whitespaces)))
        if card.manual == "graduated" { c.manual = "" }   // JS と同じく空文字で「解除」を表す
        return rebuild(c)
    }

    public static func setRecallResult(_ card: PhraseCard, today: String, ok: Bool) -> PhraseCard {
        var c = card
        c.history = card.history.filter { !($0.d == today && ($0.r == "rok" || $0.r == "rng")) }
        c.history.append(PhraseHistory(d: today, r: ok ? "rok" : "rng"))
        if !ok && card.manual == "graduated" { c.manual = "" }
        return rebuild(c)
    }

    public static func setManualStatus(_ card: PhraseCard, _ status: String, today: String) -> PhraseCard {
        var c = card
        if status == "graduated" { c.manual = "graduated"; return rebuild(c) }
        if status == "active" {
            c.manual = "active"
            var r = rebuild(c)
            if r.due == nil { r.due = today }
            return r
        }
        return card
    }

    public static func speechResults(_ card: PhraseCard) -> [PhraseHistory] {
        card.history.filter { $0.r != "rok" && $0.r != "rng" }
    }

    public static func isNew(_ card: PhraseCard) -> Bool { speechResults(card).isEmpty }

    public static func lastSpeechResult(_ card: PhraseCard) -> String { speechResults(card).last?.r ?? "" }

    // MARK: - 今日の表現を選ぶ

    public static func pickToday(_ list: [PhraseCard], today: String, total: Int = defaultTotal,
                                 maxNew: Int = defaultNew, fixedIds: [String] = []) -> [PhraseCard] {
        let all = list.filter { $0.status == "active" }
        var byId: [String: PhraseCard] = [:]
        for p in all { byId[p.id] = p }
        var picked: [PhraseCard] = []
        var used = Set<String>()
        for id in fixedIds {
            if let p = byId[id], !used.contains(id) { picked.append(p); used.insert(id) }
        }
        func newCount() -> Int { picked.filter(isNew).count }

        let due = all.filter { !used.contains($0.id) && !isNew($0) && $0.due != nil && $0.due! <= today }
        let retry = due.filter { ["miss", "partial"].contains(lastSpeechResult($0)) }
        let retryIds = Set(retry.map { $0.id })
        let rest = due.filter { !retryIds.contains($0.id) }
        let byDue: (PhraseCard, PhraseCard) -> Bool = { a, b in
            if a.due! != b.due! { return a.due! < b.due! }
            return a.added < b.added
        }
        for p in retry.sorted(by: byDue) + rest.sorted(by: byDue) {
            if picked.count >= total { break }
            picked.append(p); used.insert(p.id)
        }
        let fresh = all.filter { !used.contains($0.id) && isNew($0) && $0.due != nil && $0.due! <= today }
            .sorted { a, b in
                if a.added != b.added { return a.added > b.added }
                return a.id > b.id
            }
        for p in fresh {
            if picked.count >= total || newCount() >= maxNew { break }
            picked.append(p); used.insert(p.id)
        }
        return picked
    }

    // MARK: - 独り言の中に表現が出たか

    static let wildcards: Set<String> = ["someone", "somebody", "something", "sb", "sth", "one's", "someone's", "oneself", "sth.", "sb."]
    static let optionals: Set<String> = ["a", "an", "the", "my", "your", "his", "her", "its", "our", "their", "to", "be"]
    static let irregular: [String: String] = [
        "am": "be", "is": "be", "are": "be", "was": "be", "were": "be", "been": "be", "being": "be",
        "has": "have", "had": "have", "did": "do", "done": "do", "does": "do",
        "went": "go", "gone": "go", "goes": "go", "came": "come", "ran": "run", "took": "take", "taken": "take",
        "made": "make", "got": "get", "gotten": "get", "gave": "give", "given": "give", "saw": "see", "seen": "see",
        "knew": "know", "known": "know", "thought": "think", "felt": "feel", "kept": "keep", "told": "tell",
        "said": "say", "paid": "pay", "laid": "lay", "drew": "draw", "drawn": "draw", "spoke": "speak", "spoken": "speak",
        "wrote": "write", "written": "write", "broke": "break", "broken": "break", "brought": "bring", "bought": "buy",
        "caught": "catch", "taught": "teach", "found": "find", "held": "hold", "left": "leave", "lost": "lose",
        "met": "meet", "sat": "sit", "sold": "sell", "sent": "send", "stood": "stand", "understood": "understand",
        "woke": "wake", "wore": "wear", "worn": "wear", "won": "win", "fell": "fall", "fallen": "fall", "flew": "fly",
        "forgot": "forget", "forgotten": "forget", "grew": "grow", "grown": "grow", "hid": "hide", "hidden": "hide",
        "ate": "eat", "eaten": "eat", "began": "begin", "begun": "begin", "chose": "choose", "chosen": "choose",
        "led": "lead", "meant": "mean", "built": "build", "spent": "spend", "slept": "sleep", "threw": "throw", "thrown": "throw",
        "stuck": "stick", "struck": "strike", "shook": "shake", "rose": "rise", "risen": "rise", "sang": "sing", "swam": "swim",
        "became": "become", "forgave": "forgive", "froze": "freeze", "fed": "feed", "bit": "bite", "beat": "beat", "lent": "lend",
        "children": "child", "people": "person", "men": "man", "women": "woman", "feet": "foot", "teeth": "tooth", "mice": "mouse",
    ]

    static func stem(_ word: String) -> String {
        var w = word.lowercased().replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
        w = String(w.unicodeScalars.filter { ($0.value >= 97 && $0.value <= 122) || $0 == "'" }.map { Character($0) })
        if w.isEmpty { return "" }
        if let base = irregular[w] { return base }
        for suf in ["ing", "ed", "es", "s"] {
            if w.count - suf.count >= 3 && w.hasSuffix(suf) { w = String(w.dropLast(suf.count)); break }
        }
        if w.count >= 4 {
            let a = Array(w)
            if a[a.count - 1] == a[a.count - 2] { w = String(w.dropLast()) }
        }
        return w
    }

    static func stemEq(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        if a + "e" == b || b + "e" == a { return true }
        if a + "i" == b || b + "i" == a { return true }
        return false
    }

    struct Tok { var wild = false; var stem = ""; var optional = false }

    /// 表現を照合用トークン列にする。「／」で区切った別形ごとの配列
    static func tokenAlternatives(_ phrase: String) -> [[Tok]] {
        let cleaned = phrase.replacingOccurrences(of: "\\([^)]*\\)|（[^）]*）", with: " ", options: .regularExpression)
        let alts = cleaned.components(separatedBy: CharacterSet(charactersIn: "／/"))
        var out: [[Tok]] = []
        for alt in alts {
            let raw = alt.replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            var toks: [Tok] = []
            for t in raw {
                var low = t.lowercased()
                low = low.replacingOccurrences(of: "^[^a-z〜~…]+|[^a-z'〜~…]+$", with: "", options: .regularExpression)
                if low.isEmpty { continue }
                if wildcards.contains(low) || low.range(of: "[〜~…]", options: .regularExpression) != nil
                    || low.range(of: "^x+$", options: .regularExpression) != nil {
                    toks.append(Tok(wild: true)); continue
                }
                toks.append(Tok(wild: false, stem: stem(low), optional: optionals.contains(low)))
            }
            if toks.contains(where: { !$0.wild && !$0.optional }) { out.append(toks) }
        }
        return out
    }

    /// 本文の語（英字とアポストロフィだけ。n't は not に開く）
    static func textWords(_ text: String) -> [String] {
        let s = text.replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "n't\\b", with: " not", options: [.regularExpression, .caseInsensitive])
        var words: [String] = []
        var cur = ""
        for u in s.unicodeScalars {
            let ok = (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) || u == "'"
            if ok { cur.unicodeScalars.append(u) } else if !cur.isEmpty { words.append(cur); cur = "" }
        }
        if !cur.isEmpty { words.append(cur) }
        return words
    }

    struct Match { var exact: Bool; var start: Int; var end: Int }

    static func matchTokens(_ toks: [Tok], _ stems: [String]) -> Match? {
        var best: Match? = nil
        for start in 0..<max(stems.count, 0) {
            var i = start, ti = 0, gaps = 0, dropped = 0
            var ok = true
            while ti < toks.count {
                let tk = toks[ti]
                if tk.wild {
                    guard let next = toks[(ti + 1)...].first(where: { !$0.wild && !$0.optional }) else { i += 1; ti += 1; continue }
                    var found = -1
                    var k = i
                    while k <= min(stems.count - 1, i + 3) {
                        if stemEq(stems[k], next.stem) { found = k; break }
                        k += 1
                    }
                    if found < 0 { ok = false; break }
                    i = found; ti += 1
                    while ti < toks.count && toks[ti].optional { ti += 1 }
                    continue
                }
                if i >= stems.count { ok = false; break }
                if stemEq(stems[i], tk.stem) { i += 1; ti += 1; continue }
                if tk.optional { dropped += 1; ti += 1; continue }
                if i + 1 < stems.count && stemEq(stems[i + 1], tk.stem) && gaps < 2 { gaps += 1; i += 2; ti += 1; continue }
                if i + 2 < stems.count && stemEq(stems[i + 2], tk.stem) && gaps < 1 { gaps += 2; i += 3; ti += 1; continue }
                ok = false; break
            }
            if !ok { continue }
            let cand = Match(exact: gaps == 0 && dropped == 0, start: start, end: i)
            if best == nil || (cand.exact && !best!.exact) { best = cand }
            if best!.exact { break }
        }
        return best
    }

    public struct Detection: Equatable, Sendable {
        public var used: Bool
        public var exact: Bool
        public var asSaid: String
    }

    public static func detect(_ phrase: String, in text: String) -> Detection {
        let words = textWords(text)
        let stems = words.map(stem)
        var best: Match? = nil
        for toks in tokenAlternatives(phrase) {
            if let m = matchTokens(toks, stems) {
                if best == nil || (m.exact && !best!.exact) { best = m }
            }
            if let b = best, b.exact { break }
        }
        guard let b = best else { return Detection(used: false, exact: false, asSaid: "") }
        let end = min(b.end, words.count)
        return Detection(used: true, exact: b.exact, asSaid: words[b.start..<end].joined(separator: " "))
    }

    public static func judge(_ cards: [PhraseCard], text: String) -> [Judged] {
        cards.map { c in
            let d = detect(c.phrase, in: text)
            return Judged(id: c.id, result: !d.used ? "miss" : (d.exact ? "hit" : "partial"), asSaid: d.asSaid, judge: "auto")
        }
    }

    /// AI が返した targets を優先して重ねる
    public static func mergeAiTargets(_ judged: [Judged], cards: [PhraseCard], aiTargets: [Target]) -> [Judged] {
        guard !aiTargets.isEmpty else { return judged }
        var byKey: [String: String] = [:]
        for c in cards { byKey[phraseKey(c.phrase)] = c.id }
        var out = judged
        for t in aiTargets {
            guard let id = byKey[phraseKey(t.phrase)], let idx = out.firstIndex(where: { $0.id == id }) else { continue }
            out[idx].result = !t.used ? "miss" : (t.exact ? "hit" : "partial")
            out[idx].asSaid = t.used ? (t.asSaid.isEmpty ? out[idx].asSaid : t.asSaid) : ""
            out[idx].note = t.note
            out[idx].judge = "ai"
        }
        return out
    }

    /// AI へ渡す「今日の狙いの表現」の節（無ければ空文字）
    public static func targetsSection(_ cards: [PhraseCard]) -> String {
        let list = cards.filter { !$0.phrase.isEmpty }
        if list.isEmpty { return "" }
        let lines = list.map { "- \($0.phrase)" + ($0.meaning.isEmpty ? "" : "（\($0.meaning)）") }
        return "\n\n## 今日使うと決めていた表現（それぞれ使えたかを \"targets\" で判定してください）\n" + lines.joined(separator: "\n")
    }

    public struct Stats: Equatable, Sendable { public var total, active, fresh, graduated: Int }

    public static func stats(_ list: [PhraseCard]) -> Stats {
        Stats(total: list.count,
              active: list.filter { $0.status == "active" && !isNew($0) }.count,
              fresh: list.filter { $0.status == "active" && isNew($0) }.count,
              graduated: list.filter { $0.status == "graduated" }.count)
    }

    public static func trim(_ list: [PhraseCard], max: Int = maxPhrases) -> [PhraseCard] {
        if list.count <= max { return list }
        let grads = list.filter { $0.status == "graduated" }.sorted { $0.added < $1.added }
        let drop = Set(grads.prefix(list.count - max).map { $0.id })
        return Array(list.filter { !drop.contains($0.id) }.prefix(max))
    }

    public static let markOf: [String: String] = ["hit": "◎", "partial": "△", "miss": "✗", "skip": "−", "rok": "○", "rng": "×"]

    public static func marks(_ card: PhraseCard) -> String {
        card.history.map { markOf[$0.r] ?? "" }.joined()
    }
}

import Foundation

/// 「前に言えなかった表現」の候補（アプリ版だけ。拡張の phrase-core.js には無いので突き合わせの対象外）。
///
/// 考え方（2026-10-15 本人要望・定石は Duolingo の「自分のミスから毎日の復習を組む」）:
///   - 過去の「直すべし」と「英語ならこう」は、表現集に入れなければ二度と出てこなかった。
///     そこで話す画面の最初に、まだ表現集に入っていない直しを数個だけ出し、
///     「今日使ってみる」を選んだものだけ表現集＋今日の表現に入れる（あとは表現集の間隔反復に任せる）
///   - 出す順: 何度も直された（recurring）＞ ちょうど 1・3・7・14・30・60 日前の話（「以前こういう話をしました」）＞ 新しい順
///   - 「今日は使わない」は責めずにしばらく寝かせる（1 回目 3 日・2 回目 7 日・以降 21 日）。
///     「もう出さない」を押したものだけ二度と出さない
public enum Candidates {

    public static let defaultLimit = 4
    public static let lookbackDays = [1, 3, 7, 14, 30, 60]
    public static let snoozeDays = [3, 7, 21]
    /// 長すぎる直し（段落ごと書き直したもの）は、独り言に混ぜる表現にならないので出さない
    public static let maxLength = 90

    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { key }
        /// phraseKey(phrase)。寝かせた記録のキー
        public var key: String
        /// 表現集に入れる形（直した後の英語）
        public var phrase: String
        /// 言ってしまった形（日本語で言ったときはその日本語）
        public var said: String
        public var reason: String
        /// issue（直すべし）| ask（日本語で言った分）
        public var origin: String
        public var kind: String
        /// その直しが出た日（YYYY-MM-DD）
        public var date: String
        /// 何回直されたか（同じ表現が別の日にも出たら数える）
        public var count: Int
    }

    /// セッション id（ISO 日時）→ 端末の暦の日付
    public static func sessionDay(_ id: String) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: id) ?? ISO8601DateFormatter().date(from: id) else { return nil }
        return Logic.todayStamp(d)
    }

    static func clean(_ s: String) -> String { Logic.collapseSpaces(s).trimmingCharacters(in: CharacterSet(charactersIn: " .")) }

    /// 記録全体から候補を集める（同じ表現は 1 つにまとめ、いちばん新しい日の文脈を残す）
    public static func collect(_ sessions: [Session], phrases: [PhraseCard]) -> [Item] {
        var map: [String: Item] = [:]
        func put(_ phrase: String, said: String, reason: String, origin: String, kind: String, date: String) {
            let p = clean(phrase)
            guard !p.isEmpty, p.count <= maxLength else { return }
            guard PhraseLogic.phraseKey(p) != PhraseLogic.phraseKey(clean(said)) else { return }
            guard PhraseLogic.findPhrase(phrases, p) == nil else { return }
            let k = PhraseLogic.phraseKey(p)
            if var cur = map[k] {
                cur.count += 1
                if date > cur.date { cur.date = date; cur.said = said; cur.reason = reason }
                map[k] = cur
            } else {
                map[k] = Item(key: k, phrase: p, said: clean(said), reason: reason, origin: origin, kind: kind, date: date, count: 1)
            }
        }
        for s in sessions where s.folded != true {
            guard let day = sessionDay(s.id) else { continue }
            for it in s.issues {
                guard let orig = it.original, !orig.isEmpty else { continue }
                put(it.suggestion, said: orig, reason: it.reason ?? "", origin: "issue",
                    kind: it.type == "vocabulary" ? "word" : "phrase", date: day)
            }
            for a in s.asks ?? [] {
                guard let way = a.ways.first else { continue }
                put(way, said: a.said, reason: a.note, origin: "ask", kind: "phrase", date: day)
            }
        }
        return Array(map.values)
    }

    /// 今日出す候補を選ぶ。今日の分の直しは結果画面で見たばかりなので出さない
    public static func pick(_ items: [Item], today: String, states: [String: CandidateState],
                            limit: Int = defaultLimit) -> [Item] {
        let open = items.filter { it in
            guard it.date < today else { return false }
            guard let st = states[it.key] else { return true }
            if st.dismissed { return false }
            if let until = st.until, until > today { return false }
            return true
        }
        func score(_ it: Item) -> Int {
            let ago = PhraseLogic.daysBetween(it.date, today)
            var s = 0
            if it.count >= 2 { s += 100 + it.count }
            if lookbackDays.contains(ago) { s += 50 }
            return s
        }
        return open.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            if a.date != b.date { return a.date > b.date }
            return a.key < b.key
        }.prefix(limit).map { $0 }
    }

    /// 「今日は使わない」: 寝かせる回数が増えるほど長く寝かせる
    public static func snooze(_ state: CandidateState?, today: String) -> CandidateState {
        var st = state ?? CandidateState()
        let days = snoozeDays[min(st.snoozes, snoozeDays.count - 1)]
        st.snoozes += 1
        st.until = PhraseLogic.addDays(today, days)
        return st
    }

    public static func dismiss(_ state: CandidateState?) -> CandidateState {
        var st = state ?? CandidateState()
        st.dismissed = true
        return st
    }
}

/// 候補 1 件の扱い（寝かせた日・もう出さない）。キーは phraseKey
public struct CandidateState: Codable, Equatable, Sendable {
    public var until: String?
    public var snoozes: Int
    public var dismissed: Bool

    public init(until: String? = nil, snoozes: Int = 0, dismissed: Bool = false) {
        self.until = until; self.snoozes = snoozes; self.dismissed = dismissed
    }
}

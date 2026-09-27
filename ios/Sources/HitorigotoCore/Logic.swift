import Foundation

/// 拡張機能の extension/english-core.js をそのまま移した層。
/// 同じ入力に同じ答えを返すことを ../test/parity_swift_test.mjs が突き合わせる。
public enum Logic {

    public static let keepFull = 30        // 全文で残すセッション数
    public static let keepTotal = 400      // 畳んだものも含めた保持上限
    public static let recurringMin = 2     // 何回出たら「繰り返し」として AI に渡すか
    public static let recurringSend = 5    // AI に渡す繰り返し指摘の件数
    public static let types = ["phrasing", "vocabulary", "grammar"]

    // MARK: - 応答の解釈

    /// 最初の { から対応する } までを取り出す。取れなければ nil
    public static func extractJsonObject(_ raw: String?) -> String? {
        guard let raw, let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0, inStr = false, esc = false
        var i = start
        while i < raw.endIndex {
            let c = raw[i]
            if inStr {
                if esc { esc = false }
                else if c == "\\" { esc = true }
                else if c == "\"" { inStr = false }
            } else if c == "\"" {
                inStr = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(raw[start...i]) }
            }
            i = raw.index(after: i)
        }
        return nil
    }

    static func asText(_ v: Any?) -> String {
        (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func asStringArray(_ v: Any?) -> [String] {
        guard let a = v as? [Any] else { return [] }
        return a.map { asText($0) }.filter { !$0.isEmpty }
    }

    /// JS の `!!v`
    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil: return false
        case let b as Bool: return b
        case let n as NSNumber: return n.doubleValue != 0
        case let s as String: return !s.isEmpty
        case is NSNull: return false
        default: return true
        }
    }

    /// 応答を、表示と保存が前提にできる形に揃える。読み取れなければ nil
    public static func parseFeedback(_ raw: String?) -> Feedback? {
        guard let json = extractJsonObject(raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let d = obj as? [String: Any] else { return nil }

        let issues = ((d["issues"] as? [Any]) ?? []).compactMap { raw -> Issue? in
            let it = raw as? [String: Any]
            let type = asText(it?["type"]).lowercased()
            let original = asText(it?["original"])
            let suggestion = asText(it?["suggestion"])
            guard !original.isEmpty, !suggestion.isEmpty else { return nil }
            return Issue(type: types.contains(type) ? type : "phrasing", original: original,
                         suggestion: suggestion, reason: asText(it?["reason"]))
        }
        let pron = ((d["pronunciation"] as? [Any]) ?? []).compactMap { raw -> Pronunciation? in
            let it = raw as? [String: Any]
            let said = asText(it?["said"]), heard = asText(it?["heard_as"])
            guard !said.isEmpty, !heard.isEmpty else { return nil }
            return Pronunciation(said: said, heardAs: heard, note: asText(it?["note"]))
        }
        let targets = ((d["targets"] as? [Any]) ?? []).compactMap { raw -> Target? in
            let it = raw as? [String: Any]
            let phrase = asText(it?["phrase"])
            guard !phrase.isEmpty else { return nil }
            return Target(phrase: phrase, used: truthy(it?["used"]), exact: truthy(it?["exact"]),
                          asSaid: asText(it?["as_said"]), note: asText(it?["note"]))
        }
        return Feedback(
            correctedText: asText(d["corrected_text"]),
            issues: issues,
            recurring: asStringArray(d["recurring"]),
            recognitionDoubt: asStringArray(d["recognition_doubt"]),
            good: asText(d["good"]),
            transcript: asText(d["transcript"]),
            pronunciation: Array(pron.prefix(3)),
            targets: targets
        )
    }

    // MARK: - 繰り返し指摘

    public static func recurringText(_ issue: Issue) -> String {
        "\(issue.original ?? "") → \(issue.suggestion)"
    }

    public static func recurringKey(_ text: String) -> String {
        collapseSpaces(text.lowercased())
    }

    /// 空白の連続を 1 つに（JS の replace(/\s+/g, ' ').trim()）
    static func collapseSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// 今回の指摘を繰り返しリストへ反映する。1 回目は count:1 で控えるだけ
    public static func promoteRecurring(_ prev: [Recurring], issues: [Issue], today: String) -> [Recurring] {
        var list = prev
        var index: [String: Int] = [:]
        for (i, r) in list.enumerated() { index[recurringKey(r.text)] = i }
        var seen = Set<String>()
        for issue in issues {
            let text = recurringText(issue)
            let key = recurringKey(text)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            if let at = index[key] {
                list[at].count += 1
                list[at].lastSeen = today
            } else {
                index[key] = list.count
                list.append(Recurring(text: text, count: 1, lastSeen: today))
            }
        }
        return list
    }

    /// AI に渡すのは「2 回以上出たもの」の上位だけ
    public static func topRecurring(_ list: [Recurring], limit: Int = recurringSend, min: Int = recurringMin) -> [Recurring] {
        list.filter { $0.count >= min }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.text.localizedCompare(b.text) == .orderedAscending
            }
            .prefix(limit).map { $0 }
    }

    /// 直近 keepFull 件は全文、それ以前は指摘の type と suggestion だけ残す
    public static func foldSessions(_ sessions: [Session], keepFull: Int = keepFull, keepTotal: Int = keepTotal) -> [Session] {
        sessions.prefix(keepTotal).enumerated().map { i, s in
            if i < keepFull || s.folded == true { return s }
            return Session(id: s.id, folded: true,
                           issues: s.issues.map { Issue(type: $0.type, suggestion: $0.suggestion) })
        }
    }

    // MARK: - コピー用の本文

    public struct Labels {
        public var corrected: String, issues: String, good: String, said: String, pron: String
        public var types: [String: String]
        public init(corrected: String, issues: String, good: String, said: String, pron: String, types: [String: String]) {
            self.corrected = corrected; self.issues = issues; self.good = good; self.said = said; self.pron = pron; self.types = types
        }
    }

    /// 履歴からコピーするときの本文。修正版だけでなく、何をどう直されたのかも持ち出せる
    public static func buildSessionText(_ s: Session, labels L: Labels) -> String {
        var out: [String] = []
        if let c = s.correctedText, !c.isEmpty { out.append("【\(L.corrected)】\n\(c)") }
        if !s.issues.isEmpty {
            let lines = s.issues.enumerated().map { i, it -> String in
                let head = (it.original?.isEmpty == false) ? "\(it.original!)\n   → \(it.suggestion)" : "→ \(it.suggestion)"
                let type = L.types[it.type].map { "[\($0)] " } ?? ""
                let reason = (it.reason?.isEmpty == false) ? "\n   \(it.reason!)" : ""
                return "\(i + 1). \(type)\(head)\(reason)"
            }
            out.append("【\(L.issues)】\n\(lines.joined(separator: "\n\n"))")
        }
        if let pron = s.pronunciation, !pron.isEmpty {
            let lines = pron.enumerated().map { i, it in
                "\(i + 1). \(it.said) → \(it.heardAs)" + (it.note.isEmpty ? "" : "\n   \(it.note)")
            }
            out.append("【\(L.pron)】\n\(lines.joined(separator: "\n\n"))")
        }
        if let g = s.good, !g.isEmpty { out.append("【\(L.good)】\n\(g)") }
        if let t = s.transcript, !t.isEmpty { out.append("【\(L.said)】\n\(t.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return out.joined(separator: "\n\n")
    }

    // MARK: - AI へ渡すユーザーメッセージ（JS と一字一句同じ）

    static func recurringLines(_ recurring: [Recurring]) -> String {
        let lines = recurring.map { "- \($0.text)（\($0.count) 回）" }
        return lines.isEmpty ? "なし" : lines.joined(separator: "\n")
    }

    public static func buildEnglishUserMessage(_ transcript: String, recurring: [Recurring], extra: String = "") -> String {
        """
        ## 今回の独り言（音声認識結果）
        \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))

        ## これまでに繰り返し指摘されている点
        \(recurringLines(recurring))\(extra)
        """
    }

    public static func buildEnglishAudioUserMessage(_ asrTranscript: String, recurring: [Recurring], extra: String = "") -> String {
        let asr = asrTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ## 今回の独り言
        音声を添付しています。まず音声を聞いて、実際に言ったことを書き起こしてください。

        ## 参考：Chrome の音声認識結果（化けている可能性があります。書き起こしの根拠にしないこと）
        \(asr.isEmpty ? "（取れませんでした。音声だけを頼りにしてください）" : asr)

        ## これまでに繰り返し指摘されている点
        \(recurringLines(recurring))\(extra)
        """
    }

    /// 今日の日付（'YYYY-MM-DD'・端末のローカル時刻）
    public static func todayStamp(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

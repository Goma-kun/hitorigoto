import Foundation

/// 添削文（corrected_text）と書き起こしを突き合わせて、「直すべし」に挙がらなかった直しを拾う。
/// コーチの指摘は最大 5 件なので、添削文の中で黙って直された箇所が残る（Day 28 で本人が気づいた）。
/// 読者がそれを自分で拾っていたのを、アプリでやる
enum SilentFixes {
    struct Fix: Equatable, Identifiable {
        var from: String
        var to: String
        var id: String { from + "→" + to }
    }

    private static let fillers: Set<String> = ["uh", "um", "er", "hmm", "mm", "ah", "oh"]

    static func find(transcript: String, corrected: String, issues: [Issue], limit: Int = 10) -> [Fix] {
        let a = tokens(transcript), b = tokens(corrected)
        guard !a.isEmpty, !b.isEmpty, a.count < 1200, b.count < 1200 else { return [] }
        // LCS で「同じ語」の並びを取り、それ以外を変更の塊にまとめる
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].key == b[j].key ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        var runs: [(ai: Int, aj: Int, bi: Int, bj: Int)] = []     // a[ai..<aj] → b[bi..<bj]
        var cur: (Int, Int, Int, Int)? = nil
        func closeRun() { if let c = cur { runs.append((c.0, c.1, c.2, c.3)); cur = nil } }
        while i < n || j < m {
            if i < n, j < m, a[i].key == b[j].key {
                closeRun(); i += 1; j += 1
            } else if j < m, i >= n || dp[i][j + 1] >= dp[i + 1][j] {
                if cur == nil { cur = (i, i, j, j) }; cur!.3 = j + 1; j += 1
            } else {
                if cur == nil { cur = (i, i, j, j) }; cur!.1 = i + 1; i += 1
            }
        }
        closeRun()
        let merged = runs
        let coveredFrom = issues.compactMap { $0.original?.lowercased() }
        let coveredTo = issues.map { $0.suggestion.lowercased() }
        var out: [Fix] = []
        for r in merged {
            let fromWords = a[r.ai..<r.aj].map(\.text), toWords = b[r.bi..<r.bj].map(\.text)
            let fromKeys = a[r.ai..<r.aj].map(\.key)
            // 言いよどみ・同じ語の繰り返しを消しただけなら出さない
            if toWords.isEmpty, fromKeys.allSatisfy({ fillers.contains($0) }) { continue }
            if toWords.isEmpty, Set(fromKeys).count == 1, r.ai > 0, a[r.ai - 1].key == fromKeys[0] { continue }
            if fromWords.isEmpty && toWords.isEmpty { continue }
            // 前後 1 語を添えて読める形にする
            let from = ((r.ai > 0 ? [a[r.ai - 1].text] : []) + fromWords + (r.aj < n ? [a[r.aj].text] : [])).joined(separator: " ")
            let to = ((r.bi > 0 ? [b[r.bi - 1].text] : []) + toWords + (r.bj < m ? [b[r.bj].text] : [])).joined(separator: " ")
            if from.lowercased() == to.lowercased() { continue }
            // コーチの指摘と重なるものは出さない（言った形か直した形のどちらかが指摘に含まれていれば重なり）
            let coreFrom = fromWords.joined(separator: " ").lowercased(), coreTo = toWords.joined(separator: " ").lowercased()
            if !coreFrom.isEmpty, coveredFrom.contains(where: { $0.contains(coreFrom) || coreFrom.contains($0) }) { continue }
            if !coreTo.isEmpty, coveredTo.contains(where: { $0.contains(coreTo) || coreTo.contains($0) }) { continue }
            out.append(Fix(from: from, to: to))
            if out.count >= limit { break }
        }
        return out
    }

    private struct Tok { let text: String; let key: String }
    private static func tokens(_ s: String) -> [Tok] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { w in
            let text = String(w)
            let key = text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(CharacterSet(charactersIn: "'’")))
            return Tok(text: text, key: key.isEmpty ? text.lowercased() : key)
        }
    }
}

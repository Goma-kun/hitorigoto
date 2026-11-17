import Foundation

// 直しの点検（2026-11-17）: 添削の返事を受け取ったあと、言った文と修正版を機械で見比べ、
// 「直すべし」「ほかに直したところ」のどこにも説明が無い書き換えが多いときだけ、文字だけでもう一度聞いて足す。
// 添削の指示文には「書き換えた箇所は 1 つ残らず入れる」と書いてあるが、AI が守らない回がある
// （2026-11-17 朝: 修正版では 20 か所近く直したのに、説明は 8 件・more_fixes は空・修正版に "this me" の打ち間違い）。
// 指示文を強めても守らない回は残るので、受け取り側で数えて、足りない回だけ聞き直す。
// アプリ版だけの機能なので、ここが正本（Explain・Assess と同じ）。中継サーバーでは /v1/talk の 1 ターンとして数える

public enum Audit {

    /// 説明の無い書き換え 1 か所（言った側の語と、修正版の側の語）
    public struct Change: Equatable, Sendable {
        public var removed: [String]
        public var added: [String]
        /// 修正版の側の前後（場所を伝えるため。前後 4 語ずつ）
        public var context: String = ""
    }

    /// 点検の返事
    public struct Result: Equatable, Sendable {
        /// 修正版の差し替え（from は修正版の中の文字列・to は直した形）。
        /// 全文を書き直させると別の場所に打ち間違いが入る（2026-11-17 実測）ので、差し替えだけを受け取って機械で当てる
        public var patches: [Patch]
        public var fixes: [Fix]
    }
    public struct Patch: Equatable, Sendable {
        public var from: String
        public var to: String
    }

    /// 説明の無い書き換えがこの数以上あったら聞き直す
    public static let threshold = 3
    /// これより短い独り言では聞き直さない（語数）
    public static let minWords = 30
    /// 点検の考える深さ（確認用に環境変数 HG_AUDIT_THINKING で変えられる）
    public static var thinking: String { ProcessInfo.processInfo.environment["HG_AUDIT_THINKING"] ?? "medium" }
    /// 足す直しの上限
    public static let maxFixes = 30

    /// 比べるときの語。小文字にして、文字・数字・アポストロフィ以外で切る（I'm と I’m は同じ語にする）
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// これだけでは「説明済み」の手がかりにしない語（どの直しにも出てくるので）
    static let common: Set<String> = [
        "a", "an", "the", "i", "you", "he", "she", "it", "we", "they", "me", "my", "your", "this", "that", "these", "those",
        "is", "am", "are", "was", "were", "be", "been", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could",
        "to", "of", "in", "on", "at", "for", "with", "about", "from", "by", "as", "and", "but", "or", "so", "because", "if",
        "not", "no", "yes", "there", "here", "what", "which", "who", "when", "then", "than", "just", "very", "really",
        "i'm", "i've", "i'd", "i'll", "it's", "that's", "don't", "didn't", "can't",
    ]

    /// 言った文と修正版を語で突き合わせ、違っている場所を順に返す（消しただけの場所は含めない）
    static func changes(said: String, corrected: String) -> [Change] {
        let a = words(said), b = words(corrected)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // 共通の並び（LCS）を後ろから数える
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Change] = []
        var cur = Change(removed: [], added: [])
        var i = 0, j = 0
        func flush() {
            if !cur.added.isEmpty {
                let from = max(0, j - cur.added.count - 4), to = min(b.count, j + 4)
                cur.context = b[from..<to].joined(separator: " ")
                out.append(cur)
            }
            cur = Change(removed: [], added: [])
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { flush(); i += 1; j += 1 }
            else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { cur.added.append(b[j]); j += 1 }
            else { cur.removed.append(a[i]); i += 1 }
        }
        flush()
        return out
    }

    /// 書き換えのうち、どの直しにも説明が無いもの。
    /// 「説明がある」＝修正版で足した語のどれか（ありふれた語は除く）が、直した形か「英語ならこう」の言い方に出てくる
    public static func uncovered(said: String, feedback fb: Feedback) -> [Change] {
        var explained = Set<String>()
        for i in fb.issues { explained.formUnion(words(i.suggestion)) }
        for f in fb.moreFixes { explained.formUnion(words(f.suggestion)) }
        for a in fb.asks { for w in a.ways { explained.formUnion(words(w)) } }
        return changes(said: said, corrected: fb.correctedText).filter { c in
            let content = c.added.filter { !common.contains($0) }
            let keys = content.isEmpty ? c.added : content
            return !keys.contains(where: explained.contains)
        }
    }

    /// 聞き直すかどうか。語の区切りに空白が無い言語（日本語）は突き合わせができないので対象外
    public static func needed(said: String, feedback fb: Feedback, language: TargetLanguage) -> Bool {
        guard !language.hasNoWordSpaces, !fb.correctedText.isEmpty, words(said).count >= minWords else { return false }
        return uncovered(said: said, feedback: fb).count >= threshold
    }

    // MARK: - 指示文

    /// 添削の指示文から、人物像と口調の節だけを借りる（文面を二重に持たない）
    static var persona: String {
        let s = Prompts.system
        guard let from = s.range(of: "## あなたの人物像と口調"),
              let to = s.range(of: "## 口調より優先される絶対のルール"), from.lowerBound < to.lowerBound else { return "" }
        return String(s[from.lowerBound..<to.lowerBound])
    }

    static let rules = """
## やること（点検）

学習者が言った文、あなたが書いた修正版、すでに説明した直しの一覧が渡されます。
修正版では直してあるのに、どこにも説明が無い箇所が残っています。それを埋めるのが今回の仕事です。

1. 学習者が言った文を頭から 1 文ずつ取り出し、修正版の対応する文と見比べてください。
2. 書き換えてあるのに「すでに説明した直し」に無い箇所を、1 件ずつ説明します（返し方は 4 を見てください）。
   - "original": 学習者が言った形（言った文からそのまま引く）
   - "suggestion": 直した形（英語だけ。口調を混ぜない）
   - "note": なぜそう直すのかを、老トレーナーの口調で日本語 1〜2 文。理屈は正確に。空にしない
   - 時制、冠詞、前置詞、語の選び方、文のつなぎ方（because と so の重なりなど）の小さな直しも 1 件ずつ入れる
   - 言った形のままだと**意味が変わってしまう**箇所（「完全にはやめていない」のつもりで「まったくやめない」と言った、など）は、
     必ず入れ、どう意味がずれるのかを "note" に書く
   - 「すでに説明した直し」と同じ中身は入れない
   - 言いよどみ（uh、um、you know）を消しただけ、言い直しや繰り返しを 1 回にまとめただけの箇所は入れない
3. 修正版そのものも見直し、直すところを "corrected_patches" に入れてください。全文は書き直しません。
   - "from": 直す部分を含む 1 文を、修正版から**文頭から文末の記号までまるごと、一字も変えずに**引く
   - "to": その 1 文を直したもの（英語だけ。文頭から文末の記号まで。そのまま差し替えて前後とつながる形にする）
   - 入れるもの:
     - 打ち間違い・語の抜け・意味の通らない語
     - 「すでに説明した直し」で直したはずの言い方が、修正版の別の場所に残っているところ
     - 学習者の誤りが直らずに残っているところ（時制の食い違い、because と so の重なりなど）
     - 話の流れと食い違うところ（これからの予定なのに過去形、前後で言っていることが食い違う語の選び方、など）
   - 文・例・数字・固有名詞を削る差し替えはしない。直すところが無ければ空配列にする
   - 修正版の打ち間違いは学習者の誤りではないので、"more_fixes" には入れない。
     学習者の誤りが残っていたところを直した場合だけ、その直しを "more_fixes" にも入れる（"original" は学習者が言った形）
4. 「機械で見つけた、説明の無い書き換え」が番号つきで渡されます。左が学習者の言った語、右が修正版の語、かっこの中は修正版での前後です。
   **番号 1 つにつき必ず 1 件、"answers" に答えを返してください。飛ばした番号があってはいけません。**
   - 直しとして説明が要るもの（文法・語の選び方・言い回し・時制・冠詞・前置詞・文のつなぎ方）は "skip": false にして、
     "original"・"suggestion"・"note" を書く。"original" は学習者が言った文から、意味の通るまとまりで引く（1 語だけにしない）
   - 言いよどみを消しただけ、言い直しをまとめただけ、句読点や大文字小文字だけ、のものは "skip": true にする
   - 隣り合う番号が同じ 1 つの直しなら、最初の番号で説明し、残りは "skip": true にする
   - 「すでに説明した直し」と同じ中身なら "skip": true にする
   渡された番号に無い直しを見つけたら、それは "more_fixes" に入れてください。
5. 発音には触れないでください。

## 出力

以下の JSON だけを返してください。前置き、説明、コードフェンスは付けないでください。

{
  "answers": [
    { "n": 1, "skip": false, "original": "学習者が言った形", "suggestion": "直した形", "note": "なぜそう直すのかを老トレーナーの口調で日本語 1〜2 文" },
    { "n": 2, "skip": true }
  ],
  "more_fixes": [
    { "original": "学習者が言った形", "suggestion": "直した形", "note": "なぜそう直すのかを老トレーナーの口調で日本語 1〜2 文" }
  ],
  "corrected_patches": [
    { "from": "修正版の中の 1 文（そのまま）", "to": "直した 1 文" }
  ]
}
"""

    /// 点検の指示文。人物像は添削と同じものを使い、話す言語と説明の言語は添削と同じやり方で合わせる
    public static func system(language: TargetLanguage, explanation: TargetLanguage.Explanation = TargetLanguage.explanation) -> String {
        let base = "あなたは英語学習者の「独り言」練習を見る、下町のボクシングジムの老トレーナーです。\n"
            + "さきほどあなたが返した添削に、説明の漏れが無いかを点検します。\n\n" + persona + rules
        return language.localize(base, explanation: explanation)
    }

    public static func userMessage(said: String, feedback fb: Feedback) -> String {
        var lines: [String] = []
        lines.append("## 学習者が言った文\n\(said)\n")
        lines.append("## 修正版\n\(fb.correctedText)\n")
        lines.append("## すでに説明した直し")
        var n = 0
        for i in fb.issues { n += 1; lines.append("\(n). \(i.original ?? "") → \(i.suggestion)") }
        for f in fb.moreFixes { n += 1; lines.append("\(n). \(f.original) → \(f.suggestion)") }
        for a in fb.asks { n += 1; lines.append("\(n). \(a.said) → \(a.ways.joined(separator: " / "))") }
        if n == 0 { lines.append("（なし）") }
        let gaps = uncovered(said: said, feedback: fb)
        if !gaps.isEmpty {
            lines.append("\n## 機械で見つけた、説明の無い書き換え（言った語 → 修正版の語（修正版での前後））")
            for (k, g) in gaps.enumerated() {
                lines.append("\(k + 1). \(g.removed.isEmpty ? "（なし）" : g.removed.joined(separator: " ")) → \(g.added.joined(separator: " "))（… \(g.context) …）")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 返事を読む・足す

    public static func parse(_ raw: String) -> Result? {
        guard let json = Logic.extractJsonObject(raw), let data = json.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // 番号つきの答え（skip でないもの）を先に、番号に無い直しを後ろに
        let items = ((d["answers"] as? [Any]) ?? []) + ((d["more_fixes"] as? [Any]) ?? [])
        let fixes = items.compactMap { raw -> Fix? in
            let it = raw as? [String: Any]
            if Logic.truthy(it?["skip"]) { return nil }
            let o = Logic.asText(it?["original"]), s = Logic.asText(it?["suggestion"])
            guard !o.isEmpty, !s.isEmpty, o != s else { return nil }
            return Fix(original: o, suggestion: s, note: Logic.asText(it?["note"]))
        }
        let patches = ((d["corrected_patches"] as? [Any]) ?? []).compactMap { raw -> Patch? in
            let it = raw as? [String: Any]
            let from = Logic.asText(it?["from"]), to = Logic.asText(it?["to"])
            guard !from.isEmpty, !to.isEmpty, from != to else { return nil }
            return Patch(from: from, to: to)
        }
        return Result(patches: patches, fixes: Array(fixes.prefix(maxFixes)))
    }

    /// 点検の返事を添削に足す。
    /// - 直しは「ほかに直したところ」の後ろに足し、重なりを外す
    /// - 修正版の差し替えは、from が修正版にちょうど 1 回出てくるものだけ当てる。
    ///   大きく削る差し替え（to の語数が from の半分未満で 4 語以上減る）は当てない（要約させない）
    public static func merge(_ fb: Feedback, _ r: Result) -> Feedback {
        var out = fb
        let tidy = Logic.tidyFixes(fb.issues, fb.moreFixes + r.fixes)
        out.moreFixes = tidy.fixes
        var text = fb.correctedText
        for p in r.patches {
            guard text.components(separatedBy: p.from).count == 2 else { continue }
            let a = words(p.from).count, b = words(p.to).count
            if a - b >= 4, b * 2 < a { continue }
            text = text.replacingOccurrences(of: p.from, with: p.to)
        }
        out.correctedText = text
        return out
    }
}

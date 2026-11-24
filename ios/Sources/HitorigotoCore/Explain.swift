import Foundation

// 「トラさんに詳しく聞く」: 直し 1 件（または「英語ならこう」1 件）について、追加で解説を頼む。
// 添削の指示文（Prompts.swift・JS から機械生成）とは別物。アプリ版だけの機能なので、ここが正本。
// 送るのは文字だけ（音声は送らない）。中継サーバーでは添削とは別の回数で数える（/v1/explain）

/// 何について聞くか
public struct ExplainTopic: Codable, Equatable, Sendable {
    public var kind: String          // issue | ask
    public var original: String      // issue: 言った形／ask: 日本語で言ったこと
    public var suggestion: String    // issue: 直した形／ask: 言い方（複数なら " / " でつなぐ）
    public var reason: String        // 添削のときの一言

    public init(kind: String, original: String, suggestion: String, reason: String = "") {
        self.kind = kind; self.original = original; self.suggestion = suggestion; self.reason = reason
    }

    public init(issue: Issue) {
        self.init(kind: "issue", original: issue.original ?? "", suggestion: issue.suggestion, reason: issue.reason ?? "")
    }

    public init(ask: Ask) {
        self.init(kind: "ask", original: ask.said, suggestion: ask.ways.joined(separator: " / "), reason: ask.note)
    }

    /// あとから「これ、何て言う？」と聞く分（2026-11-25 本人の要望）。直しではなく、言いたかったことそのもの
    public init(wish: String) {
        self.init(kind: "wish", original: wish.trimmingCharacters(in: .whitespacesAndNewlines), suggestion: "")
    }

    /// 保存してある見分け（key）から、あとから聞いた分を組み直す。あとから聞いた分でなければ nil
    public init?(wishKey key: String) {
        guard key.hasPrefix("wish:"), key.hasSuffix("→") else { return nil }
        self.init(wish: String(key.dropFirst(5).dropLast(1)))
    }

    /// 保存のときの見分け（同じセッションの同じ直しには同じやり取りを出す）
    public var key: String { "\(kind):\(original)→\(suggestion)" }
}

/// 解説の中の例文 1 つ
public struct ExplainExample: Codable, Equatable, Sendable {
    public var text: String
    public var ja: String

    public init(text: String, ja: String = "") { self.text = text; self.ja = ja }
}

/// 1 往復（聞いたこと・返ってきたこと）
public struct ExplainTurn: Codable, Equatable, Sendable {
    public var q: String
    public var a: String
    public var examples: [ExplainExample]

    public init(q: String, a: String, examples: [ExplainExample] = []) { self.q = q; self.a = a; self.examples = examples }

    enum CodingKeys: String, CodingKey { case q, a, examples }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        q = try c.decodeIfPresent(String.self, forKey: .q) ?? ""
        a = try c.decodeIfPresent(String.self, forKey: .a) ?? ""
        examples = try c.decodeIfPresent([ExplainExample].self, forKey: .examples) ?? []
    }
}

/// 直し 1 件ぶんのやり取り。セッションに残すので、履歴から開き直しても回数を使わない
public struct ExplainThread: Codable, Equatable, Sendable {
    public var key: String
    public var turns: [ExplainTurn]

    public init(key: String, turns: [ExplainTurn] = []) { self.key = key; self.turns = turns }
}

public enum Explain {

    /// 用意しておく聞き方。最初の 1 回は deeper を自動で出す
    public enum Preset: String, CaseIterable, Sendable {
        case deeper, alternatives, examples, grammar, compare
        /// あとから「これ、何て言う？」と聞くときの最初の 1 回（続けて聞くボタンには出さない）
        case howToSay

        /// 続けて聞くボタンに出す分。あとから聞いた言い方には「直し」が無いので、直しの説明を頼むものは出さない
        public static func followUps(for topic: ExplainTopic, first: Bool) -> [Preset] {
            if topic.kind == "wish" { return [.examples, .compare] }
            return allCases.filter { $0 != .howToSay && ($0 != .deeper || first) }
        }

        /// ボタンに出す文字（そのまま「聞いたこと」として残す）
        public var label: String {
            switch self {
            case .deeper: return String(localized: "くわしく")
            case .alternatives: return String(localized: "ほかの形も正解？")
            case .examples: return String(localized: "例文をもっと")
            case .grammar: return String(localized: "文法で説明して")
            case .compare: return String(localized: "似た言い方との違い")
            case .howToSay: return String(localized: "これ、何て言う？")
            }
        }

        /// AI に渡す頼み方（指示文は日本語で書く。答えの言語は system 側で決める）
        public var request: String {
            switch self {
            case .deeper:
                return "この直しについて、なぜそう直すのかをもう一歩くわしく説明してください。添削のときの一言より深く、どういう場面でどう使い分けるのかまで教えてください。例文を 3 つ付けてください。"
            case .alternatives:
                return "直した形は、元の話の流れに合わせた一つの言い方です。学習者が「この形だけが正解」と思い込まないように説明してください。(1) 元の話の流れでは、なぜこの形になるのか（時制・仮定・語の選び方など、形を決めた手がかりを話の中から示す）(2) 同じ中身を言える別の正しい形を 2〜3 個挙げ、それぞれ言うと意味や伝わり方がどう変わるか、どんな場面ならその形が合うか (3) 元の話の流れでは選ばないほうがよい形があれば、その理由。別の形ごとに例文を 1 つ付けてください。"
            case .examples:
                return "この直した形（または言い方）を使った例文を、日常会話でよくある場面から 5 つください。場面がばらけるようにしてください。"
            case .grammar:
                return "この直しを、文法の言葉（品詞・語の働き・構文の型）を使ってきちんと説明してください。なぜ元の形ではいけないのか、規則として覚えるならどう覚えればよいかまで。例文を 3 つ付けてください。"
            case .howToSay:
                return "学習者が言いたかったこと（上の「学習者が言いたかったこと」）を、学習者が練習している言語の自然な話し言葉でどう言うかを教えてください。examples に言い方そのものを 2〜3 個入れます（text が言い方、ja がその日本語訳）。1 つ目はいちばんすすめる言い方で、学習者がそのまま口に出せる長さにします。2 つ目からは、くだけ方や組み立てが違う言い方です。**言いたかったことの中身を落とさないこと**（「寒いけれど気持ちがいい」なら、寒いこと・気持ちがいいこと・「けれど」の対比の 3 つとも入れる。程度の語の「ちょっと」「とても」も保つ）。answer には、要になる語句と、言い方ごとの感じの違いを短く書きます（2〜3 段落）。"
            case .compare:
                return "直した形と似た言い方（言い換えの候補）をいくつか挙げて、ニュアンス・硬さ・使う場面の違いを比べてください。それぞれ例文を 1 つずつ付けてください。"
            }
        }
    }

    /// システム指示。人物はトラさん（寅吉）のまま、ただし解説は正確さを最優先にする
    public static func system(language: TargetLanguage, explanation: TargetLanguage.Explanation = TargetLanguage.explanation) -> String {
        let lang = language.promptName
        var s = """
あなたは「独り言」アプリのコーチ、寅吉（トラさん）です。下町のボクシングジムの老トレーナーで、口は悪いが面倒見がいい人物です。
学習者は\(lang)で独り言を話し、あなたの添削を受けました。いま学習者は、そのうちの 1 件について「もっと詳しく知りたい」と聞いてきています。

\(language.variantNote)

## 答え方
- 一人称は「わし」、学習者は「おめえ」。べらんめえ調で短く、ただし**説明の中身は正確で分かりやすいこと**を何より優先する。口調のために中身を削らない
- 学習者の質問にまっすぐ答える。聞かれていないことを長々と書かない
- 本文（answer）は 2〜5 段落。段落の間は空行（\\n\\n）で区切る。見出し・箇条書きの記号（#, -, *）は使わない。強調したい\(lang)の語句は **太字** にしてよい
- 例文（examples）は自然な話し言葉の\(lang)で、場面がすぐ浮かぶ短い文にする。ja は例文の自然な日本語訳
- 確信の持てないことは言い切らない。「地域や人によっては〜とも言う」のように幅を残す
- 添削のときの直しそのものが不自然・誤りだと気づいたら、正直にそう言って直す

## 出力
次の JSON だけを返す。前後に説明や ``` を付けない。
{"answer": "本文", "examples": [{"text": "例文", "ja": "日本語訳"}]}
例文が要らない質問なら examples は空配列でよい。
"""
        if explanation == .en {
            s += """

## 出力言語の上書き（最優先）
- "answer" と "ja" は**日本語ではなく英語**で書く（"ja" には例文の平易な英語での言い換えか意味の説明を入れる）。読む学習者は日本語が読めない。
- 口調は a gruff old boxing-gym trainer: blunt and short, but the explanation must be accurate and clear.
"""
        }
        return s
    }

    /// 聞く内容（これまでのやり取りも文脈として渡す）。context は添削後の全文（長ければ切る）
    public static func userMessage(topic: ExplainTopic, context: String, history: [ExplainTurn], question: String) -> String {
        var lines: [String] = []
        lines.append(topic.kind == "wish" ? "## 学習者が言いたかったこと" : "## 対象の直し")
        if topic.kind == "wish" {
            lines.append("話し終えたあとで、学習者が「これは何と言えばよかったのか」と聞いてきた内容（直しではない）: \(topic.original)")
        } else if topic.kind == "ask" {
            lines.append("学習者が言葉に詰まって日本語で言ったこと: \(topic.original)")
            lines.append("あなたが返した言い方: \(topic.suggestion)")
        } else {
            lines.append("学習者が言った形: \(topic.original)")
            lines.append("あなたが直した形: \(topic.suggestion)")
        }
        if !topic.reason.isEmpty { lines.append("添削のときの一言: \(topic.reason)") }
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            lines.append("")
            lines.append(topic.kind == "wish" ? "## 参考: この日に学習者が話したこと（添削後。話の流れに合う言い方を選ぶ手がかり）" : "## 参考: この日の独り言（添削後）")
            lines.append(ctx.count > 1500 ? String(ctx.prefix(1500)) + "…" : ctx)
        }
        if !history.isEmpty {
            lines.append("")
            lines.append("## ここまでのやり取り")
            for t in history.suffix(4) {
                lines.append("学習者: \(t.q)")
                lines.append("あなた: \(t.a.count > 600 ? String(t.a.prefix(600)) + "…" : t.a)")
            }
        }
        lines.append("")
        lines.append("## 学習者の今回の質問")
        lines.append(question)
        return lines.joined(separator: "\n")
    }

    /// 応答を読む。JSON で返らなかったときは本文として丸ごと使う（何も出ないよりよい）
    public static func parse(_ raw: String, question: String) -> ExplainTurn? {
        if let json = Logic.extractJsonObject(raw), let data = json.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let answer = Logic.asText(obj["answer"])
            let examples = ((obj["examples"] as? [Any]) ?? []).compactMap { e -> ExplainExample? in
                guard let d = e as? [String: Any] else { return nil }
                let text = Logic.asText(d["text"])
                return text.isEmpty ? nil : ExplainExample(text: text, ja: Logic.asText(d["ja"]))
            }
            if answer.isEmpty && examples.isEmpty { return nil }
            return ExplainTurn(q: question, a: answer, examples: Array(examples.prefix(6)))
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : ExplainTurn(q: question, a: text)
    }
}

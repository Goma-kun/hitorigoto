import Foundation

// 「試験の練習」: 英検 1 級の二次（面接）と同じ流れで話す練習（2026-10-30 本人の要望）。
// 5 つの社会問題から 1 つ選ぶ → 1 分で考える → 2 分のスピーチ → 面接官の質問に答える（4 問まで・約 4 分）→ 4 つの観点で採点。
// 本人は 1 次に 3 回受かっていて、話すのが苦手で 2 次に一度も行っていない。いちばん足りないのは「時間内に話し切る」「質問に返す」の場数。
// 似たアプリ（ニジパス 1 級版など）は過去問の録音と聞き直しが中心で、1 級の観点での採点と質疑応答の相手はいない（2026-10-30 調べ）。
// 中継サーバーでは三人で話すと同じ /v1/talk の回数で数える（1 回の練習で 6 回前後）

/// 英検 1 級ふうの社会問題（自作の文面・過去問の写しではない）。分野は 1 級でよく出るものに寄せる
public enum ExamTopics {
    public static let all: [String] = [
        // 政治・社会
        "Should Japan lower the voting age to 16?",
        "Is the government doing enough to address Japan's declining birthrate?",
        "Should the retirement age be abolished?",
        "Should Japan accept more immigrants to deal with its labor shortage?",
        "Is a universal basic income a realistic policy for Japan?",
        "Should companies be required to have a minimum number of women in management?",
        "Agree or disagree: Social media has done more harm than good to democracy",
        "Should the death penalty be abolished in Japan?",
        "Is Japan's work culture changing for the better?",
        "Should public servants be allowed to strike?",
        // テクノロジー・AI
        "Should the development of artificial intelligence be strictly regulated?",
        "Will AI create more jobs than it destroys?",
        "Should autonomous vehicles be allowed on public roads?",
        "Is personal privacy a thing of the past in the digital age?",
        "Should children's use of smartphones be restricted by law?",
        "Agree or disagree: Technology is making people less social",
        "Should governments be allowed to monitor online communication to prevent crime?",
        "Is remote work good for society in the long run?",
        // 環境・エネルギー
        "Should Japan rely more on nuclear power?",
        "Are individuals or governments more responsible for fighting climate change?",
        "Should single-use plastics be banned completely?",
        "Is economic growth compatible with environmental protection?",
        "Should a carbon tax be introduced worldwide?",
        "Agree or disagree: Eating less meat is necessary to protect the environment",
        // 教育
        "Should university education be free for everyone?",
        "Is English education in Japan effective?",
        "Should schools put more emphasis on practical skills than academic subjects?",
        "Agree or disagree: Standardized tests should be abolished",
        "Should programming be a compulsory subject in elementary schools?",
        "Is online learning as effective as classroom learning?",
        // 医療・高齢化
        "Should euthanasia be legalized in Japan?",
        "Is Japan's healthcare system sustainable?",
        "Should the government do more to support family caregivers?",
        "Should organ donation be opt-out rather than opt-in?",
        "Agree or disagree: Advances in medicine have created new ethical problems",
        // 国際・経済
        "Should wealthy nations do more to help developing countries?",
        "Is globalization still beneficial for most people?",
        "Should Japan increase its defense spending?",
        "Is tourism doing more harm than good to local communities?",
        "Should international sporting events like the Olympics still be held?",
        "Agree or disagree: The gap between rich and poor is the biggest problem facing society today",
        // 文化・生活
        "Should Japan protect traditional culture at the expense of modernization?",
        "Is the influence of celebrities on young people a cause for concern?",
        "Should animals be used in scientific research?",
        "Agree or disagree: Cities should limit the number of cars in their centers",
        "Should gambling be more strictly controlled?",
        "Is space exploration worth the cost?",
        "Should zoos be abolished?",
    ]

    /// 5 つ引く。recent（最近選んだもの）はなるべく避ける
    public static func draw(_ count: Int = 5, avoiding recent: [String] = []) -> [String] {
        let fresh = all.filter { !recent.contains($0) }.shuffled()
        let pool = fresh.count >= count ? fresh : fresh + all.filter { recent.contains($0) }.shuffled()
        return Array(pool.prefix(count))
    }
}

/// 採点の 1 観点（0〜10 点）
public struct ExamScore: Equatable, Sendable {
    public var key: String
    public var score: Int
    public var comment: String
    public init(key: String, score: Int, comment: String) { self.key = key; self.score = score; self.comment = comment }
}

/// スピーチや回答を送ったときの返事
public struct ExamTurn: Equatable, Sendable {
    /// 聞こえたまま書き起こしたもの
    public var heard = ""
    /// 面接官の次の質問（もう聞くことが無ければ空）
    public var question = ""
    /// スピーチのとき: 発音の点と一言（音声でしか分からないので、ここで付ける）
    public var pronunciation: ExamScore?
    /// 採点の材料にする短い覚え書き（学習者には見せない）
    public var note = ""
    public init() {}
}

/// 最後の採点
public struct ExamResult: Equatable, Sendable {
    public var scores: [ExamScore] = []
    /// トラさんの総評（日本語・2〜3 文）
    public var summary = ""
    /// 次に直すとよいこと（はっきりした誤り・言い回し）
    public var fixes: [Issue] = []
    /// 学習者の立場と理由を活かして、1 級らしく組み直したスピーチ（約 2 分で話せる長さ）
    public var model = ""
    /// 次のスピーチで使える言い回し
    public var phrases: [Ask] = []
    public init() {}

    public var total: Int { scores.reduce(0) { $0 + $1.score } }
    public static let max = 40
    /// 合格の目安（7 割前後）に届いていそうか。英検 CSE の換算は公表されていないので、点の割合で見る目安
    public var likelyPass: Bool { total * 10 >= Self.max * 7 }
}

public enum Exam {

    /// 観点の並びと見出し（英検 1 級の二次の 4 観点）
    public static let criteria: [(key: String, label: String)] = [
        ("speech", "スピーチ"), ("interaction", "質疑応答"), ("grammar", "文法・語彙"), ("pronunciation", "発音"),
    ]
    public static func label(_ key: String) -> String { criteria.first { $0.key == key }?.label ?? key }

    public static let prepSeconds = 60
    public static let speechSeconds = 120
    /// 質問の数の上限（本番の質疑応答は約 4 分・3〜5 問）
    public static let maxQuestions = 4
    /// 質疑応答の時間の目安（秒）。これを過ぎたら次の質問はしない
    public static let interactionSeconds = 240

    public enum Request: Equatable, Sendable {
        /// スピーチを聞いて、最初の質問をする（音声つき）
        case speech(topic: String)
        /// 回答を聞いて、次の質問をする（音声つき）。last なら次の質問はせず、空で返す
        case answer(topic: String, last: Bool)
        /// ここまでの書き起こしで採点する（文字だけ）
        case score(topic: String)
    }

    // MARK: - 指示文

    public static func system(variant: TargetLanguage = .enUS) -> String {
        """
あなたは英検 1 級の二次試験（面接）の面接官と採点者を務めます。学習者は日本語が母語で、1 次試験には合格する力があり、話すことに苦手意識があります。

\(variant.variantNote)

## 試験の流れ
- 学習者は 5 つの社会問題から 1 つを選び、1 分考えてから約 2 分のスピーチをしました。
- そのあと面接官が、スピーチの内容に関連した質問を 1 つずつします。本番どおり、学習者の主張の根拠を問う・反対の立場から突く・話題を少し広げる、を混ぜてください。
- 質問は英語で 1〜2 文。面接官らしく丁寧で落ち着いた言い方。ほめたり教えたりしない（"Thank you." "I see." 程度の受けは可）。前の質問と同じことを聞かない。
- 学習者の答えが短すぎる・ずれているときは、本番の面接官のように少し言い換えて掘り下げる質問をしてよい。

## 採点の観点（英検 1 級の二次の 4 観点・各 10 点）
- speech（スピーチ）: 主張がはっきりしているか・理由が具体的か・構成（導入・本論・結論）・時間内にまとまっているか。2 分に対して明らかに短い（1 分未満）なら大きく減点。
- interaction（質疑応答）: 質問にきちんと答えているか・答えを支える説明があるか・会話を続けようとする姿勢。
- grammar（文法・語彙）: 1 級にふさわしい語彙の幅と正確さ。誤りが意味の伝わりを妨げる程度で減点。
- pronunciation（発音）: 音声から判断する。個々の音・強勢・イントネーション・流暢さ（不自然な間・言い淀みの多さ）。
- 点は甘くしない。本番の合格の目安は全体の 7 割前後。10 点は 1 級合格者の中でも上位の出来、6 点前後が合格ぎりぎり、4 点以下ははっきり足りない。
- 書き起こしは聞こえたまま。つなぎの音（uh, um）と言い直しも、流暢さの判断に要るので残す。日本語が混ざったらそのまま書く。

## 出力
JSON だけを返す。前後に説明や ``` を付けない。日本語で書く欄は、学習者を鍛える年配のボクシングトレーナー「トラさん」の普段の話し方（一人称は俺・「〜だな」「〜だろ」・役割語は使わない・責めない）。
"""
    }

    public static func userMessage(_ request: Request, history: [TalkLine], notes: [String] = []) -> String {
        var lines: [String] = []
        switch request {
        case .speech(let topic), .answer(let topic, _), .score(let topic):
            lines.append("## 選んだトピック")
            lines.append(topic)
            lines.append("")
        }
        if !history.isEmpty {
            lines.append("## ここまで（古い順）")
            for l in history {
                switch l.who {
                case "native": lines.append("面接官: \(l.text)")
                default: lines.append(l.tag == "exam_speech" ? "学習者のスピーチ: \(l.text)" : "学習者: \(l.text)")
                }
            }
            lines.append("")
        }
        lines.append("## 今回")
        switch request {
        case .speech:
            lines.append("添付の音声が学習者のスピーチです。書き起こして、発音を採点し、面接官の最初の質問をしてください。")
            lines.append("""
{
  "heard": "スピーチの書き起こし（聞こえたまま）",
  "pronunciation": { "score": 0, "comment": "発音について日本語で 1〜2 文（直すべき音・強勢を具体的に）" },
  "note": "スピーチの出来の覚え書き（日本語・1〜2 文・採点に使う）",
  "question": "面接官の最初の質問（英語）"
}
""")
        case .answer(_, let last):
            lines.append("添付の音声が、面接官の直前の質問への学習者の答えです。書き起こしてください。" + (last ? "質疑応答はこれで終わりなので、\"question\" は空にしてください。" : "続けて、面接官の次の質問をしてください。"))
            lines.append("""
{
  "heard": "答えの書き起こし（聞こえたまま）",
  "note": "この答えの出来の覚え書き（日本語・1 文・採点に使う）",
  "question": "\(last ? "" : "面接官の次の質問（英語）")"
}
""")
        case .score:
            if !notes.isEmpty {
                lines.append("### 途中の覚え書き（音声を聞いたときのもの）")
                for n in notes { lines.append("- \(n)") }
                lines.append("")
            }
            lines.append("試験は終わりです。ここまでの書き起こしと覚え書きから、speech・interaction・grammar を採点してください（pronunciation は音声を聞いたときの点を使うので不要）。")
            lines.append("\"model\" は、学習者の立場と理由をできるだけ活かして、1 級の合格水準のスピーチに組み直したもの（英語・約 230〜270 語・2 分で話せる長さ・導入で立場→理由 2 つ→結論）。学習者が言えなかった具体例は自然に補ってよい。")
            lines.append("\"fixes\" は、スピーチと答えの中のはっきりした誤りや不自然な言い回しを 3〜5 件（言った形→直した形）。\"phrases\" は、このトピックや似た話題で次に使える言い回しを 3〜4 件（\"said\" に日本語の意味、\"ways\" に英語 1 つ）。")
            lines.append("""
{
  "scores": {
    "speech": { "score": 0, "comment": "日本語で 1〜2 文" },
    "interaction": { "score": 0, "comment": "日本語で 1〜2 文" },
    "grammar": { "score": 0, "comment": "日本語で 1〜2 文" }
  },
  "summary": "トラさんの総評（日本語・2〜3 文。まず実際に言えたことを 1 つ引いて認め、次にいちばん伸ばすべき点を 1 つ）",
  "fixes": [ { "type": "grammar", "original": "言った形", "suggestion": "直した形", "reason": "一言（日本語）" } ],
  "model": "組み直したスピーチ（英語）",
  "phrases": [ { "said": "日本語の意味", "ways": ["英語の言い回し"] } ]
}
""")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 応答の解釈

    static func clampScore(_ any: Any?) -> Int {
        let n: Int
        if let i = any as? Int { n = i } else if let d = any as? Double { n = Int(d.rounded()) } else if let s = any as? String, let i = Int(s) { n = i } else { n = 0 }
        return Swift.max(0, Swift.min(10, n))
    }

    static func object(_ raw: String?) -> [String: Any]? {
        guard let json = Logic.extractJsonObject(raw), let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func parseTurn(_ raw: String?) -> ExamTurn? {
        guard let obj = object(raw) else { return nil }
        var t = ExamTurn()
        t.heard = Logic.asText(obj["heard"])
        t.question = Logic.asText(obj["question"])
        t.note = Logic.asText(obj["note"])
        if let p = obj["pronunciation"] as? [String: Any] {
            t.pronunciation = ExamScore(key: "pronunciation", score: clampScore(p["score"]), comment: Logic.asText(p["comment"]))
        }
        if t.heard.isEmpty && t.question.isEmpty { return nil }
        return t
    }

    /// pronunciation はスピーチのときの点を渡す（無ければ 0 点・コメントなし）
    public static func parseResult(_ raw: String?, pronunciation: ExamScore?) -> ExamResult? {
        guard let obj = object(raw), let s = obj["scores"] as? [String: Any] else { return nil }
        var r = ExamResult()
        for c in criteria {
            if c.key == "pronunciation" {
                r.scores.append(pronunciation ?? ExamScore(key: c.key, score: 0, comment: ""))
            } else {
                let d = s[c.key] as? [String: Any] ?? [:]
                r.scores.append(ExamScore(key: c.key, score: clampScore(d["score"]), comment: Logic.asText(d["comment"])))
            }
        }
        r.summary = Logic.asText(obj["summary"])
        r.model = Logic.asText(obj["model"])
        r.fixes = ((obj["fixes"] as? [Any]) ?? []).compactMap { f -> Issue? in
            guard let d = f as? [String: Any] else { return nil }
            let original = Logic.asText(d["original"]), suggestion = Logic.asText(d["suggestion"])
            guard !suggestion.isEmpty, PhraseLogic.phraseKey(original) != PhraseLogic.phraseKey(suggestion) else { return nil }
            let type = Logic.asText(d["type"])
            return Issue(type: Logic.types.contains(type) ? type : "phrasing", original: original.isEmpty ? nil : original,
                         suggestion: suggestion, reason: Logic.asText(d["reason"]))
        }
        r.fixes = Array(r.fixes.prefix(5))
        r.phrases = ((obj["phrases"] as? [Any]) ?? []).compactMap { a -> Ask? in
            guard let d = a as? [String: Any] else { return nil }
            let ways = Logic.asStringArray(d["ways"])
            guard !ways.isEmpty else { return nil }
            return Ask(said: Logic.asText(d["said"]), ways: ways, ipa: [], note: "")
        }
        r.phrases = Array(r.phrases.prefix(4))
        return r
    }

    // MARK: - 記録にするとき

    /// 履歴に残す一言（点と総評）。会話の記録の good 欄に入れる
    public static func recordGood(_ r: ExamResult) -> String {
        let parts = r.scores.map { "\(label($0.key)) \($0.score)" }.joined(separator: "・")
        return "英検 1 級 2 次の練習 \(r.total)/\(ExamResult.max)（\(parts)）。\(r.summary)"
    }
}

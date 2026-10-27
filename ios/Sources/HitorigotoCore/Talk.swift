import Foundation

// 「三人で話す」: ネイティブ役（友だちの友だち）とトラさん（通訳役の友だち）と学習者の三者会話。
// 学習者は話す言語で頑張り、出てこなければ日本語で言ったりトラさんに聞いたりする。
// 1 ターンごとに学習者の音声（短い）とこれまでの会話（文字）を Gemini に送り、二人ぶんの返事を JSON で受け取る。
// 添削の指示文（Prompts.swift・JS から機械生成）とは別物。アプリ版だけの機能なので、ここが正本。
// 中継サーバーでは添削とは別の回数で数える（/v1/talk）

/// 会話の 1 行。who は native（ネイティブ役）／tora（トラさん）／me（学習者）
public struct TalkLine: Codable, Equatable, Sendable, Identifiable {
    public var who: String
    public var text: String
    /// native: 返事の訳（説明の言語）。me: 自然な言い方に直した形（元と同じなら空）。tora: "hint" なら「なんて言えばいい？」への答え
    public var sub: String
    /// tora: 「日本語で言った分、英語ならこう」。me: 使わない
    public var asks: [Ask]
    /// me: この発言への直し（会話の邪魔をしないよう、終わってからまとめて出す）
    public var fixes: [Issue]
    /// 印。me: "repeat_ok"（トラさんの言い方を言い直せた）／"repeat_ng"（言い直したが違った）。それ以外は空
    public var tag: String

    public var id: String { "\(who):\(text.hashValue):\(sub.hashValue)" }

    public init(who: String, text: String, sub: String = "", asks: [Ask] = [], fixes: [Issue] = [], tag: String = "") {
        self.who = who; self.text = text; self.sub = sub; self.asks = asks; self.fixes = fixes; self.tag = tag
    }

    enum CodingKeys: String, CodingKey { case who, text, sub, asks, fixes, tag }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        who = try c.decodeIfPresent(String.self, forKey: .who) ?? "me"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        sub = try c.decodeIfPresent(String.self, forKey: .sub) ?? ""
        asks = try c.decodeIfPresent([Ask].self, forKey: .asks) ?? []
        fixes = try c.decodeIfPresent([Issue].self, forKey: .fixes) ?? []
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(who, forKey: .who); try c.encode(text, forKey: .text); try c.encode(sub, forKey: .sub)
        try c.encode(asks, forKey: .asks); try c.encode(fixes, forKey: .fixes)
        if !tag.isEmpty { try c.encode(tag, forKey: .tag) }
    }

    /// トラさんがくれた言い方（この行が tora のとき）
    public var ways: [String] { asks.flatMap(\.ways) }
}

/// 前回の会話の覚え書き。翌日の Sam が「昨日の話」として振れるように渡す（復習を会話の中に溶かす）
public struct TalkReview: Equatable, Sendable {
    /// いつの話か（「昨日」「3 日前」など、指示文にそのまま入れる）
    public var when: String
    /// 学習者が前回話した中身（学習者の発言をつないで短く）
    public var summary: String
    /// 前回トラさんに助けてもらった言い方・直された形。今回の会話で自然に出せるように振る
    public var phrases: [String]

    public init(when: String, summary: String, phrases: [String]) { self.when = when; self.summary = summary; self.phrases = phrases }

    /// 直近の会話の記録から作る。古すぎる（maxDays より前）なら nil
    public static func from(sessions: [Session], today: String, maxDays: Int = 14) -> TalkReview? {
        guard let s = sessions.first(where: { $0.talk != nil && !($0.transcript ?? "").isEmpty }) else { return nil }
        // id は UTC の ISO 日時。日本の朝の会話は UTC では前日なので、端末の日付に直してから数える
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter()
        let day = (f.date(from: s.id) ?? g.date(from: s.id)).map { Logic.todayStamp($0) } ?? String(s.id.prefix(10))
        let days = PhraseLogic.daysBetween(day, today)
        guard days >= 0, days <= maxDays else { return nil }
        let when = days == 0 ? "さっき" : (days == 1 ? "昨日" : "\(days) 日前")
        var phrases: [String] = []
        for a in s.asks ?? [] { if let w = a.ways.first { phrases.append(w) } }
        for i in s.issues { phrases.append(i.suggestion) }
        var seen = Set<String>()
        phrases = phrases.filter { seen.insert(PhraseLogic.phraseKey($0)).inserted }
        let summary = String((s.correctedText ?? s.transcript ?? "").replacingOccurrences(of: "\n", with: " ").prefix(300))
        return TalkReview(when: when, summary: summary, phrases: Array(phrases.prefix(6)))
    }
}

/// Gemini から返る 1 ターンぶん
public struct TalkTurn: Equatable, Sendable {
    /// 学習者が言ったこと（聞こえたまま。日本語の部分は日本語）
    public var heard: String
    /// 学習者の発言を自然な言い方にした形（日本語で言った部分も訳して）。言う前の最初のターンでは空
    public var corrected: String
    /// ネイティブ役の返事（話す言語）
    public var reply: String
    /// 返事の訳（説明の言語）
    public var replySub: String
    /// トラさんの一言（口を出すときだけ）
    public var help: String
    /// 日本語で言った分 → 英語ならこう
    public var asks: [Ask]
    /// 学習者の発言への直し（はっきりした誤りだけ・少なめ）
    public var fixes: [Issue]
    /// 会話を終えるときのトラさんの締めの言葉
    public var good: String
    /// 「言ってみる」のターンで、トラさんの言い方をちゃんと言えたか
    public var saidOk: Bool

    public init(heard: String = "", corrected: String = "", reply: String = "", replySub: String = "", help: String = "",
                asks: [Ask] = [], fixes: [Issue] = [], good: String = "", saidOk: Bool = false) {
        self.heard = heard; self.corrected = corrected; self.reply = reply; self.replySub = replySub; self.help = help
        self.asks = asks; self.fixes = fixes; self.good = good; self.saidOk = saidOk
    }
}

public enum Talk {

    /// 何をしてほしいターンか
    public enum Request: Equatable, Sendable {
        /// 会話のはじまり。ネイティブ役が最初の一言（話題）を出す。rerun が空でなければ「同じ会話をもう一回」
        case open(topic: String, rerun: [TalkLine] = [])
        /// 学習者が話した（音声つき）
        case speak
        /// 言ってみる: トラさんがくれた言い方（ways）を学習者が口に出した（音声つき）。Sam は相づちと直前の質問の言い直しだけ
        case `repeat`(ways: [String])
        /// 「なんて言えばいい？」: トラさんが次に言えそうなことを 2 つ出す
        case hint
        /// 会話を終える。トラさんの締めの一言
        case close
    }

    /// ネイティブ役の名前（言語ごと）
    public static func nativeName(_ language: TargetLanguage) -> String {
        switch language {
        case .enUS, .enGB: return "Sam"
        case .esES, .esMX: return "Lucía"
        case .jaJP: return "ゆき"
        }
    }

    /// 話題の種（学習者が決めていないときに 1 つ引く）。ネイティブ役はここから自然に切り出す
    public static let topics: [String] = [
        "今日あったこと", "最近食べたおいしいもの", "飼っている（飼ってみたい）動物", "週末の予定", "最近見た動画や番組",
        "仕事や勉強で今いちばん気になっていること", "子どものころの思い出", "行ってみたい場所", "最近買ってよかったもの",
        "朝のルーティン", "好きな季節とその理由", "最近のニュースで気になったこと", "いまはまっていること",
        "住んでいる町のいいところ", "苦手な家事", "最近うれしかった小さなこと", "もし 1 週間休みがもらえたら",
    ]

    /// 会話の中に母語（日本語）の文字があるか。「英語だけで言えた」の数え方に使う
    public static func hasJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            (0x3040...0x30FF).contains(u.value) || (0x4E00...0x9FFF).contains(u.value) || (0xFF66...0xFF9F).contains(u.value)
        }
    }

    // MARK: - 指示文

    /// システム指示。ネイティブ役とトラさんの二人を 1 回の応答で演じ分けさせる
    public static func system(language: TargetLanguage, explanation: TargetLanguage.Explanation = TargetLanguage.explanation) -> String {
        let lang = language.promptName
        let native = nativeName(language)
        let mother = explanation == .ja ? "日本語" : "英語"
        var s = """
あなたは「独り言」アプリの会話練習で、**二人の人物を同時に演じます**。学習者を入れて三人の会話です。

## 場面
学習者は\(lang)を学んでいて、母語は\(mother)です。\(lang)で話そうと頑張っていますが、言葉が出てこないと\(mother)で言ったり、友だちのトラさんに「これ、\(lang)で何て言う？」と聞いたりします。
三人で気楽におしゃべりをしている場面です。試験でも授業でもありません。

\(language.variantNote)

## 1 人目: \(native)（ネイティブ役）
- \(lang)のネイティブスピーカー。トラさんの友だちで、学習者とは今日仲良くなったところ。気さくで聞き上手。
- \(mother)は分かりません。学習者が\(mother)で言った部分は、トラさんが訳して伝えてくれたものとして、その**中身**に返事をします（訳の話はしない）。
- 返事は\(lang)だけで、1〜3 文。必ず最後は質問か、話を広げる一言で、学習者に話す番を渡す。
- 学習者の言い間違いは指摘しない。代わりに、返事の中で正しい形を自然に使って返す（さりげなく）。
- 学習者のレベルに合わせて平易に話す。難しい語を使ったら、言い換えを添える。
- 同じ質問を繰り返さない。学習者が言ったことを拾って、そこから広げる。

## 2 人目: 寅吉（トラさん・通訳役）
- \(mother)と\(lang)の両方ができる学習者の友だち。下町のボクシングジムの老トレーナーで、一人称は「わし」、学習者は「おめえ」、べらんめえ調。叱らない。この場では面倒見のいい通訳役。
- **出しゃばらない。** 口を出すのは次のときだけ: (a) 学習者が\(mother)で言った部分がある (b) 学習者が「トラさん」と呼びかけて聞いた (c) 学習者が明らかに詰まって短く終わった (d) 「なんて言えばいい？」と頼まれた
- 口を出すときは "help" に\(mother)で 1〜2 文だけ。言い方そのものは "asks" に入れる（1 件につき "ways" を 1〜2 通り・学習者が言える長さで）。
- 学習者が\(lang)だけで話せたターンでは "help" は空、"asks" は空配列。

## 直し（"fixes"）
- 学習者の今回の発言のうち、**意味が変わる・明らかな誤り**だけを 0〜2 件。言い回しの好みや細かい冠詞は入れない。会話の邪魔をしないよう、学習者には会話が終わってからまとめて見せる。
- "reason" は\(mother)で 1 文、トラさんの口調。
- "corrected" は学習者の今回の発言を、自然な\(lang)にしたもの（\(mother)で言った部分も\(lang)にする）。トラさんへの質問（「〜って何て言う？」）の部分は入れない。発言が無いターンは空。

## 言ってみる（"repeat" のターン）
- トラさんが言い方を出したあと、学習者はそれを**その場で口に出す**練習をします。メッセージに「言ってみる」とあるターンがそれです。
- "heard" に書き起こし、"said_ok" に、出した言い方のどれかを（細かい違いは許して）言えていれば true、言えていなければ false。
- \(native) の "reply" は短い相づち 1 文のあと、**直前に自分がした質問をもう一度 1 文で**（新しい質問はしない。学習者はこれから答える）。
- "help" は言えていなければ、どこが違ったかを\(mother)で 1 文だけ。言えていれば空。"asks"・"fixes" は空配列。

## 聞こえた内容（"heard"）
- 音声が届いたら、学習者が言ったことをそのまま書き起こす。\(mother)の部分は\(mother)のまま。言い直し・つなぎの音（uh, um）は省いてよい。
- 聞き取れる発話が無ければ "heard" を空にし、\(native) は "Sorry, I didn't catch that." のように聞き返す。

## 出力
次の JSON だけを返す。前後に説明や ``` を付けない。
{
  "heard": "学習者が言ったこと",
  "corrected": "学習者の発言を自然な\(lang)にした形",
  "reply": "\(native) の返事（\(lang)だけ）",
  "reply_sub": "返事の\(mother)訳（短く）",
  "help": "トラさんの一言（\(mother)・口を出すときだけ。無ければ空文字）",
  "asks": [ { "said": "\(mother)で言ったこと（短く）", "ways": ["いちばん自然な言い方", "別の言い方"], "ipa": ["/発音記号/", "/発音記号/"], "note": "使いどころの一言（\(mother)・トラさんの口調）" } ],
  "fixes": [ { "type": "grammar", "original": "言った形", "suggestion": "直した形", "reason": "一言（\(mother)）" } ],
  "good": "",
  "said_ok": false
}
- "reply"・"corrected"・"ways"・"suggestion" は\(lang)だけ。口調を持ち込まず、自然で正しい\(lang)で。
- "ipa" は "ways" と同じ順で、\(lang)の発音記号。学習者が目指す地域の発音で、全体を /.../ で囲む。
- "type" は grammar / vocabulary / phrasing のどれか。
"""
        if explanation == .en {
            s += """

## 出力言語の上書き（最優先）
- "reply_sub"・"help"・"note"・"reason"・"good" は**日本語ではなく英語**で書く。読む学習者は日本語が読めない。
- トラさんの口調は英語で（a gruff but kind old boxing-gym trainer: blunt and short）。
"""
        }
        return s
    }

    /// ユーザーメッセージ。これまでの会話を文字で渡し、今回なにをしてほしいかを最後に書く
    public static func userMessage(request: Request, history: [TalkLine], language: TargetLanguage, targets: [String] = [],
                                   review: TalkReview? = nil,
                                   explanation: TargetLanguage.Explanation = TargetLanguage.explanation) -> String {
        let native = nativeName(language)
        let lang = language.promptName
        let mother = explanation == .ja ? "日本語" : "英語"
        var lines: [String] = []
        if let review, !review.summary.isEmpty || !review.phrases.isEmpty {
            // 翌日の Sam が「昨日の話」を振る。本人にはただの会話の続きに見えて、中身は前回の復習
            lines.append("## 前回の会話（\(review.when)）")
            lines.append("\(native) は前回の話を覚えている友だちです。はじまりの一言で前回の話に軽く触れ、その続きや近況を聞いてください。")
            if !review.summary.isEmpty { lines.append("学習者が前回話した中身: \(review.summary)") }
            if !review.phrases.isEmpty {
                lines.append("前回トラさんに助けてもらった言い方・直された形（今回の会話で学習者が自然に使える場面を作る。無理に寄せない・\"asks\" に入れない・学習者が使えてもトラさんは口を出さない）:")
                for p in review.phrases { lines.append("- \(p)") }
            }
            lines.append("")
        }
        if !targets.isEmpty {
            lines.append("## 学習者が今日使ってみたい表現")
            lines.append("会話の流れで自然に使える場面があれば、\(native) はそれが出せるような話の振り方をしてください（無理に寄せない・この表現を \"asks\" に入れない）。")
            for t in targets.prefix(6) { lines.append("- \(t)") }
            lines.append("")
        }
        if !history.isEmpty {
            lines.append("## ここまでの会話（古い順）")
            for l in history.suffix(16) {
                switch l.who {
                case "native": lines.append("\(native): \(l.text)")
                case "tora": lines.append("トラさん: \(l.text)" + (l.asks.isEmpty ? "" : "（言い方: " + l.asks.flatMap(\.ways).joined(separator: " / ") + "）"))
                default: lines.append("学習者: \(l.text)")
                }
            }
            lines.append("")
        }
        lines.append("## 今回")
        switch request {
        case .open(let topic, let rerun):
            if rerun.isEmpty {
                lines.append("会話のはじまりです。学習者はまだ何も言っていません。\(native) が挨拶を 1 文と、次の話題について軽い質問を 1 つ出してください: \(topic)")
            } else {
                // 同じ会話をもう一回（今度は助けなしで）。同じ話を繰り返すと流暢さが伸びる（task repetition）
                lines.append("さっきの会話を**もう一度同じ流れで**やる練習です。\(native) は、さっきと同じ質問を同じ順で振ってください（言い回しは少し変えてよい）。はじまりは「もう一回やってみよう」の一言と、さっきの最初の質問。トラさんは、学習者が\(mother)で言うか呼びかけるまで黙っていてください。")
                lines.append("### さっきの会話")
                for l in rerun.suffix(16) {
                    switch l.who {
                    case "native": lines.append("\(native): \(l.text)")
                    case "tora": lines.append("トラさん:（言い方: " + l.ways.joined(separator: " / ") + "）")
                    default: lines.append("学習者: \(l.text)")
                    }
                }
            }
            lines.append("\"heard\"・\"corrected\"・\"help\"・\"fixes\"・\"good\" は空、\"asks\" は空配列にしてください。")
        case .repeat(let ways):
            lines.append("言ってみる: 添付の音声は、学習者がトラさんの言い方を口に出したものです。出した言い方: " + ways.joined(separator: " / "))
            lines.append("\"heard\" に書き起こし、\"said_ok\" に言えたかどうか。\"reply\" は相づち 1 文＋直前の質問の言い直し 1 文。\"corrected\"・\"good\" は空、\"asks\"・\"fixes\" は空配列にしてください。")
        case .speak:
            lines.append("添付の音声が学習者の今回の発言です。\"heard\" に書き起こし、\(native) の返事と、必要ならトラさんの助けを返してください。")
        case .hint:
            lines.append("学習者が「なんて言えばいい？」とトラさんに頼みました。\(native) の直前の発言に対して、学習者が言えそうなことを **2 つ**、\(mother)の意味（\"said\"）と\(lang)の言い方（\"ways\" は 1 つずつ）で \"asks\" に入れてください。短くて言える長さに。")
            lines.append("\"help\" にはトラさんの一言（「こう言ってみな」程度）。\"heard\"・\"corrected\"・\"reply\"・\"reply_sub\"・\"good\" は空、\"fixes\" は空配列にしてください。")
        case .close:
            lines.append("学習者が会話を終えます。\(native) は短い別れの一言を \"reply\" に（質問はしない）。トラさんは \"good\" に、今日の会話で学習者が実際に\(lang)で言えたことを 1 つ引いて、短く褒める一言を\(mother)で書いてください（口調はトラさん・2 文まで）。")
            lines.append("\"heard\"・\"corrected\"・\"help\" は空、\"asks\"・\"fixes\" は空配列にしてください。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 応答の解釈

    public static let maxFixes = 2
    public static let maxAsks = 3

    public static func parse(_ raw: String?) -> TalkTurn? {
        guard let json = Logic.extractJsonObject(raw), let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var t = TalkTurn()
        t.heard = Logic.asText(obj["heard"])
        t.corrected = Logic.asText(obj["corrected"])
        t.reply = Logic.asText(obj["reply"])
        t.replySub = Logic.asText(obj["reply_sub"])
        t.help = Logic.asText(obj["help"])
        t.good = Logic.asText(obj["good"])
        t.saidOk = Logic.truthy(obj["said_ok"])
        t.asks = ((obj["asks"] as? [Any]) ?? []).compactMap { a -> Ask? in
            guard let d = a as? [String: Any] else { return nil }
            let ways = Logic.asStringArray(d["ways"])
            guard !ways.isEmpty else { return nil }
            return Ask(said: Logic.asText(d["said"]), ways: ways, ipa: (d["ipa"] as? [Any])?.map { Logic.asText($0) } ?? [], note: Logic.asText(d["note"]))
        }
        t.asks = Array(t.asks.prefix(maxAsks))
        t.fixes = ((obj["fixes"] as? [Any]) ?? []).compactMap { f -> Issue? in
            guard let d = f as? [String: Any] else { return nil }
            let original = Logic.asText(d["original"]), suggestion = Logic.asText(d["suggestion"])
            guard !suggestion.isEmpty, PhraseLogic.phraseKey(original) != PhraseLogic.phraseKey(suggestion) else { return nil }
            let type = Logic.asText(d["type"])
            return Issue(type: Logic.types.contains(type) ? type : "phrasing", original: original.isEmpty ? nil : original,
                         suggestion: suggestion, reason: Logic.asText(d["reason"]))
        }
        t.fixes = Array(t.fixes.prefix(maxFixes))
        // 空の応答（何も入っていない）は読めなかったのと同じ
        if t.heard.isEmpty && t.reply.isEmpty && t.help.isEmpty && t.asks.isEmpty && t.good.isEmpty { return nil }
        return t
    }

    // MARK: - 記録にするとき

    /// 会話を 1 回の記録（Session）にする。transcript は学習者の発言だけ（添削文との突き合わせに使う欄なので）、
    /// 会話そのものは talk に残す。直しと「英語ならこう」は会話全体から集める（同じものは 1 回）
    public static func makeSession(id: String, lines: [TalkLine], good: String, engine: String) -> Session {
        let mine = lines.filter { $0.who == "me" && !$0.text.isEmpty && !$0.tag.hasPrefix("repeat") }
        var s = Session(id: id, transcript: mine.map(\.text).joined(separator: "\n"),
                        correctedText: mine.map { $0.sub.isEmpty ? $0.text : $0.sub }.joined(separator: "\n"),
                        issues: [], good: good.isEmpty ? nil : good, engine: engine)
        var seen = Set<String>()
        var issues: [Issue] = []
        for l in mine { for f in l.fixes {
            let k = PhraseLogic.phraseKey(f.original ?? "") + "→" + PhraseLogic.phraseKey(f.suggestion)
            if seen.insert(k).inserted { issues.append(f) }
        } }
        s.issues = issues
        var askSeen = Set<String>()
        var asks: [Ask] = []
        for l in lines where l.who == "tora" { for a in l.asks where !a.said.isEmpty {
            if askSeen.insert(PhraseLogic.phraseKey(a.said)).inserted { asks.append(a) }
        } }
        if !asks.isEmpty { s.asks = asks }
        s.talk = lines
        return s
    }

    /// 進み具合。英語（話す言語）だけで言えた発言の数、母語を混ぜた・トラさんに頼った数、もらった言い方をその場で言い直せた数
    public struct Tally: Equatable, Sendable {
        public var alone = 0, helped = 0, repeated = 0
        public init(alone: Int = 0, helped: Int = 0, repeated: Int = 0) { self.alone = alone; self.helped = helped; self.repeated = repeated }
    }

    public static func tally(_ lines: [TalkLine], nativeLanguageIsJapanese: Bool) -> Tally {
        var t = Tally()
        var pendingHelp = false
        for l in lines {
            // 「なんて言えばいい？」でもらった言い方のあとの発言は、助けてもらった分に数える
            if l.who == "tora" { if l.sub == "hint" && !l.asks.isEmpty { pendingHelp = true }; continue }
            guard l.who == "me", !l.text.isEmpty else { continue }
            // 言い直しのターンは「言えた／言えなかった」の数だけ（会話の発言とは分ける）
            if l.tag == "repeat_ok" { t.repeated += 1; continue }
            if l.tag == "repeat_ng" { continue }
            let mixed = nativeLanguageIsJapanese ? hasJapanese(l.text) : false
            if mixed || pendingHelp { t.helped += 1 } else { t.alone += 1 }
            pendingHelp = false
        }
        return t
    }
}

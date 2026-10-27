import Foundation

// 拡張機能の chrome.storage.local と同じ形で持つ。
// 書き出し／読み込み（hitorigoto-english-v1）をそのまま通すため、キー名は JS 側と一字一句そろえる。

/// 添削の指摘 1 件
public struct Issue: Codable, Equatable, Sendable {
    public var type: String          // phrasing | vocabulary | grammar
    public var original: String?     // 畳んだ古い記録には無い
    public var suggestion: String
    public var reason: String?

    public init(type: String, original: String? = nil, suggestion: String, reason: String? = nil) {
        self.type = type; self.original = original; self.suggestion = suggestion; self.reason = reason
    }
}

/// 発音で伝わらなかった箇所（音声モードだけ）
public struct Pronunciation: Codable, Equatable, Sendable {
    public var said: String
    public var heardAs: String
    public var note: String

    enum CodingKeys: String, CodingKey { case said, heardAs = "heard_as", note }

    public init(said: String, heardAs: String, note: String = "") {
        self.said = said; self.heardAs = heardAs; self.note = note
    }
}

/// 日本語で言った分（英語が出てこなかったところ）→ 英語ならこう言う
public struct Ask: Codable, Equatable, Sendable {
    public var said: String
    public var ways: [String]
    /// ways と同じ長さ。i 番目の言い方の発音記号（IPA）。無いときは空文字
    public var ipa: [String]
    public var note: String

    public init(said: String, ways: [String], ipa: [String] = [], note: String = "") {
        self.said = said; self.ways = ways; self.note = note
        self.ipa = ways.indices.map { i in i < ipa.count ? ipa[i] : "" }
    }

    enum CodingKeys: String, CodingKey { case said, ways, ipa, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ways = try c.decodeIfPresent([String].self, forKey: .ways) ?? []
        self.init(said: try c.decodeIfPresent(String.self, forKey: .said) ?? "", ways: ways,
                  ipa: try c.decodeIfPresent([String].self, forKey: .ipa) ?? [],
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "")
    }
}

/// 「今日の狙いの表現」の AI 判定
public struct Target: Codable, Equatable, Sendable {
    public var phrase: String
    public var used: Bool
    public var exact: Bool
    public var asSaid: String
    public var note: String

    enum CodingKeys: String, CodingKey { case phrase, used, exact, asSaid = "as_said", note }

    public init(phrase: String, used: Bool, exact: Bool, asSaid: String = "", note: String = "") {
        self.phrase = phrase; self.used = used; self.exact = exact; self.asSaid = asSaid; self.note = note
    }
}

/// 「直すべし」に入りきらなかった直し（コーチが理由を一言つける）
public struct Fix: Codable, Equatable, Sendable {
    public var original: String
    public var suggestion: String
    public var note: String

    public init(original: String, suggestion: String, note: String = "") {
        self.original = original; self.suggestion = suggestion; self.note = note
    }
}

/// AI の応答を、表示と保存が前提にできる形に揃えたもの（JS の parseFeedback の結果）
public struct Feedback: Codable, Equatable, Sendable {
    public var correctedText: String
    public var issues: [Issue]
    public var moreFixes: [Fix]
    public var recurring: [String]
    public var recognitionDoubt: [String]
    public var good: String
    public var transcript: String            // 音声モードだけ
    public var pronunciation: [Pronunciation]
    public var targets: [Target]
    public var asks: [Ask]

    enum CodingKeys: String, CodingKey {
        case correctedText = "corrected_text", issues, moreFixes = "more_fixes", recurring
        case recognitionDoubt = "recognition_doubt", good, transcript, pronunciation, targets, asks
    }

    public init(correctedText: String = "", issues: [Issue] = [], moreFixes: [Fix] = [], recurring: [String] = [],
                recognitionDoubt: [String] = [], good: String = "", transcript: String = "",
                pronunciation: [Pronunciation] = [], targets: [Target] = [], asks: [Ask] = []) {
        self.correctedText = correctedText; self.issues = issues; self.moreFixes = moreFixes; self.recurring = recurring
        self.recognitionDoubt = recognitionDoubt; self.good = good; self.transcript = transcript
        self.pronunciation = pronunciation; self.targets = targets; self.asks = asks
    }
}

/// 履歴に残す「その日の今日の表現の結果」
public struct SessionTarget: Codable, Equatable, Sendable {
    public var phrase: String
    public var r: String     // hit | partial | miss | skip
    public var `as`: String

    public init(phrase: String, r: String, as: String = "") { self.phrase = phrase; self.r = r; self.as = `as` }
}

/// 練習 1 回の記録。id は ISO 日時（新しい順に並べる）
public struct Session: Codable, Equatable, Sendable {
    public var id: String
    public var folded: Bool?
    public var transcript: String?
    public var asrTranscript: String?
    public var correctedText: String?
    public var issues: [Issue]
    /// 「直すべし」に入りきらなかった直し（理由つき）。2026-10-17 から。それより前の記録には無い
    public var moreFixes: [Fix]?
    public var good: String?
    public var pronunciation: [Pronunciation]?
    public var targets: [SessionTarget]?
    /// 日本語で言った分 → 英語ならこう。無いセッションでは nil
    public var asks: [Ask]?
    /// アプリ版だけ: どのエンジンで添削したか（gemini / apple）。拡張の記録には無い
    public var engine: String?
    /// アプリ版だけ: 「トラさんに詳しく聞く」のやり取り（直しごと）
    public var explains: [ExplainThread]?
    /// アプリ版だけ: 「三人で話す」の会話そのもの（ネイティブ役・トラさん・学習者の順に並ぶ）。独り言の記録では nil
    public var talk: [TalkLine]?

    enum CodingKeys: String, CodingKey {
        case id, folded, transcript, asrTranscript = "asr_transcript", correctedText = "corrected_text"
        case issues, moreFixes = "more_fixes", good, pronunciation, targets, asks, engine, explains, talk
    }

    public init(id: String, folded: Bool? = nil, transcript: String? = nil, asrTranscript: String? = nil,
                correctedText: String? = nil, issues: [Issue] = [], good: String? = nil,
                pronunciation: [Pronunciation]? = nil, targets: [SessionTarget]? = nil, asks: [Ask]? = nil,
                engine: String? = nil) {
        self.id = id; self.folded = folded; self.transcript = transcript; self.asrTranscript = asrTranscript
        self.correctedText = correctedText; self.issues = issues; self.good = good
        self.pronunciation = pronunciation; self.targets = targets; self.asks = asks; self.engine = engine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folded = try c.decodeIfPresent(Bool.self, forKey: .folded)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        asrTranscript = try c.decodeIfPresent(String.self, forKey: .asrTranscript)
        correctedText = try c.decodeIfPresent(String.self, forKey: .correctedText)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        moreFixes = try c.decodeIfPresent([Fix].self, forKey: .moreFixes)
        good = try c.decodeIfPresent(String.self, forKey: .good)
        pronunciation = try c.decodeIfPresent([Pronunciation].self, forKey: .pronunciation)
        targets = try c.decodeIfPresent([SessionTarget].self, forKey: .targets)
        asks = try c.decodeIfPresent([Ask].self, forKey: .asks)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        explains = try c.decodeIfPresent([ExplainThread].self, forKey: .explains)
        talk = try c.decodeIfPresent([TalkLine].self, forKey: .talk)
    }
}

/// 繰り返し出ている指摘（"original → suggestion" をキーに数える）
public struct Recurring: Codable, Equatable, Sendable {
    public var text: String
    public var count: Int
    public var lastSeen: String

    enum CodingKeys: String, CodingKey { case text, count, lastSeen = "last_seen" }

    public init(text: String, count: Int, lastSeen: String) { self.text = text; self.count = count; self.lastSeen = lastSeen }
}

/// 表現集の 1 件の履歴（d: 日付、r: hit|partial|miss|skip|rok|rng、as: 口から出た形）
public struct PhraseHistory: Codable, Equatable, Sendable {
    public var d: String
    public var r: String
    public var `as`: String?

    public init(d: String, r: String, as: String? = nil) { self.d = d; self.r = r; self.as = `as` }
}

/// 表現集の 1 件（phrase-core.js の makePhrase と同じ形）
public struct PhraseCard: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var phrase: String
    public var meaning: String
    public var note: String
    public var kind: String        // phrase | word
    public var source: String      // manual | issue
    public var added: String
    public var due: String?        // 卒業したら nil
    public var hits: Int
    public var status: String      // active | graduated | archived
    public var history: [PhraseHistory]
    public var manual: String?     // graduated | active（手で押した記録）
    /// 例文（英文と訳を改行でつなぐ）。スクショから入れたときに付く。アプリ版だけの欄（拡張・Android は読み飛ばす）
    public var example: String?
    /// 元のスクショのファイル名（端末の phrase-images に置き、iCloud には添付ファイルとして送る）。アプリ版だけの欄
    public var image: String?

    public init(id: String, phrase: String, meaning: String = "", note: String = "", kind: String = "phrase",
                source: String = "manual", added: String, due: String?, hits: Int = 0, status: String = "active",
                history: [PhraseHistory] = [], manual: String? = nil, example: String? = nil, image: String? = nil) {
        self.id = id; self.phrase = phrase; self.meaning = meaning; self.note = note; self.kind = kind
        self.source = source; self.added = added; self.due = due; self.hits = hits; self.status = status
        self.history = history; self.manual = manual; self.example = example; self.image = image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        phrase = try c.decode(String.self, forKey: .phrase)
        meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "phrase"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        added = try c.decodeIfPresent(String.self, forKey: .added) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due)
        hits = try c.decodeIfPresent(Int.self, forKey: .hits) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        history = try c.decodeIfPresent([PhraseHistory].self, forKey: .history) ?? []
        manual = try c.decodeIfPresent(String.self, forKey: .manual)
        example = try c.decodeIfPresent(String.self, forKey: .example)
        image = try c.decodeIfPresent(String.self, forKey: .image)
    }
}

/// 今日の表現の判定 1 件
public struct TodayResult: Codable, Equatable, Sendable {
    public var r: String
    public var `as`: String
    public var note: String
    public var judge: String   // auto | ai | manual

    public init(r: String, as: String = "", note: String = "", judge: String = "auto") {
        self.r = r; self.as = `as`; self.note = note; self.judge = judge
    }
}

/// 今日の表現（日をまたいだら選び直す）
public struct Today: Codable, Equatable, Sendable {
    public var date: String
    public var ids: [String]
    public var results: [String: TodayResult]

    public init(date: String, ids: [String] = [], results: [String: TodayResult] = [:]) {
        self.date = date; self.ids = ids; self.results = results
    }
}

/// 判定の結果（judgePhrases の 1 件）
public struct Judged: Equatable, Sendable {
    public var id: String
    public var result: String
    public var asSaid: String
    public var note: String
    public var judge: String

    public init(id: String, result: String, asSaid: String = "", note: String = "", judge: String = "auto") {
        self.id = id; self.result = result; self.asSaid = asSaid; self.note = note; self.judge = judge
    }
}

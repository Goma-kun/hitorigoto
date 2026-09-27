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

/// AI の応答を、表示と保存が前提にできる形に揃えたもの（JS の parseFeedback の結果）
public struct Feedback: Codable, Equatable, Sendable {
    public var correctedText: String
    public var issues: [Issue]
    public var recurring: [String]
    public var recognitionDoubt: [String]
    public var good: String
    public var transcript: String            // 音声モードだけ
    public var pronunciation: [Pronunciation]
    public var targets: [Target]

    enum CodingKeys: String, CodingKey {
        case correctedText = "corrected_text", issues, recurring
        case recognitionDoubt = "recognition_doubt", good, transcript, pronunciation, targets
    }

    public init(correctedText: String = "", issues: [Issue] = [], recurring: [String] = [],
                recognitionDoubt: [String] = [], good: String = "", transcript: String = "",
                pronunciation: [Pronunciation] = [], targets: [Target] = []) {
        self.correctedText = correctedText; self.issues = issues; self.recurring = recurring
        self.recognitionDoubt = recognitionDoubt; self.good = good; self.transcript = transcript
        self.pronunciation = pronunciation; self.targets = targets
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
    public var good: String?
    public var pronunciation: [Pronunciation]?
    public var targets: [SessionTarget]?
    /// アプリ版だけ: どのエンジンで添削したか（gemini / apple）。拡張の記録には無い
    public var engine: String?

    enum CodingKeys: String, CodingKey {
        case id, folded, transcript, asrTranscript = "asr_transcript", correctedText = "corrected_text"
        case issues, good, pronunciation, targets, engine
    }

    public init(id: String, folded: Bool? = nil, transcript: String? = nil, asrTranscript: String? = nil,
                correctedText: String? = nil, issues: [Issue] = [], good: String? = nil,
                pronunciation: [Pronunciation]? = nil, targets: [SessionTarget]? = nil, engine: String? = nil) {
        self.id = id; self.folded = folded; self.transcript = transcript; self.asrTranscript = asrTranscript
        self.correctedText = correctedText; self.issues = issues; self.good = good
        self.pronunciation = pronunciation; self.targets = targets; self.engine = engine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folded = try c.decodeIfPresent(Bool.self, forKey: .folded)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        asrTranscript = try c.decodeIfPresent(String.self, forKey: .asrTranscript)
        correctedText = try c.decodeIfPresent(String.self, forKey: .correctedText)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        good = try c.decodeIfPresent(String.self, forKey: .good)
        pronunciation = try c.decodeIfPresent([Pronunciation].self, forKey: .pronunciation)
        targets = try c.decodeIfPresent([SessionTarget].self, forKey: .targets)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
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

    public init(id: String, phrase: String, meaning: String = "", note: String = "", kind: String = "phrase",
                source: String = "manual", added: String, due: String?, hits: Int = 0, status: String = "active",
                history: [PhraseHistory] = [], manual: String? = nil) {
        self.id = id; self.phrase = phrase; self.meaning = meaning; self.note = note; self.kind = kind
        self.source = source; self.added = added; self.due = due; self.hits = hits; self.status = status
        self.history = history; self.manual = manual
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

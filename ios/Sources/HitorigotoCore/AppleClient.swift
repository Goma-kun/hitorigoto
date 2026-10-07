import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 端末内 AI（Apple Intelligence の Foundation Models）で添削する。**通信もキーも要らず、話した内容が端末の外に出ない。**
/// 拡張機能の createNanoProvider（Chrome 内蔵 AI / Gemini Nano）に相当する。
///
/// - iOS 26 / macOS 26 以降で、Apple Intelligence が有効な端末でだけ動く。それ以外は `availability` が理由を返す
/// - 音声は渡せない（テキストだけ）。端末の音声認識の字幕を入力にする。発音の評価はしない（Nano と同じ設計）
/// - 「今日の狙いの表現」の判定は AI に頼まず、PhraseLogic の文字照合だけで行う（小型モデルなので。Nano と同じ）
/// - 1 セッション 4096 トークン（入力＋出力）。長文の指示は入らないので ApplePrompts の短い版を使う
/// - 応答は @Generable の型で受ける（JSON の崩れが起きない）。受けたあと JSON に戻して Logic.parseFeedback に通し、
///   拡張機能と同じ揃え方（type の正規化・空の指摘の除去）にする
public enum AppleEngine {

    /// 使えるかどうか。画面の案内文に直結する
    public enum Availability: Equatable, Sendable {
        case available
        case unsupportedOS          // iOS 26 / macOS 26 より前、または FoundationModels の無いビルド
        case deviceNotEligible      // Apple Intelligence 非対応の機種
        case notEnabled             // 設定で Apple Intelligence がオフ
        case modelNotReady          // モデルを準備中（ダウンロード中など）
        case unknown(String)
    }

    public enum Failure: Error, Equatable {
        case unavailable(Availability)
        case emptyTranscript        // 字幕が空。端末内 AI は字幕が無いと何もできない
        case tooLong                // 4096 トークンに入りきらない
        case guardrail              // 安全フィルタにかかった
        case unsupportedLanguage
        case parse
        case generation(String)
    }

    /// 応答の 1 件分。@Generable の型から写すための入れ物（テストでも使う）
    public struct DraftIssue: Equatable, Sendable {
        public var type: String
        public var original: String
        public var suggestion: String
        public var reason: String
        public init(type: String, original: String, suggestion: String, reason: String) {
            self.type = type; self.original = original; self.suggestion = suggestion; self.reason = reason
        }
    }

    // MARK: - 使えるか

    public static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unknown(String(describing: reason))
                }
            @unknown default:
                return .unknown("unknown availability")
            }
        }
        #endif
        return .unsupportedOS
    }

    // MARK: - 添削

    /// 先に作っておいたセッション。型は Any にしてある（iOS 17 でも読める型にしておくため。中身は LanguageModelSession）。
    /// 画面（MainActor）からも CLI（hg-probe）からも触るので、ロックで守る
    private static let lock = NSLock()
    private static var warmSession: Any?

    private static func takeWarm() -> Any? {
        lock.lock(); defer { lock.unlock() }
        let s = warmSession; warmSession = nil; return s
    }

    private static func putWarm(_ s: Any?) {
        lock.lock(); defer { lock.unlock() }
        warmSession = s
    }

    /// 録音を始めた時点で呼ぶ。モデルの読み込みを先に済ませ、停止したあとに待たせない（拡張の prewarmNano と同じ）
    public static func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), availability == .available {
            let s = LanguageModelSession(instructions: ApplePrompts.instructions)
            s.prewarm()
            putWarm(s)
        }
        #endif
    }

    /// テキストだけで添削する。transcript は端末の音声認識の字幕
    public static func reviewEnglish(_ transcript: String, recurring: [Recurring]) async throws -> Feedback {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyTranscript }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let state = availability
            guard state == .available else { throw Failure.unavailable(state) }
            // セッションは 1 回で使い捨てる（会話の履歴を積まない。Nano の clone() と同じ考え）
            let session = (takeWarm() as? LanguageModelSession) ?? LanguageModelSession(instructions: ApplePrompts.instructions)
            let prompt = ApplePrompts.userMessage(text, recurring: recurring)
            do {
                let response = try await session.respond(to: prompt, generating: AppleReview.self)
                return try feedback(from: response.content)
            } catch let e as LanguageModelSession.GenerationError {
                throw classify(e)
            } catch let f as Failure {
                throw f
            } catch {
                throw Failure.generation(error.localizedDescription)
            }
        }
        #endif
        throw Failure.unavailable(.unsupportedOS)
    }

    // MARK: - 応答を Feedback に揃える

    /// 応答を JSON に戻して Logic.parseFeedback に通す。**拡張機能と同じ揃え方**にするため、独自に組み立てない
    public static func feedback(correctedText: String, issues: [DraftIssue], recurring: [String],
                                recognitionDoubt: [String], good: String) throws -> Feedback {
        let obj: [String: Any] = [
            "corrected_text": correctedText,
            "issues": issues.map { ["type": $0.type, "original": $0.original, "suggestion": $0.suggestion, "reason": $0.reason] },
            "recurring": recurring,
            "recognition_doubt": recognitionDoubt,
            "good": good,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let raw = String(data: data, encoding: .utf8),
              let fb = Logic.parseFeedback(raw) else { throw Failure.parse }
        return fb
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    static func feedback(from r: AppleReview) throws -> Feedback {
        try feedback(correctedText: r.correctedText,
                     issues: r.issues.map { DraftIssue(type: $0.type.key, original: $0.original, suggestion: $0.suggestion, reason: $0.reason) },
                     recurring: r.recurring, recognitionDoubt: r.recognitionDoubt, good: r.good)
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func classify(_ e: LanguageModelSession.GenerationError) -> Failure {
        switch e {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation: return .guardrail
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .decodingFailure: return .parse
        default: return .generation(e.localizedDescription)
        }
    }
    #endif
}

#if canImport(FoundationModels)
// 端末内 AI に返させる形。parseFeedback が受け取れる JSON と同じ項目（拡張の NANO_REVIEW_SCHEMA に相当）

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum AppleIssueType {
    case phrasing
    case vocabulary
    case grammar

    var key: String {
        switch self {
        case .phrasing: return "phrasing"
        case .vocabulary: return "vocabulary"
        case .grammar: return "grammar"
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "One correction to the learner's English")
struct AppleIssue {
    @Guide(description: "phrasing, vocabulary, or grammar")
    var type: AppleIssueType
    @Guide(description: "The learner's exact words, copied from the transcript")
    var original: String
    @Guide(description: "The corrected English. English only, no Japanese")
    var suggestion: String
    @Guide(description: "Why, in Japanese, one sentence, in the old trainer's voice")
    var reason: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "Feedback on an English learner's monologue")
struct AppleReview {
    @Guide(description: "The whole monologue rewritten as natural, correct English for reading aloud. English only")
    var correctedText: String
    @Guide(description: "Up to 5 corrections, biggest impact first", .maximumCount(5))
    var issues: [AppleIssue]
    @Guide(description: "Habits from the given list that appeared again. Japanese, one short line each, trainer's voice", .maximumCount(5))
    var recurring: [String]
    @Guide(description: "Words that look like speech-recognition errors, copied exactly from the transcript", .maximumCount(5))
    var recognitionDoubt: [String]
    @Guide(description: "One thing done well, in Japanese, one sentence, trainer's voice. Empty if nothing")
    var good: String
}
#endif

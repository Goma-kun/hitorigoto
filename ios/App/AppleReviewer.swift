import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 端末内の AI（Apple Intelligence・Foundation Models）で添削する。**API キーも通信も要らない**。
///
/// Gemini との違い（設計上の割り切り）:
/// - 音声は聞かせられない。端末の音声認識の文字（字幕）を添削する。聞き取りの化けはそのまま残る
/// - モデルが小さく、枠が 4,096 トークンしかない。拡張機能の長いプロンプトは入らないので、短い指示で
///   「褒め・直し（最大 5 件）・直した全文・今日の表現の判定」だけを返させる
/// - 使えるのは iOS 26 / macOS 26 以上で、Apple Intelligence をオンにした端末だけ
enum AppleReviewer {

    enum Status: Equatable {
        case available
        case unavailable(String)    // 理由（設定画面に出す）
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable(String(localized: "この端末は Apple Intelligence に対応していません"))
                case .appleIntelligenceNotEnabled: return .unavailable(String(localized: "設定で Apple Intelligence をオンにしてください"))
                case .modelNotReady: return .unavailable(String(localized: "AI モデルを準備中です。しばらくしてからもう一度どうぞ"))
                @unknown default: return .unavailable(String(localized: "この端末では今は使えません"))
                }
            }
        }
        #endif
        return .unavailable(String(localized: "iOS 26 / macOS 26 以上で使えます"))
    }

    static var isAvailable: Bool { status == .available }

    enum Failure: Error { case unavailable(String), emptyTranscript, model(String) }

    /// 字幕の文字を添削して、Gemini と同じ Feedback の形で返す
    static func review(transcript: String, targets: [String], recurring: [String]) async throws -> Feedback {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyTranscript }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard case .available = status else {
                if case .unavailable(let why) = status { throw Failure.unavailable(why) }
                throw Failure.unavailable("")
            }
            let session = LanguageModelSession(instructions: Self.instructions)
            var prompt = "Monologue (speech-to-text, may contain recognition errors and fillers):\n\"\"\"\n\(text)\n\"\"\"\n"
            if !targets.isEmpty {
                prompt += "\nTarget phrases the learner tried to use today:\n" + targets.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if !recurring.isEmpty {
                prompt += "\nMistakes this learner has repeated before (point out only if they appear again):\n" + recurring.prefix(3).map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            do {
                let out = try await session.respond(to: prompt, generating: AppleReview.self).content
                return convert(out, transcript: text, targets: targets)
            } catch {
                throw Failure.model(error.localizedDescription)
            }
        }
        #endif
        throw Failure.unavailable(String(localized: "iOS 26 / macOS 26 以上で使えます"))
    }

    /// 指示は英語（モデルが一番安定する）。返事の日本語部分だけ日本語で、と頼む
    private static let instructions = """
    You are a friendly English coach for a Japanese intermediate learner who records a spoken monologue every day.
    The text is a speech-to-text transcript: ignore fillers (uh, um), self-corrections and repeated words. Do not treat recognition glitches as the learner's mistakes.
    Find the mistakes that matter: grammar, unnatural phrasing, wrong words. Pick at most 5, most important first. For each give the original wording, a natural correction, and a one-sentence reason in simple Japanese (why the original does not work, and what the corrected form means).
    Write a corrected version of the whole monologue in natural spoken English, keeping the learner's meaning and order, removing fillers.
    Write one short compliment in Japanese about something the learner did well (a good phrase, a clear point).
    If target phrases are given, judge each: did the learner use it exactly (exact), in a changed form (changed), or not at all (missed). Quote the words actually said.
    Japanese fields must be in natural Japanese. English fields must be in English.
    """

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func convert(_ r: AppleReview, transcript: String, targets: [String]) -> Feedback {
        let issues = r.issues.prefix(5).map { i in
            Issue(type: ["grammar", "vocabulary", "phrasing"].contains(i.kind) ? i.kind : "phrasing",
                  original: i.original, suggestion: i.corrected, reason: i.reasonJa)
        }
        var ts: [Target] = []
        for t in r.targets {
            // モデルが言い換えた表現名を、こちらの表現に寄せる
            let phrase = targets.first { $0.lowercased() == t.phrase.lowercased() } ?? t.phrase
            let used = t.result != "missed"
            ts.append(Target(phrase: phrase, used: used, exact: t.result == "exact", asSaid: used ? t.asSaid : "", note: ""))
        }
        return Feedback(correctedText: r.correctedText, issues: Array(issues), recurring: [], recognitionDoubt: [],
                        good: r.complimentJa, transcript: transcript, pronunciation: [], targets: ts)
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct AppleReview {
    @Guide(description: "One short compliment in Japanese")
    var complimentJa: String
    @Guide(description: "Mistakes worth fixing, most important first, at most 5", .maximumCount(5))
    var issues: [AppleIssue]
    @Guide(description: "The whole monologue rewritten in natural spoken English, fillers removed")
    var correctedText: String
    @Guide(description: "One entry per target phrase given; empty if none were given")
    var targets: [AppleTarget]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct AppleIssue {
    @Guide(description: "grammar, vocabulary, or phrasing", .anyOf(["grammar", "vocabulary", "phrasing"]))
    var kind: String
    @Guide(description: "The learner's original words, quoted from the transcript")
    var original: String
    @Guide(description: "Natural corrected English")
    var corrected: String
    @Guide(description: "One sentence in Japanese explaining why")
    var reasonJa: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct AppleTarget {
    @Guide(description: "The target phrase as given")
    var phrase: String
    @Guide(description: "exact, changed, or missed", .anyOf(["exact", "changed", "missed"]))
    var result: String
    @Guide(description: "The words the learner actually said for it, or empty")
    var asSaid: String
}
#endif

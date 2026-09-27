import Foundation

/// Gemini API をユーザー自身のキーで直接呼ぶ。開発者のサーバーは経由しない。
/// 拡張機能の ai-providers.js（createGeminiProvider）と同じ送り方・同じエラー分類
public struct GeminiClient: Sendable {

    /// モデルは拡張機能・まもるくんと揃える
    public static let model = "gemini-3.6-flash"
    /// inlineData で送れる全体上限（20MB）に対する安全側の目安
    public static let audioMaxBytes = 18 * 1024 * 1024

    public let key: String
    public var session: URLSession = .shared

    public init(key: String) { self.key = key }

    public enum Failure: Error, Equatable {
        case noKey
        case keyInvalid
        case projectDenied     // 403 + denied access（無料枠が割り当てられていないプロジェクト）
        case rateLimited
        case server(String)
        case network(String)
        case parse             // JSON として読めない応答
        case audio             // 音声が空・大きすぎる
        case silent            // 音声に聞き取れる発話が無かった
    }

    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent")!
    }

    func call(_ body: [String: Any]) async throws -> String {
        guard !key.isEmpty else { throw Failure.noKey }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // キーは URL ではなくヘッダーで渡す（ログや Referer に残さないため）
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw Failure.network(error.localizedDescription) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), json?["error"] == nil else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw classify(status: status, message: msg)
        }
        guard let cands = json?["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private func classify(status: Int, message: String) -> Failure {
        let lower = message.lowercased()
        switch status {
        case 403 where lower.contains("denied access") || lower.contains("permission_denied"): return .projectDenied
        case 400, 401:
            if lower.contains("api key") || lower.contains("api_key") || lower.contains("invalid") { return .keyInvalid }
            return .server(message.isEmpty ? "HTTP \(status)" : message)
        case 403: return .keyInvalid
        case 429: return .rateLimited
        default: return .server(message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    /// テキストだけで添削する
    public func reviewEnglish(_ text: String, recurring: [Recurring], extra: String = "") async throws -> Feedback {
        let raw = try await call([
            "systemInstruction": ["parts": [["text": Prompts.system]]],
            "contents": [["role": "user", "parts": [["text": Logic.buildEnglishUserMessage(text, recurring: recurring, extra: extra)]]]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"]],
            "tools": [],
        ])
        guard let fb = Logic.parseFeedback(raw) else { throw Failure.parse }
        return fb
    }

    /// 音声そのものを渡して、書き起こしと添削を一度にやらせる。
    /// asrTranscript は端末の音声認識結果（比較材料）。空でもよい
    public func reviewEnglishAudio(_ audio: Data, mimeType: String, asrTranscript: String,
                                   recurring: [Recurring], extra: String = "") async throws -> Feedback {
        guard !audio.isEmpty, audio.count <= Self.audioMaxBytes else { throw Failure.audio }
        let raw = try await call([
            "systemInstruction": ["parts": [["text": Prompts.audio]]],
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": mimeType, "data": audio.base64EncodedString()]],
                ["text": Logic.buildEnglishAudioUserMessage(asrTranscript, recurring: recurring, extra: extra)],
            ]]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"], "responseMimeType": "application/json"],
            "tools": [],
        ])
        guard let fb = Logic.parseFeedback(raw) else { throw Failure.parse }
        // 音声に聞き取れる発話が無かった（無音・雑音）。AI が作った結果を出さない
        if fb.transcript.isEmpty { throw Failure.silent }
        return fb
    }

    /// 設定画面の接続テスト。**本番と同じ指定**（thinkingLevel low ＋ tools）で投げる
    public func testConnection() async throws {
        _ = try await call([
            "contents": [["role": "user", "parts": [["text": "ping"]]]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"]],
            "tools": [],
        ])
    }
}

import Foundation

/// Gemini API をユーザー自身のキーで直接呼ぶ。開発者のサーバーは経由しない。
/// 拡張機能の ai-providers.js（createGeminiProvider）と同じ送り方・同じエラー分類
public struct GeminiClient: Sendable {

    /// モデルは拡張機能・まもるくんと揃える
    public static let model = "gemini-3.6-flash"
    /// inlineData で送れる全体上限（20MB）に対する安全側の目安
    public static let audioMaxBytes = 18 * 1024 * 1024

    /// 送り先。direct＝自分のキーで Gemini へ直接／relay＝開発者の中継サーバー（キー不要・回数制限あり）
    public enum Transport: Sendable, Equatable {
        case direct(key: String)
        case relay(url: URL, deviceId: String, appKey: String)
    }
    public let transport: Transport
    public var session: URLSession = .shared

    public init(key: String) { self.transport = .direct(key: key) }
    public init(transport: Transport) { self.transport = transport }

    public var key: String { if case .direct(let k) = transport { return k }; return "" }

    /// 直近の中継サーバーの返事に付いていた回数（used, limit）。直接のときは nil
    public struct Quota: Equatable, Sendable { public var used: Int; public var limit: Int; public var remaining: Int { max(0, limit - used) } }

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
        case quota(used: Int, limit: Int)   // 中継サーバーの無料回数を使い切った
        case relayBusy         // 中継サーバーの全体の上限
    }

    private var endpoint: URL {
        switch transport {
        case .direct: return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent")!
        case .relay(let url, _, _): return url.appendingPathComponent("v1/review")
        }
    }

    func call(_ body: [String: Any]) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch transport {
        case .direct(let key):
            guard !key.isEmpty else { throw Failure.noKey }
            // キーは URL ではなくヘッダーで渡す（ログや Referer に残さないため）
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .relay(_, let deviceId, let appKey):
            req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
            req.setValue(appKey, forHTTPHeaderField: "x-app-key")
        }
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw Failure.network(error.localizedDescription) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), json?["error"] == nil else {
            let err = json?["error"] as? [String: Any]
            let msg = (err?["message"] as? String) ?? ""
            // 中継サーバーの返事は code で見分ける
            if case .relay = transport {
                switch err?["code"] as? String {
                case "quota": throw Failure.quota(used: err?["used"] as? Int ?? 0, limit: err?["limit"] as? Int ?? 0)
                case "busy": throw Failure.relayBusy
                case "forbidden", "device": throw Failure.server(msg)
                default: break
                }
            }
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
    public func reviewEnglish(_ text: String, recurring: [Recurring], extra: String = "", system: String = Prompts.system) async throws -> Feedback {
        let raw = try await call([
            "systemInstruction": ["parts": [["text": system]]],
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
                                   recurring: [Recurring], extra: String = "", system: String = Prompts.audio) async throws -> Feedback {
        guard !audio.isEmpty, audio.count <= Self.audioMaxBytes else { throw Failure.audio }
        let raw = try await call([
            "systemInstruction": ["parts": [["text": system]]],
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

    /// 中継サーバーの今日の残り回数を聞く（direct のときは nil）
    public func quota() async -> Quota? {
        guard case .relay(let url, let deviceId, let appKey) = transport else { return nil }
        var req = URLRequest(url: url.appendingPathComponent("v1/quota"))
        req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        req.setValue(appKey, forHTTPHeaderField: "x-app-key")
        req.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: req),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let used = j["used"] as? Int, let limit = j["limit"] as? Int else { return nil }
        return Quota(used: used, limit: limit)
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

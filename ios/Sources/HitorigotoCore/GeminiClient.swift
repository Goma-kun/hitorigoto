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
        case consentRejected   // 声の複製: 同意の文が画面のとおりに読めていない（Google 側の確認で弾かれた）
        case voiceRejected(String)   // 声の複製: それ以外の理由で作れなかった（音が短い・声が合わない等）
    }

    /// 「三人で話す」の声（Sam とトラさんの読み上げ）。軽い方で十分自然で、速い（2026-10-28 実測 11 秒の音声に約 4 秒）
    public static let voiceModel = "gemini-3.8-flash-lite-tts"

    /// Gemini 側の入口。generate＝いつもの generateContent／interactions＝複製の声で話す（声の複製は generateContent では使えない・2026-10-29 実測）／voices＝声の複製を作る
    enum Upstream { case generate(model: String), interactions, voices }

    /// relayPath: 中継サーバーの入口。添削は v1/review、詳しく聞くは v1/explain、スクショは v1/scan、三人で話すは v1/talk、その声は v1/voice（回数を別に数える）、
    /// 複製の声で話すは v1/speak（voice と同じ財布）、声の複製を作るは v1/voice-clone
    private func endpoint(_ relayPath: String, upstream: Upstream) -> URL {
        switch transport {
        case .direct:
            switch upstream {
            case .generate(let model): return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            case .interactions: return URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
            case .voices: return URL(string: "https://generativelanguage.googleapis.com/v1beta/voices")!
            }
        case .relay(let url, _, _): return url.appendingPathComponent(relayPath)
        }
    }

    func call(_ body: [String: Any], relayPath: String = "v1/review") async throws -> String {
        let parts = try await send(body, relayPath: relayPath, model: Self.model)
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    /// 送って、返事の parts を返す（文字でも音声でも）
    private func send(_ body: [String: Any], relayPath: String, model: String) async throws -> [[String: Any]] {
        let json = try await post(body, relayPath: relayPath, upstream: .generate(model: model))
        guard let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return [] }
        return parts
    }

    /// 送って、返事の JSON をそのまま返す。失敗は Failure に分ける（中継サーバーの返事は code で見分ける）
    private func post(_ body: [String: Any], relayPath: String, upstream: Upstream) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint(relayPath, upstream: upstream))
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
            var msg = (err?["message"] as? String) ?? ""
            // 声の複製の失敗は 500 の中に本当の理由が包まれて返る（details[].detail・2026-10-29 実測）
            for d in (err?["details"] as? [[String: Any]]) ?? [] { if let t = d["detail"] as? String { msg += " " + t } }
            // 中継サーバーの返事は code で見分ける
            if case .relay = transport {
                switch err?["code"] as? String {
                case "quota": throw Failure.quota(used: err?["used"] as? Int ?? 0, limit: err?["limit"] as? Int ?? 0)
                case "busy": throw Failure.relayBusy
                case "forbidden", "device": throw Failure.server(msg)
                case "not_found": throw Failure.server(msg)
                default: break
                }
            }
            if case .voices = upstream {
                let lower = msg.lowercased()
                if lower.contains("consent") || lower.contains("didn't match") || lower.contains("read the prompt") { throw Failure.consentRejected }
                if status == 400 || status == 500 { throw Failure.voiceRejected(msg) }
            }
            throw classify(status: status, message: msg)
        }
        return json ?? [:]
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

    /// 直し 1 件について詳しく聞く（文字だけ）。history はこれまでのやり取り
    public func explain(topic: ExplainTopic, context: String, history: [ExplainTurn], question: String, request: String? = nil,
                        system: String) async throws -> ExplainTurn {
        let raw = try await call([
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": Explain.userMessage(topic: topic, context: context, history: history,
                                                                                 question: request ?? question)]]]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"], "responseMimeType": "application/json"],
            "tools": [],
        ], relayPath: "v1/explain")
        guard let turn = Explain.parse(raw, question: question) else { throw Failure.parse }
        return turn
    }

    /// 「三人で話す」の 1 ターン。audio が nil のターン（はじまり・ヒント・締め）は文字だけ。中継サーバーでは /v1/talk で別に数える
    public func talk(audio: Data?, mimeType: String, message: String, system: String) async throws -> TalkTurn {
        var parts: [[String: Any]] = []
        if let audio {
            guard !audio.isEmpty, audio.count <= Self.audioMaxBytes else { throw Failure.audio }
            parts.append(["inlineData": ["mimeType": mimeType, "data": audio.base64EncodedString()]])
        }
        parts.append(["text": message])
        let raw = try await call([
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"], "responseMimeType": "application/json"],
            "tools": [],
        ], relayPath: "v1/talk")
        guard let turn = Talk.parse(raw) else { throw Failure.parse }
        return turn
    }

    /// 復習の音声の台本（文字だけ）。中継サーバーでは /v1/talk の 1 ターンとして数える
    public func recapScript(message: String, system: String) async throws -> [TalkLine] {
        let raw = try await call([
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": message]]]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"], "responseMimeType": "application/json"],
            "tools": [],
        ], relayPath: "v1/talk")
        let lines = Recap.parse(raw)
        guard !lines.isEmpty else { throw Failure.parse }
        return lines
    }

    /// 「三人で話す」の声。話者ごとの文を 1 回で読み上げてもらい、WAV（24kHz・16bit・モノラル）を返す。
    /// 話者が 2 人なら multiSpeaker、1 人なら単独の声。中継サーバーでは /v1/voice で別に数える
    public func speech(_ parts: [VoicePart], voices: [String: String]) async throws -> Data {
        let parts = parts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { throw Failure.audio }
        let speakers = parts.reduce(into: [String]()) { if !$0.contains($1.speaker) { $0.append($1.speaker) } }
        // 自分や友人の声（複製）が混ざるときは、片ごとに 1 回ずつ作ってつなぐ（複製の声は multiSpeaker に入れられない）
        if speakers.contains(where: { Voice.isReplicated(voices[$0] ?? "") }) {
            var wavs: [Data] = []
            for p in parts {
                let v = voices[p.speaker] ?? "Puck"
                wavs.append(Voice.isReplicated(v) ? try await speakReplicated(p, voice: v) : try await speech([p], voices: voices))
            }
            return wavs.count == 1 ? wavs[0] : Voice.join(wavs, gap: 0.35)
        }
        let speech: [String: Any]
        if speakers.count >= 2 {
            speech = ["multiSpeakerVoiceConfig": ["speakerVoiceConfigs": speakers.prefix(2).map { sp in
                ["speaker": sp, "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voices[sp] ?? "Puck"]]] as [String: Any]
            }]]
        } else {
            speech = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voices[speakers[0]] ?? "Puck"]]]
        }
        let multi = speakers.count >= 2
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts.map { p -> [String: Any] in
                var meta: [String: Any] = [:]
                if multi { meta["speaker"] = p.speaker }
                if !p.style.isEmpty { meta["style"] = p.style }
                return meta.isEmpty ? ["text": p.text] : ["text": p.text, "speechMetadata": meta]
            }]],
            "generationConfig": ["responseModalities": ["AUDIO"], "speechConfig": speech],
        ]
        let out = try await send(body, relayPath: "v1/voice", model: Self.voiceModel)
        guard let inline = out.compactMap({ $0["inlineData"] as? [String: Any] }).first,
              let b64 = inline["data"] as? String, let data = Data(base64Encoded: b64), !data.isEmpty else { throw Failure.parse }
        let mime = (inline["mimeType"] as? String ?? "").lowercased()
        // 古い TTS は頭なしの PCM（audio/l16）を返す。再生できるよう WAV の頭を付ける
        return mime.contains("wav") ? data : Voice.wav(pcm: data, sampleRate: 24000)
    }

    /// 複製の声（voicekey_…）で 1 片を読む。generateContent では複製の声を指せないので interactions の入口を使う
    /// （2026-10-29 実測: input[].annotations[{type: speech_metadata, style}] で言い方が渡せる・返りは steps[0].content[0].data の WAV）。
    /// 中継サーバーでは /v1/speak（声と同じ財布で数える）
    func speakReplicated(_ part: VoicePart, voice: String) async throws -> Data {
        var item: [String: Any] = ["type": "text", "text": part.text]
        if !part.style.isEmpty { item["annotations"] = [["type": "speech_metadata", "style": part.style]] }
        let body: [String: Any] = [
            "model": Self.voiceModel,
            "input": [item],
            "response_format": ["type": "audio"],
            "generation_config": ["speech_config": [["voice": voice]]],
        ]
        let json = try await post(body, relayPath: "v1/speak", upstream: .interactions)
        guard let steps = json["steps"] as? [[String: Any]],
              let content = steps.first?["content"] as? [[String: Any]],
              let b64 = content.first?["data"] as? String, let data = Data(base64Encoded: b64), !data.isEmpty else { throw Failure.parse }
        let mime = (content.first?["mime_type"] as? String ?? "").lowercased()
        return mime.contains("l16") || mime.contains("pcm") ? Voice.wav(pcm: data, sampleRate: 24000) : data
    }

    /// 自分や友人の声を複製して、端末だけが持つ鍵（voicekey_…）を返す。
    /// source＝10〜30 秒の話し声、consent＝同意の文（Voice.consentStatement）を読んだ声。どちらも 24kHz・16bit・モノラルの WAV。
    /// store=false なので Google 側に声は残らない（鍵は 7 日で切れる・呼ぶ側が作り直す）。中継サーバーでは /v1/voice-clone で別に数える
    public static let voiceClipMaxBytes = 3 * 1024 * 1024

    public func createVoice(source: Data, consent: Data) async throws -> String {
        guard !source.isEmpty, !consent.isEmpty, source.count <= Self.voiceClipMaxBytes, consent.count <= Self.voiceClipMaxBytes else { throw Failure.audio }
        let body: [String: Any] = [
            "store": false,
            "voice": ["type": "replicated", "replicated": [
                "source_audio": ["mime_type": "audio/wav", "data": source.base64EncodedString()],
                "consent_audio": ["mime_type": "audio/wav", "data": consent.base64EncodedString()],
            ]],
        ]
        let json = try await post(body, relayPath: "v1/voice-clone", upstream: .voices)
        // 返りの入れ物の名前は SDK と REST で揺れる（replicated_voice / replicatedVoice・key / id）ので、鍵らしい文字を探す
        if let k = Self.findVoiceKey(in: json) { return k }
        throw Failure.parse
    }

    static func findVoiceKey(in any: Any) -> String? {
        if let s = any as? String { return Voice.isReplicated(s) ? s : nil }
        if let d = any as? [String: Any] {
            for key in ["key", "id"] { if let s = d[key] as? String, Voice.isReplicated(s) { return s } }
            for v in d.values { if let k = findVoiceKey(in: v) { return k } }
        }
        if let a = any as? [Any] { for v in a { if let k = findVoiceKey(in: v) { return k } } }
        return nil
    }

    /// 「三人で話す」の今日の残り回数（中継サーバーが古くて答えないときは nil）
    public func talkQuota() async -> Quota? {
        await subQuota("talk")
    }

    /// 「声を足す」（声の複製）の今日の残り回数
    public func cloneQuota() async -> Quota? {
        await subQuota("clone")
    }

    private func subQuota(_ name: String) async -> Quota? {
        guard case .relay(let url, let deviceId, let appKey) = transport else { return nil }
        var req = URLRequest(url: url.appendingPathComponent("v1/quota"))
        req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        req.setValue(appKey, forHTTPHeaderField: "x-app-key")
        req.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: req),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let e = j[name] as? [String: Any],
              let used = e["used"] as? Int, let limit = e["limit"] as? Int else { return nil }
        return Quota(used: used, limit: limit)
    }

    /// スクショ 1 枚から表現集の候補を取り出す（JPEG を渡す）。中継サーバーでは /v1/scan で別に数える
    public static let imageMaxBytes = 4 * 1024 * 1024

    public func scanImage(_ jpeg: Data, system: String) async throws -> [ScanCandidate] {
        guard !jpeg.isEmpty, jpeg.count <= Self.imageMaxBytes else { throw Failure.audio }
        let raw = try await call([
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["text": Scan.userMessage],
            ]]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"], "responseMimeType": "application/json"],
            "tools": [],
        ], relayPath: "v1/scan")
        if Logic.extractJsonObject(raw) == nil { throw Failure.parse }
        return Scan.parse(raw)
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

    /// 「詳しく聞く」の今日の残り回数（中継サーバーが古くて答えないときは nil）
    public func explainQuota() async -> Quota? {
        guard case .relay(let url, let deviceId, let appKey) = transport else { return nil }
        var req = URLRequest(url: url.appendingPathComponent("v1/quota"))
        req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        req.setValue(appKey, forHTTPHeaderField: "x-app-key")
        req.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: req),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let e = j["explain"] as? [String: Any],
              let used = e["used"] as? Int, let limit = e["limit"] as? Int else { return nil }
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

import Foundation
import Security

/// 開発者の中継サーバー（Cloudflare Worker・`server/`）。ユーザーは API キーを持たなくてよい。
/// 音声はここを経由して Gemini に送られる。回数は端末ごとに 1 日 FREE_PER_DAY 回（サーバー側の設定）
enum Relay {
    static let url = URL(string: "https://hitorigoto-relay.jsphdn.workers.dev")!
    /// アプリであることの合言葉。本格的な不正対策（App Attest）は後で足す
    static let appKey = "RcyXaLCKzZ2tkKfSkTAE8yw5jEZH-erC"

    /// 端末ごとの識別子。初回に作って Keychain に置く（アプリを入れ直しても同じ端末なら残る）
    static var deviceId: String {
        if let v = KeychainStore.read(account: "device-id"), !v.isEmpty { return v }
        let v = UUID().uuidString
        KeychainStore.write(v, account: "device-id")
        return v
    }

    static var transport: GeminiClient.Transport { .relay(url: url, deviceId: deviceId, appKey: appKey) }
}

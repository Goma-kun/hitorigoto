import Foundation
import Security

/// Gemini API キーの保管庫。UserDefaults ではなく Keychain に置く（まもるくん iOS 版と同じ型）
enum KeychainStore {
    private static let service = "jp.nishira.hitorigoto"
    private static let account = "gemini-api-key"

    static var apiKey: String? {
        get { read() }
        set {
            let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if v.isEmpty { delete() } else { write(v) }
        }
    }

    static var hasKey: Bool { read() != nil }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    private static func write(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        if SecItemCopyMatching(base.merging([kSecReturnData as String: true]) { a, _ in a } as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var attrs = base
            attrs[kSecValueData as String] = data
            // 端末ロック解除後のみ読める。バックアップで他端末へ持ち出さない
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

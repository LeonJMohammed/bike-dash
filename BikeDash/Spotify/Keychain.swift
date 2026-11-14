import Foundation
import Security

/// Small strings in the iOS Keychain (this app only, this device only). Readable once the
/// phone has been unlocked after a restart, so a locked phone mid-ride can still reconnect.
enum Keychain {
    private static let service = "com.jlmoh.bikedash.spotify"

    static func string(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil deletes it.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        guard let value else { return true }
        var item = base(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

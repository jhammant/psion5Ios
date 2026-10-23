import Foundation
import Security

/// The user's Anthropic API key, kept in the iOS Keychain on this device only
/// (it isn't synced to iCloud or included in backups to other devices).
enum APIKeyStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.hammant.psion5.anthropic",
        kSecAttrAccount as String: "api-key",
    ]

    static func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}

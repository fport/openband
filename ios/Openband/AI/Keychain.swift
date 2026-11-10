import Foundation
import Security

/// The API key, kept in the keychain and nowhere else.
///
/// Not `UserDefaults`, not `@AppStorage`: those write plain text into the app container, which
/// ends up in unencrypted backups and in any file dump of the device. `WhenUnlockedThisDeviceOnly`
/// keeps the key off iCloud and off any restored backup — if the phone is replaced, the user
/// pastes the key again, which is the right trade for someone else's billable secret.
enum Keychain {
    static func set(_ value: String?, for account: String) {
        guard let value, !value.isEmpty else { remove(account); return }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // An add on an existing item returns errSecDuplicateItem, so update first and only add
        // when there is nothing to update.
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func remove(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    private static let service = "dev.fport.openband.ai"
}

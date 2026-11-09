import Foundation
import Security

/// The app's identity (HANDOFF §3): a UUID generated on first launch and kept in the keychain.
/// Keychain items survive deleting and reinstalling the app (unlike identifierForVendor),
/// and move to a new phone with an encrypted backup. It is not synced to iCloud.
enum DeviceIdentity {
    private static let service = "com.aspinalljason.familypizza"
    private static let account = "device-uuid"

    static func uuid() -> String {
        if let existing = read() {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()  // server stores canonical lowercase
        store(fresh)
        return fresh
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) != nil else {
            return nil
        }
        return value.lowercased()
    }

    private static func store(_ value: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // Readable after the first unlock since boot, so a push-triggered launch can use it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            print("Keychain: storing device uuid failed (\(status))")
        }
    }
}

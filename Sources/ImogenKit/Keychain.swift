import Foundation
import Security

/// A single secret in the keychain.
///
/// Refresh tokens are the whole account: one is worth a password. A file in the app's
/// container is private until the device is jailbroken, restored from an unencrypted
/// backup, or handed to someone with the passcode — and "private under those conditions"
/// is a weaker claim than it sounds.
///
/// `afterFirstUnlock` rather than `whenUnlocked`: the backup task runs while the phone is
/// in a pocket, and a secret it cannot read then is a backup that never happens. Not
/// synchronised to iCloud, because a grant belongs to the device it was issued to.
public struct Keychain: Sendable {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    public func write(_ data: Data) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Update first: adding over an existing item fails rather than replacing it, and
        // the update path is the one that runs on every token refresh.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }

        var insert = query
        insert.merge(attributes) { _, new in new }
        SecItemAdd(insert as CFDictionary, nil)
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

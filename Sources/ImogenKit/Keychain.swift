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
/// A refusal from the keychain, carrying the status that explains it.
///
/// Worth raising rather than swallowing: the alternative is a later read coming back empty
/// and the app blaming whatever asked for it. That is how a store that could not be written
/// surfaced as "there is no sign-in waiting for this callback" — an error about the wrong
/// thing, pointing away from the cause.
public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) { self.status = status }

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String?
        return "The keychain refused to store this (\(status))"
            + (detail.map { ": \($0)" } ?? "")
    }
}

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

    public func write(_ data: Data) throws {
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
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

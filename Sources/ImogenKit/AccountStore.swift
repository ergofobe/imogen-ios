import Foundation
import Observation

/// Somewhere to keep the account book. A protocol so tests do not touch the keychain.
public protocol AccountStorage: Sendable {
    func load() -> AccountBook
    func save(_ book: AccountBook) throws
}

public struct KeychainAccountStorage: AccountStorage {
    private let keychain: Keychain

    public init(service: String = "com.imogen.ios", account: String = "accounts") {
        self.keychain = Keychain(service: service, account: account)
    }

    public func load() -> AccountBook {
        guard let data = keychain.read() else { return AccountBook() }
        return (try? JSONDecoder().decode(AccountBook.self, from: data)) ?? AccountBook()
    }

    public func save(_ book: AccountBook) throws {
        // Not `try?`: an encode that fails and returns looks to the caller exactly like a
        // save that worked, which is the silence the warning above it exists to break.
        try keychain.write(JSONEncoder().encode(book))
    }
}

/// In-memory, for tests and previews.
public final class MemoryAccountStorage: AccountStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var book: AccountBook

    public init(_ book: AccountBook = AccountBook()) {
        self.book = book
    }

    public func load() -> AccountBook {
        lock.withLock { book }
    }

    public func save(_ book: AccountBook) {
        lock.withLock { self.book = book }
    }
}

/// The accounts, as the application sees them.
///
/// Observable, and the single source of truth: switching account has to change what every
/// screen is looking at at once, and a screen still showing the last server's photographs
/// after a switch is the bug this arrangement exists to prevent.
@MainActor
@Observable
public final class AccountStore {
    public private(set) var book: AccountBook

    /// Set when the accounts could not be written. Not thrown from the mutators, whose
    /// thirteen call sites are all SwiftUI actions — but recorded rather than discarded,
    /// because an account that appears to save and does not is the same silence that made
    /// #17 undiagnosable. Settings reads it and says so.
    public private(set) var lastSaveFailure: AccountSaveFailure?

    private let storage: AccountStorage

    public init(storage: AccountStorage = KeychainAccountStorage()) {
        self.storage = storage
        self.book = storage.load()
    }

    public var accounts: [Account] { book.accounts }
    public var active: Account? { book.active }

    @discardableResult
    public func add(_ account: Account) -> Account {
        mutate(.addAccount) { $0.upsert(account) }
        return book.accounts.last ?? account
    }

    public func setActive(_ id: String) {
        mutate(.switchAccount) { $0.activeAccountId = id }
    }

    public func remove(_ id: String) {
        mutate(.removeAccount) { $0.remove(id: id) }
    }

    public func setBackupEnabled(_ id: String, _ enabled: Bool) {
        mutate(.backupPreference) { $0.update(id: id) { $0.backupEnabled = enabled } }
    }

    public func setTokens(_ id: String, _ tokens: TokenSet) {
        mutate(.refreshedTokens) { $0.update(id: id) { $0.tokens = tokens } }
    }

    /// Puts the warning away. A failure that could only be cleared by a later successful
    /// write would sit there indefinitely, since nothing writes unless somebody acts.
    public func dismissSaveFailure() {
        lastSaveFailure = nil
    }

    /// The book advances whether or not the write lands, and deliberately.
    ///
    /// Rolling back looks more honest, but the mutation that matters most is the token
    /// refresh: the new token is the only one that works, and discarding it signs the
    /// person out immediately instead of at relaunch. That trades a visible-and-explained
    /// divergence for an invisible one, which is #17 again. So: keep the change, and say
    /// out loud that it is not on disk.
    private func mutate(_ change: AccountChange, _ apply: (inout AccountBook) -> Void) {
        var updated = book
        apply(&updated)
        book = updated
        do {
            try storage.save(updated)
            lastSaveFailure = nil
        } catch {
            // A keychain that refused one write refuses the next, and the person may still
            // be reading the first. The unprompted one outranks whatever they touched
            // after it, because it is the one nothing else will bring them back to.
            guard lastSaveFailure?.isUnprompted != true else { return }
            lastSaveFailure = AccountSaveFailure(change: change, error: error)
        }
    }
}

/// What was being written. The consequence of losing it differs enough between them to be
/// worth telling apart: a lost sign-in and a lost backup toggle are not the same news.
public enum AccountChange: Sendable {
    case addAccount
    case removeAccount
    case switchAccount
    case backupPreference
    case refreshedTokens
}

/// A write the keychain refused, in terms somebody can act on.
public struct AccountSaveFailure {
    public let change: AccountChange
    public let error: any Error

    public init(change: AccountChange, error: any Error) {
        self.change = change
        self.error = error
    }

    /// What the next launch will look like. Always the next launch: until then the app
    /// holds the change in memory and behaves as though it saved, which is exactly why
    /// the divergence needs saying now rather than being discovered later.
    public var consequence: String {
        switch change {
        case .addAccount:
            "This account is not saved, and will be gone when imogen starts again."
        case .removeAccount:
            "Signing out is not saved. The account will be back when imogen starts again, "
                + "and will have to be signed out again."
        case .switchAccount:
            "The account you switched to is not saved, and imogen will start again on the "
                + "previous one."
        case .backupPreference:
            "This backup setting is not saved, and will go back to what it was when imogen "
                + "starts again."
        case .refreshedTokens:
            "A renewed sign-in is not saved, and this account will be signed out when imogen "
                + "starts again."
        }
    }

    /// Whether anything the person did asked for this write.
    ///
    /// A renewed token is written behind whatever they are doing; the other four follow
    /// something they just did and will notice. So this one outranks a later failure —
    /// nothing else is going to bring them back to it.
    public var isUnprompted: Bool { change == .refreshedTokens }

    /// What the keychain said. A locked device and a full one need different answers from
    /// the person, so the status travels rather than being flattened to "could not save".
    public var reason: String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

import Foundation
import Observation

/// Somewhere to keep the account book. A protocol so tests do not touch the keychain.
///
/// `load` throws rather than answering with an empty book, because "there is nothing
/// stored" and "what is stored could not be read" call for opposite responses: the first
/// invites a write, the second forbids one.
public protocol AccountStorage: Sendable {
    func load() throws -> AccountBook
    func save(_ book: AccountBook) throws
}

public struct KeychainAccountStorage: AccountStorage {
    private let keychain: Keychain

    public init(service: String = "com.imogen.ios", account: String = "accounts") {
        self.keychain = Keychain(service: service, account: account)
    }

    /// An empty book means the device has no accounts. Anything else is thrown.
    ///
    /// Not `try?` on the decode either: a payload written by a version that stored
    /// something else is unreadable, not absent, and the accounts in it are still there
    /// to be read by whatever can read them.
    public func load() throws -> AccountBook {
        guard let data = try keychain.read() else { return AccountBook() }
        return try JSONDecoder().decode(AccountBook.self, from: data)
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

    /// Set when the accounts could not be read, or could not be written. Not thrown from
    /// the mutators, whose thirteen call sites are all SwiftUI actions — but recorded
    /// rather than discarded, because an account that appears to save and does not is the
    /// same silence that made #17 undiagnosable. A banner over whatever is on screen reads
    /// it and says so, and stays up until a write lands — see `AccountStoreFailure`.
    public private(set) var lastFailure: AccountStoreFailure?

    /// Whether the accounts on the device are unknown because the read failed.
    ///
    /// Once true it stays true for this store's lifetime. Only a successful read could
    /// make it untrue, and re-reading mid-session would mean adopting a book the person
    /// has since changed on top of the empty one — two wrong books instead of one. The
    /// next launch reads again, which is the right moment for it.
    public private(set) var accountsUnreadable = false

    private let storage: AccountStorage

    public init(storage: AccountStorage = KeychainAccountStorage()) {
        self.storage = storage
        self.book = (try? storage.load()) ?? AccountBook()
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

    /// Whether the accounts are reaching the keychain at all.
    ///
    /// Stays true across however many failures follow — only a write that lands makes it
    /// untrue, and nothing else takes it down. The failure beside it names the most recent
    /// change, and that one is allowed to move on.
    public var cannotSaveAccounts: Bool { lastFailure != nil }

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
            lastFailure = nil
        } catch {
            lastFailure = AccountStoreFailure(kind: .write(change), error: error)
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

/// Something the keychain refused, in terms somebody can act on.
///
/// One type for both directions, because both end in the same place — nothing is being
/// kept — and the person has one banner to read. A separate surface for the read would be
/// a second warning competing with the one already on screen for the same device.
public struct AccountStoreFailure {
    public enum Kind: Equatable, Sendable {
        /// The stored accounts could not be read, so what is on the device is unknown.
        case read
        /// A change could not be written. The book already holds it; the device does not.
        case write(AccountChange)
    }

    public let kind: Kind
    public let error: any Error

    public init(kind: Kind, error: any Error) {
        self.kind = kind
        self.error = error
    }

    /// The half that is true of every failure, and stays true until a write lands.
    ///
    /// Said alongside the consequence rather than instead of it: a second failure replaces
    /// what is being warned about, and without this line it would also replace the warning
    /// — trading "this account will be signed out" for "a toggle reverted" while the first
    /// was still being read.
    public var standing: String {
        switch kind {
        case .read:
            "imogen could not read your accounts on this device, and is not writing over "
                + "them. They are not lost — but nothing you change is being kept."
        case .write:
            "imogen cannot save your accounts on this device. "
                + "Nothing you change is being kept."
        }
    }

    /// What the next launch will look like. Always the next launch: until then the app
    /// holds the change in memory and behaves as though it saved, which is exactly why
    /// the divergence needs saying now rather than being discovered later.
    public var consequence: String {
        switch kind {
        // Said in the same breath as "not lost", because the screen behind this banner
        // shows no accounts, and the obvious reading of that is the wrong one.
        case .read:
            "The accounts already on this device are not shown and are not being changed. "
                + "A device that was still locked when imogen started is the usual reason; "
                + "they should be there the next time imogen starts."
        case .write(let change):
            Self.consequence(of: change)
        }
    }

    private static func consequence(of change: AccountChange) -> String {
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

    /// What the keychain said. A locked device and a full one need different answers from
    /// the person, so the status travels rather than being flattened to "could not save".
    public var reason: String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

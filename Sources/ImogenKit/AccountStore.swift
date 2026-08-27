import Foundation
import Observation

/// Somewhere to keep the account book. A protocol so tests do not touch the keychain.
public protocol AccountStorage: Sendable {
    func load() -> AccountBook
    func save(_ book: AccountBook)
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

    public func save(_ book: AccountBook) {
        guard let data = try? JSONEncoder().encode(book) else { return }
        keychain.write(data)
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

    private let storage: AccountStorage

    public init(storage: AccountStorage = KeychainAccountStorage()) {
        self.storage = storage
        self.book = storage.load()
    }

    public var accounts: [Account] { book.accounts }
    public var active: Account? { book.active }

    @discardableResult
    public func add(_ account: Account) -> Account {
        mutate { $0.upsert(account) }
        return book.accounts.last ?? account
    }

    public func setActive(_ id: String) {
        mutate { $0.activeAccountId = id }
    }

    public func remove(_ id: String) {
        mutate { $0.remove(id: id) }
    }

    public func setBackupEnabled(_ id: String, _ enabled: Bool) {
        mutate { $0.update(id: id) { $0.backupEnabled = enabled } }
    }

    public func setTokens(_ id: String, _ tokens: TokenSet) {
        mutate { $0.update(id: id) { $0.tokens = tokens } }
    }

    private func mutate(_ change: (inout AccountBook) -> Void) {
        var updated = book
        change(&updated)
        book = updated
        storage.save(updated)
    }
}

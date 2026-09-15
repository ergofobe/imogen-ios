import Foundation
import Observation

/// Why a stored account book could not be produced.
///
/// The difference decides what happens next, which is why it is a type rather than a
/// comment: a device that would not answer can answer a minute later, and a payload this
/// build cannot understand does not become understandable by asking again. Telling a
/// person to try the first remedy on the second problem is worse than saying nothing.
public enum AccountStorageError: Error, LocalizedError {
    /// The device was locked. The one failure known to come right on its own, and so the
    /// only one worth asking again about.
    case locked(any Error)
    /// The accounts could not be read, for any other reason at all. Says so and shows the
    /// status rather than guessing whether this particular one might clear by itself.
    case unreadable(any Error)

    public var underlying: any Error {
        switch self {
        case .locked(let error), .unreadable(let error): error
        }
    }

    public var errorDescription: String? {
        (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    }
}

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
        let stored: Data?
        do {
            stored = try keychain.read()
        } catch {
            // Retry only what is known to be transient, and be honest about the rest.
            // errSecInteractionNotAllowed is the locked device and comes right by itself;
            // errSecMissingEntitlement, errSecDecode, errSecInvalidItemRef and whatever
            // else Security has to say do not, or not reliably, and assuming otherwise is
            // how somebody ends up in a retry loop that can never succeed.
            let locked = (error as? KeychainError)?.status == errSecInteractionNotAllowed
            throw locked ? AccountStorageError.locked(error) : .unreadable(error)
        }
        guard let stored else { return AccountBook() }

        do {
            return try JSONDecoder().decode(AccountBook.self, from: stored)
        } catch {
            throw AccountStorageError.unreadable(error)
        }
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
        do {
            self.book = try storage.load()
        } catch {
            // An empty book only so there is something to draw. It is explicitly not a
            // claim about the device, which is why the store seals itself in the same
            // breath — see `accountsUnreadable`.
            self.book = AccountBook()
            self.accountsUnreadable = true
            self.lastFailure = AccountStoreFailure(
                kind: AccountStore.kind(ofReadFailure: error), error: error
            )
        }
    }

    /// Which sort of read failure this was.
    ///
    /// Anything that does not say otherwise is treated as the retryable one. A store that
    /// tells somebody their accounts are beyond recovery had better be sure, and being
    /// wrong in that direction is not something the person can undo.
    private static func kind(ofReadFailure error: any Error) -> AccountStoreFailure.Kind {
        switch error {
        // Only a storage that says the device was locked is retried. Anything else — a
        // storage that has not heard of this distinction included — says what happened
        // and shows the status, rather than promising a remedy on the strength of a
        // guess. Being wrong optimistically is a retry loop that never ends and a person
        // who is never told why; being wrong honestly costs one deliberate replacement.
        case AccountStorageError.locked(_): .locked
        default: .unreadable
        }
    }

    /// Gives up on a stored book this build cannot read, so the device can hold accounts
    /// again.
    ///
    /// Destructive by consequence: the store stops refusing, and the next account signed
    /// in replaces the unreadable payload along with the refresh tokens in it. Offered
    /// only from the screen that has just explained that, and never for a device that was
    /// merely locked — that one is asked again instead. Without it, a device whose accounts
    /// cannot be read could never hold an account again.
    public func allowReplacingUnreadableAccounts() {
        guard case .some(.unreadable) = lastFailure?.kind else { return }
        accountsUnreadable = false
        lastFailure = nil
    }

    /// Reads again, for a device that was locked when imogen started and is not now.
    ///
    /// Without this the seal lasts for the life of the process, and a process the system
    /// launched in the background for a backup pass is one the person then brings to the
    /// front — to an empty account list they cannot fix without killing the app.
    ///
    /// Only the kind that can answer differently. A sealed store is frozen — `mutate`
    /// changes nothing while it is — so the book being read over is always the empty one
    /// `init` put there, and there is nothing of the person's to discard.
    public func reload() {
        guard case .some(.locked) = lastFailure?.kind else { return }

        do {
            book = try storage.load()
            accountsUnreadable = false
            lastFailure = nil
        } catch {
            // Still locked, or refused for some new reason. The seal stays where it was,
            // and a reason that is no longer the locked device stops the retrying.
            lastFailure = AccountStoreFailure(
                kind: AccountStore.kind(ofReadFailure: error), error: error
            )
        }
    }

    public var accounts: [Account] { book.accounts }
    public var active: Account? { book.active }

    /// Adds the account, or nil when the store is refusing to record anything.
    ///
    /// Not discardable, and not the account that was passed in. Handing back an account a
    /// sealed store had just thrown away is what let a completed pairing report success:
    /// the invitation was spent, the account existed nowhere, and the app said "signed in".
    public func add(_ account: Account) -> Account? {
        guard mutate(.addAccount, { $0.upsert(account) }) else { return nil }
        return book.accounts.last ?? account
    }

    @discardableResult
    public func setActive(_ id: String) -> Bool {
        mutate(.switchAccount) { $0.activeAccountId = id }
    }

    @discardableResult
    public func remove(_ id: String) -> Bool {
        mutate(.removeAccount) { $0.remove(id: id) }
    }

    @discardableResult
    public func setBackupEnabled(_ id: String, _ enabled: Bool) -> Bool {
        mutate(.backupPreference) { $0.update(id: id) { $0.backupEnabled = enabled } }
    }

    @discardableResult
    public func setTokens(_ id: String, _ tokens: TokenSet) -> Bool {
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
    /// Whether the change was made. False only for a sealed store, which changes nothing:
    /// a write the keychain refused is still a change the app is living with, and says so
    /// through the banner rather than by pretending it did not happen.
    @discardableResult
    private func mutate(_ change: AccountChange, _ apply: (inout AccountBook) -> Void) -> Bool {
        // A book built on a read that failed is not the device's book, and writing it
        // would replace every account and refresh token on the device with the one or two
        // this session happens to know about. A refresh token cannot be re-derived, so
        // this is the one failure worth refusing outright rather than reporting after.
        //
        // Nothing changes in memory either, which is the opposite of what a failed *write*
        // does and for the same reason. There is no working token here to be preserved —
        // the book is empty because nothing could be read — and a pairing link arriving
        // from outside the app would otherwise leave a phantom account on screen, hide
        // the failure, and make the reread unsafe for the rest of the session.
        //
        // The read failure already on `lastFailure` is left where it is: it is the cause,
        // it is still true, and naming this change instead would replace the one line
        // that says the accounts are still on the device.
        guard !accountsUnreadable else { return false }

        var updated = book
        apply(&updated)
        book = updated

        do {
            try storage.save(updated)
            lastFailure = nil
        } catch {
            lastFailure = AccountStoreFailure(kind: .write(change), error: error)
        }
        return true
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
        /// The device was locked, so what is on it is unknown. Asking again works.
        case locked
        /// The accounts could not be read, for any other reason. Nothing is retried, the
        /// status is shown, and replacing what is stored is offered as a deliberate act.
        case unreadable
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
        case .locked:
            "imogen could not read your accounts on this device, and is not writing over "
                + "them. They are not lost — but nothing you change is being kept."
        case .unreadable:
            "imogen could not read the accounts stored on this device, and is not writing "
                + "over them. They are not lost — but nothing you change is being kept."
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
        case .locked:
            "The accounts already on this device are not shown and are not being changed. "
                + "The device was locked when imogen started; unlocking it and coming back "
                + "to imogen should bring them up."
        // No remedy offered, because there is none from here. Saying "start it again"
        // would be telling somebody to do the one thing that cannot work.
        case .unreadable:
            "The accounts already on this device are not shown, and starting imogen again "
                + "will not bring them back. They are being left alone rather than replaced, "
                + "so a later version can still read them."
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

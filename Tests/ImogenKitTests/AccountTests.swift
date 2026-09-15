import Security
import XCTest

@testable import ImogenKit

private func tokens(obtainedAt: Double = 0, expiresIn: Int = 3600) -> TokenSet {
    TokenSet(
        accessToken: "at", refreshToken: "rt", obtainedAt: obtainedAt,
        expiresIn: expiresIn, scope: "library:read"
    )
}

private func account(_ id: String, backup: Bool = false) -> Account {
    Account(
        id: id,
        serverURL: "https://\(id).example.com",
        userId: "user-\(id)",
        email: "\(id)@example.com",
        name: id,
        clientId: "client-\(id)",
        tokens: tokens(),
        backupEnabled: backup
    )
}

final class TokenSetTests: XCTestCase {

    func testAFreshTokenIsNotExpired() {
        XCTAssertFalse(tokens(obtainedAt: 1_000_000).isExpired(at: 1_000_000))
    }

    func testATokenIsRefreshedAMinuteEarlyNotASecondLate() {
        let set = tokens(obtainedAt: 1_000_000)

        XCTAssertTrue(set.isExpired(at: 1_000_000 + 3_541))
        XCTAssertFalse(set.isExpired(at: 1_000_000 + 3_539))
    }

    func testATokenShorterThanTheSkewIsExpiredFromTheMomentItArrives() {
        XCTAssertTrue(tokens(obtainedAt: 0, expiresIn: 30).isExpired(at: 0))
    }
}

final class AccountBookTests: XCTestCase {

    func testTheActiveAccountIsTheOneChosen() {
        let book = AccountBook(accounts: [account("a"), account("b")], activeAccountId: "b")

        XCTAssertEqual(book.active?.id, "b")
    }

    func testAnAccountThatHasBeenRemovedFallsBackToWhateverIsLeft() {
        let book = AccountBook(accounts: [account("a")], activeAccountId: "gone")

        XCTAssertEqual(book.active?.id, "a")
    }

    func testNoAccountsMeansNoActiveAccount() {
        XCTAssertNil(AccountBook().active)
    }

    func testBackupGoesToEveryAccountThatAskedForIt() {
        let book = AccountBook(
            accounts: [account("a", backup: true), account("b"), account("c", backup: true)]
        )

        XCTAssertEqual(book.backingUpTo.map(\.id), ["a", "c"])
    }

    /// Signing in twice to the same account would otherwise leave two live grants, two
    /// rows saying the same thing, and backup sending everything to both of them.
    func testSigningInAgainReplacesTheAccountRatherThanMakingASecond() {
        var book = AccountBook()
        book.upsert(account("a", backup: true))

        var again = account("different-local-id")
        again.serverURL = "https://a.example.com"
        again.userId = "user-a"
        book.upsert(again)

        XCTAssertEqual(book.accounts.count, 1)
        // The local identity and the backup choice survive; a re-sign-in is not a new setup.
        XCTAssertEqual(book.accounts[0].id, "a")
        XCTAssertTrue(book.accounts[0].backupEnabled)
    }

    func testADifferentPersonOnTheSameServerIsASecondAccount() {
        var book = AccountBook()
        book.upsert(account("a"))

        var other = account("b")
        other.serverURL = "https://a.example.com"
        book.upsert(other)

        XCTAssertEqual(book.accounts.count, 2)
    }

    func testRemovingTheActiveAccountPromotesAnother() {
        var book = AccountBook(accounts: [account("a"), account("b")], activeAccountId: "a")
        book.remove(id: "a")

        XCTAssertEqual(book.accounts.count, 1)
        XCTAssertEqual(book.active?.id, "b")
    }

    func testTheServerLabelIsTheHostWhichIsWhatDistinguishesTwoAccounts() {
        XCTAssertEqual(account("a").serverLabel, "a.example.com")
    }

    func testAServerOnAnUnusualPortKeepsIt() {
        var local = account("a")
        local.serverURL = "http://192.168.1.9:3000"

        XCTAssertEqual(local.serverLabel, "192.168.1.9:3000")
    }
}

final class ServerURLTests: XCTestCase {

    func testABareHostnameBecomesHTTPS() {
        XCTAssertEqual(normalizeServerURL("photos.example.com"), "https://photos.example.com")
    }

    func testAnExplicitSchemeIsLeftAlone() {
        XCTAssertEqual(normalizeServerURL("http://box.local:3000"), "http://box.local:3000")
    }

    func testATrailingSlashIsRemovedBecauseEveryPathIsAppendedToThis() {
        XCTAssertEqual(normalizeServerURL(" photos.example.com/ "), "https://photos.example.com")
    }

    func testLoopbackIsAllowedOverPlainHTTPSinceThatIsWhereATestServerIs() {
        XCTAssertEqual(normalizeServerURL("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(normalizeServerURL("127.0.0.1:3000"), "http://127.0.0.1:3000")
    }
}

final class AccountStorageTests: XCTestCase {

    @MainActor
    func testAnAccountSurvivesBeingWrittenAndReadBack() {
        let storage = MemoryAccountStorage()
        let store = AccountStore(storage: storage)
        store.add(account("a"))

        let reopened = AccountStore(storage: storage)

        XCTAssertEqual(reopened.accounts.map(\.id), ["a"])
        XCTAssertEqual(reopened.active?.email, "a@example.com")
    }

    @MainActor
    func testTurningBackupOnForOneAccountLeavesTheOthersAlone() {
        let store = AccountStore(storage: MemoryAccountStorage())
        store.add(account("a"))
        store.add(account("b"))

        store.setBackupEnabled("a", true)

        XCTAssertEqual(store.book.backingUpTo.map(\.id), ["a"])
    }
}

/// Storage that refuses, which is what a locked or full keychain looks like from here.
/// The real refusal cannot be forced portably, so the protocol is the seam.
private struct RefusingStorage: AccountStorage {
    let book: AccountBook

    init(_ book: AccountBook = AccountBook()) { self.book = book }

    func load() throws -> AccountBook { book }

    func save(_ book: AccountBook) throws {
        throw KeychainError(status: errSecInteractionNotAllowed)
    }
}

final class AccountStoreFailureTests: XCTestCase {

    @MainActor
    func testAFailedSaveIsRecordedWithWhatWasBeingSaved() {
        let store = AccountStore(storage: RefusingStorage())

        store.add(account("a"))

        XCTAssertEqual(store.lastFailure?.kind, .write(.addAccount))
    }

    /// The book is not rolled back. A refreshed token that cannot be written is still the
    /// only one that works this session; discarding it would sign the person out now
    /// rather than at relaunch, and tell them nothing either way.
    @MainActor
    func testTheInMemoryBookKeepsTheChangeThatCouldNotBeWritten() {
        let store = AccountStore(storage: RefusingStorage())

        store.add(account("a"))

        XCTAssertEqual(store.accounts.map(\.id), ["a"])
    }

    @MainActor
    func testEachMutatorNamesItsOwnConsequence() {
        let store = AccountStore(storage: RefusingStorage(AccountBook(accounts: [account("a")])))

        store.setBackupEnabled("a", true)
        XCTAssertEqual(store.lastFailure?.kind, .write(.backupPreference))

        store.setActive("a")
        XCTAssertEqual(store.lastFailure?.kind, .write(.switchAccount))

        store.remove("a")
        XCTAssertEqual(store.lastFailure?.kind, .write(.removeAccount))

        store.add(account("a"))
        XCTAssertEqual(store.lastFailure?.kind, .write(.addAccount))

        store.setTokens("a", tokens(obtainedAt: 5))
        XCTAssertEqual(store.lastFailure?.kind, .write(.refreshedTokens))
    }

    /// Every consequence is about the next launch, which is when the divergence shows.
    @MainActor
    func testTheConsequenceSaysWhatTheNextLaunchWillLookLike() {
        let store = AccountStore(storage: RefusingStorage())
        store.add(account("a"))

        XCTAssertTrue(store.lastFailure?.consequence.contains("starts again") == true)
    }

    /// The keychain's own status is what distinguishes a locked device from a full one,
    /// so it travels with the failure rather than being flattened to "could not save".
    @MainActor
    func testTheReasonCarriesWhatTheKeychainSaid() {
        let store = AccountStore(storage: RefusingStorage())
        store.add(account("a"))

        XCTAssertEqual(
            store.lastFailure?.reason,
            KeychainError(status: errSecInteractionNotAllowed).errorDescription
        )
    }

    @MainActor
    func testASaveThatWorksClearsTheOneThatDidNot() {
        let storage = FlakyStorage()
        let store = AccountStore(storage: storage)

        storage.refusing = true
        store.add(account("a"))
        XCTAssertNotNil(store.lastFailure)

        storage.refusing = false
        store.setBackupEnabled("a", true)

        XCTAssertNil(store.lastFailure)
    }

    /// The standing warning is not retired by a newer failure — only the consequence
    /// beside it changes. Suppressing the later one instead was the same loss in the
    /// other direction: the person acts, nothing is written, and nothing says so.
    @MainActor
    func testALaterFailureMovesTheConsequenceOnAndLeavesTheWarningStanding() {
        let store = AccountStore(storage: RefusingStorage(AccountBook(accounts: [account("a")])))

        store.setTokens("a", tokens(obtainedAt: 5))
        store.setBackupEnabled("a", true)

        XCTAssertEqual(store.lastFailure?.kind, .write(.backupPreference))
        XCTAssertTrue(store.cannotSaveAccounts)
    }

    /// Nothing but a write that lands makes the warning untrue, so nothing else takes it
    /// down: not a different failure, and not the person having read it.
    @MainActor
    func testOnlyASaveThatLandsTakesTheWarningDown() {
        let storage = FlakyStorage()
        let store = AccountStore(storage: storage)

        storage.refusing = true
        store.add(account("a"))
        store.setBackupEnabled("a", true)
        XCTAssertTrue(store.cannotSaveAccounts)

        storage.refusing = false
        store.setBackupEnabled("a", false)

        XCTAssertFalse(store.cannotSaveAccounts)
        XCTAssertNil(store.lastFailure)
    }

    /// The standing half says the same thing whichever change failed — that is what makes
    /// it safe for the consequence beside it to be replaced.
    @MainActor
    func testTheStandingLineDoesNotDependOnWhichChangeFailed() {
        let store = AccountStore(storage: RefusingStorage(AccountBook(accounts: [account("a")])))

        store.setTokens("a", tokens(obtainedAt: 5))
        let afterTokens = store.lastFailure?.standing

        store.setBackupEnabled("a", true)

        XCTAssertEqual(store.lastFailure?.standing, afterTokens)
        XCTAssertEqual(afterTokens?.isEmpty, false)
        XCTAssertNotEqual(store.lastFailure?.consequence, store.lastFailure?.standing)
    }
}

/// Storage whose read fails and whose write would succeed — a device that was locked when
/// imogen started and unlocked by the time somebody changed something. This is the shape
/// that used to destroy the accounts, because each half worked exactly as designed.
private final class UnreadableStorage: AccountStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var written: AccountBook

    /// Reads refused, writes taken. Counted, because "did not overwrite" and "wrote the
    /// same thing back" are not the same guarantee.
    private(set) var saves = 0

    /// What the read fails with, or nil once the device has been unlocked.
    var readFailure: AccountStorageError? = .locked(
        KeychainError(status: errSecInteractionNotAllowed)
    )

    init(stored: AccountBook) { self.written = stored }

    var stored: AccountBook { lock.withLock { written } }

    func load() throws -> AccountBook {
        if let readFailure { throw readFailure }
        return lock.withLock { written }
    }

    func save(_ book: AccountBook) throws {
        lock.withLock {
            saves += 1
            written = book
        }
    }
}

final class AccountLoadFailureTests: XCTestCase {

    /// The whole of #34. A read that fails leaves the store knowing nothing about the
    /// device, and the next write — which succeeds — used to replace every account and
    /// its refresh token with the one thing this session happened to know about.
    ///
    /// Asserted on what is stored, not on what is returned: the book advancing in memory
    /// is deliberate (#19), and only the keychain's contents say whether anything was lost.
    @MainActor
    func testAChangeAfterAFailedReadIsNotWrittenOverTheStoredAccounts() {
        let storage = UnreadableStorage(
            stored: AccountBook(accounts: [account("a")], activeAccountId: "a")
        )
        let store = AccountStore(storage: storage)

        store.add(account("b"))

        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(storage.stored.accounts.map(\.id), ["a"])
        XCTAssertEqual(storage.stored.activeAccountId, "a")
    }

    /// Not one mutator, and not the first one: the seal is on the store, so a token
    /// refresh behind a screen somebody is looking at cannot get through it either.
    @MainActor
    func testNoMutatorWritesAfterAFailedRead() {
        let storage = UnreadableStorage(stored: AccountBook(accounts: [account("a")]))
        let store = AccountStore(storage: storage)

        store.add(account("b"))
        store.setActive("b")
        store.setBackupEnabled("b", true)
        store.setTokens("b", tokens(obtainedAt: 5))
        store.remove("b")

        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(storage.stored.accounts.map(\.id), ["a"])
    }

    @MainActor
    func testAFailedReadIsRecordedBeforeAnythingElseHappens() {
        let store = AccountStore(storage: UnreadableStorage(stored: AccountBook()))

        XCTAssertEqual(store.lastFailure?.kind, .locked)
        XCTAssertTrue(store.accountsUnreadable)
        XCTAssertTrue(store.cannotSaveAccounts)
    }

    /// The read failure is the cause and does not stop being true, so a later change does
    /// not replace it. Naming the change instead would swap the one line that says the
    /// accounts are still on the device for one that reads as though they were gone.
    @MainActor
    func testAChangeDoesNotReplaceTheReadFailureItCouldNotGetPast() {
        let store = AccountStore(storage: UnreadableStorage(stored: AccountBook()))

        store.add(account("b"))

        XCTAssertEqual(store.lastFailure?.kind, .locked)
        XCTAssertTrue(store.cannotSaveAccounts)
    }

    /// What the banner says has to contradict the empty screen behind it, or somebody
    /// reads "no accounts" and signs in again rather than unlocking and relaunching.
    @MainActor
    func testTheReadFailureSaysTheAccountsAreStillThere() throws {
        let store = AccountStore(storage: UnreadableStorage(stored: AccountBook()))
        let failure = try XCTUnwrap(store.lastFailure)

        XCTAssertTrue(failure.standing.contains("not lost"))
        XCTAssertFalse(failure.consequence.isEmpty)
        XCTAssertEqual(
            failure.reason,
            KeychainError(status: errSecInteractionNotAllowed).errorDescription
        )
    }

    /// Everything that is not the locked device is reported honestly rather than retried:
    /// no remedy is promised, the status is shown, and the deliberate replacement is what
    /// is offered instead. Both kinds still refuse to write.
    @MainActor
    func testAStoreThatCannotBeReadAtAllIsToldApartFromALockedDevice() throws {
        let storage = UnreadableStorage(stored: AccountBook(accounts: [account("a")]))
        storage.readFailure = .unreadable(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bytes"))
        )
        let store = AccountStore(storage: storage)

        storage.readFailure = nil
        store.reload()

        XCTAssertEqual(store.lastFailure?.kind, .unreadable)
        XCTAssertTrue(store.accountsUnreadable)
        XCTAssertEqual(storage.saves, 0)
        let failure = try XCTUnwrap(store.lastFailure)
        XCTAssertFalse(failure.consequence.contains("unlocking"))
    }

    /// Without a way out, a device holding a payload this build cannot decode could never
    /// hold an account again: every launch reads the same bytes and seals on them.
    @MainActor
    func testAStoreThatCannotBeReadCanBeDeliberatelyReplaced() {
        let storage = UnreadableStorage(stored: AccountBook(accounts: [account("a")]))
        storage.readFailure = .unreadable(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bytes"))
        )
        let store = AccountStore(storage: storage)

        store.allowReplacingUnreadableAccounts()
        XCTAssertNotNil(store.add(account("b")))

        XCTAssertFalse(store.accountsUnreadable)
        XCTAssertNil(store.lastFailure)
        XCTAssertEqual(storage.stored.accounts.map(\.id), ["b"])
    }

    /// Never offered for a device that was only locked: those accounts are coming back on
    /// their own when it is unlocked, and replacing them destroys the refresh tokens this
    /// whole change exists to keep.
    @MainActor
    func testALockedDeviceCannotBeReplaced() {
        let storage = UnreadableStorage(stored: AccountBook(accounts: [account("a")]))
        let store = AccountStore(storage: storage)

        store.allowReplacingUnreadableAccounts()
        XCTAssertNil(store.add(account("b")))

        XCTAssertTrue(store.accountsUnreadable)
        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(storage.stored.accounts.map(\.id), ["a"])
    }

    /// The device was locked when imogen started and is not now. This is the ordinary
    /// case, and without it the seal lasts until somebody kills the app — including for a
    /// process the system launched in the background and the person then opened.
    @MainActor
    func testComingBackToAnUnlockedDeviceReadsTheAccountsAndLiftsTheSeal() {
        let storage = UnreadableStorage(
            stored: AccountBook(accounts: [account("a")], activeAccountId: "a")
        )
        let store = AccountStore(storage: storage)
        XCTAssertTrue(store.accountsUnreadable)

        storage.readFailure = nil
        store.reload()

        XCTAssertEqual(store.accounts.map(\.id), ["a"])
        XCTAssertFalse(store.accountsUnreadable)
        XCTAssertNil(store.lastFailure)

        store.setBackupEnabled("a", true)
        XCTAssertEqual(storage.saves, 1)
    }

    /// A pairing link or an OAuth redirect arrives from outside the app and calls `add`
    /// whatever is on screen. A sealed store keeps its empty book, so the failure stays on
    /// screen instead of being hidden behind an account that is not on the device — and
    /// the reread stays safe, because there is nothing of the person's to discard.
    @MainActor
    func testAChangeArrivingFromOutsideTheAppLeavesTheSealedBookAlone() {
        let storage = UnreadableStorage(
            stored: AccountBook(accounts: [account("a")], activeAccountId: "a")
        )
        let store = AccountStore(storage: storage)

        store.add(account("b"))

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.active)

        storage.readFailure = nil
        store.reload()

        XCTAssertEqual(store.accounts.map(\.id), ["a"])
        XCTAssertFalse(store.accountsUnreadable)
    }

    /// A read that is still refused leaves everything as it was, rather than reporting
    /// something new each time the app comes to the front.
    @MainActor
    func testAReloadThatIsRefusedAgainChangesNothing() {
        let store = AccountStore(storage: UnreadableStorage(stored: AccountBook()))

        store.reload()

        XCTAssertTrue(store.accountsUnreadable)
        XCTAssertEqual(store.lastFailure?.kind, .locked)
    }

    @MainActor
    func testAReloadOnAStoreThatReadCleanlyDoesNothing() {
        let storage = MemoryAccountStorage(AccountBook(accounts: [account("a")]))
        let store = AccountStore(storage: storage)

        store.reload()

        XCTAssertNil(store.lastFailure)
        XCTAssertEqual(store.accounts.map(\.id), ["a"])
    }

    /// The opposite of what a failed *write* does, and for the same reason. A failed write
    /// keeps the change because the refreshed token in it is the only one that works; a
    /// failed read has no such token to keep, and holding a change would hide the failure
    /// behind an account that is not on the device.
    @MainActor
    func testASealedStoreHoldsNothingAtAll() {
        let store = AccountStore(storage: UnreadableStorage(stored: AccountBook()))

        XCTAssertNil(store.add(account("b")))
        XCTAssertFalse(store.setBackupEnabled("b", true))

        XCTAssertTrue(store.accounts.isEmpty)
    }

    /// What made the pairing bug invisible: `add` handed back the account a sealed store
    /// had just thrown away, so a caller could not tell a stored account from a discarded
    /// one — and reported "signed in" over a spent invitation.
    @MainActor
    func testARefusedAddSaysSoRatherThanHandingTheAccountBack() {
        let sealed = AccountStore(storage: UnreadableStorage(stored: AccountBook()))
        let working = AccountStore(storage: MemoryAccountStorage())

        XCTAssertNil(sealed.add(account("b")))
        XCTAssertEqual(working.add(account("b"))?.id, "b")
    }

    /// A write the keychain refused is not a refusal to make the change: the book keeps
    /// it, the banner says it is not on disk, and the caller is told the change happened.
    /// Only a sealed store answers no.
    @MainActor
    func testAFailedWriteStillCountsAsAChangeThatWasMade() {
        let store = AccountStore(storage: RefusingStorage())

        XCTAssertNotNil(store.add(account("a")))
        XCTAssertNotNil(store.lastFailure)
    }

    /// A device with nothing stored is the case that must still be allowed to write, and
    /// it is the one a seal is easiest to get wrong.
    @MainActor
    func testADeviceWithNoAccountsStoredIsNotAFailedRead() {
        let storage = MemoryAccountStorage()
        let store = AccountStore(storage: storage)

        XCTAssertNil(store.lastFailure)
        XCTAssertFalse(store.accountsUnreadable)

        store.add(account("a"))

        XCTAssertEqual(storage.load().accounts.map(\.id), ["a"])
    }
}

private final class FlakyStorage: AccountStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var book = AccountBook()
    var refusing = false

    func load() throws -> AccountBook { lock.withLock { book } }

    func save(_ book: AccountBook) throws {
        if refusing { throw KeychainError(status: errSecInteractionNotAllowed) }
        lock.withLock { self.book = book }
    }
}

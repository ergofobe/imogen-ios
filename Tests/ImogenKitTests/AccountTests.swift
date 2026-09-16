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
        _ = store.add(account("a"))

        let reopened = AccountStore(storage: storage)

        XCTAssertEqual(reopened.accounts.map(\.id), ["a"])
        XCTAssertEqual(reopened.active?.email, "a@example.com")
    }

    @MainActor
    func testTurningBackupOnForOneAccountLeavesTheOthersAlone() {
        let store = AccountStore(storage: MemoryAccountStorage())
        _ = store.add(account("a"))
        _ = store.add(account("b"))

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

        _ = store.add(account("a"))

        XCTAssertEqual(store.lastFailure?.kind, .write(.addAccount))
    }

    /// The book is not rolled back. A refreshed token that cannot be written is still the
    /// only one that works this session; discarding it would sign the person out now
    /// rather than at relaunch, and tell them nothing either way.
    @MainActor
    func testTheInMemoryBookKeepsTheChangeThatCouldNotBeWritten() {
        let store = AccountStore(storage: RefusingStorage())

        _ = store.add(account("a"))

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

        _ = store.add(account("a"))
        XCTAssertEqual(store.lastFailure?.kind, .write(.addAccount))

        store.setTokens("a", tokens(obtainedAt: 5))
        XCTAssertEqual(store.lastFailure?.kind, .write(.refreshedTokens))
    }

    /// Every consequence is about the next launch, which is when the divergence shows.
    @MainActor
    func testTheConsequenceSaysWhatTheNextLaunchWillLookLike() {
        let store = AccountStore(storage: RefusingStorage())
        _ = store.add(account("a"))

        XCTAssertTrue(store.lastFailure?.consequence.contains("starts again") == true)
    }

    /// The keychain's own status is what distinguishes a locked device from a full one,
    /// so it travels with the failure rather than being flattened to "could not save".
    @MainActor
    func testTheReasonCarriesWhatTheKeychainSaid() {
        let store = AccountStore(storage: RefusingStorage())
        _ = store.add(account("a"))

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
        _ = store.add(account("a"))
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
        _ = store.add(account("a"))
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
    var readFailure: AccountStorageError? = .transient(
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

    @MainActor
    private func store(_ storage: AccountStorage) -> AccountStore {
        AccountStore(storage: storage)
    }

    private func unreadable() -> AccountStorageError {
        .unreadable(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bytes")))
    }

    /// The whole of #34. A read that fails leaves the store knowing nothing about the
    /// device, and the next write — which succeeds — used to replace every account and
    /// its refresh token with the one thing this session happened to know about.
    ///
    /// Asserted on what is stored, not on what is returned: the book advancing in memory
    /// is deliberate for a failed *write* (#19), and only the keychain's contents say
    /// whether anything was lost.
    @MainActor
    func testAChangeAfterAFailedReadIsNotWrittenOverTheStoredAccounts() {
        let storage = UnreadableStorage(
            stored: AccountBook(accounts: [account("a")], activeAccountId: "a")
        )
        let store = store(storage)

        _ = store.add(account("b"))

        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(storage.stored.accounts.map(\.id), ["a"])
        XCTAssertEqual(storage.stored.activeAccountId, "a")
    }

    /// Not one mutator, and not the first one: the seal is on the store, so a token
    /// refresh behind a screen somebody is looking at cannot get through it either.
    @MainActor
    func testNoMutatorWritesAfterAFailedRead() {
        let storage = UnreadableStorage(stored: AccountBook(accounts: [account("a")]))
        let store = store(storage)

        _ = store.add(account("b"))
        store.setActive("b")
        store.setBackupEnabled("b", true)
        store.setTokens("b", tokens(obtainedAt: 5))
        store.remove("b")

        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(storage.stored.accounts.map(\.id), ["a"])
    }

    @MainActor
    func testAFailedReadIsRecordedBeforeAnythingElseHappens() {
        let store = store(UnreadableStorage(stored: AccountBook()))

        XCTAssertEqual(store.lastFailure?.kind, .transient)
        XCTAssertTrue(store.accountsUnreadable)
        XCTAssertTrue(store.cannotSaveAccounts)
    }

    /// The read failure is the cause and does not stop being true, so a later change does
    /// not replace it. Naming the change instead would swap the one line that says the
    /// accounts are still on the device for one that reads as though they were gone.
    @MainActor
    func testAChangeDoesNotReplaceTheReadFailureItCouldNotGetPast() {
        let store = store(UnreadableStorage(stored: AccountBook()))

        _ = store.add(account("b"))

        XCTAssertEqual(store.lastFailure?.kind, .transient)
        XCTAssertTrue(store.cannotSaveAccounts)
    }

    /// What the banner says has to contradict the empty screen behind it, or somebody
    /// reads "no accounts" and signs in again rather than unlocking and trying once more.
    @MainActor
    func testTheReadFailureSaysTheAccountsAreStillThere() throws {
        let store = store(UnreadableStorage(stored: AccountBook()))
        let failure = try XCTUnwrap(store.lastFailure)

        XCTAssertTrue(failure.standing.contains("not lost"))
        XCTAssertFalse(failure.consequence.isEmpty)
        XCTAssertEqual(
            failure.reason,
            KeychainError(status: errSecInteractionNotAllowed).errorDescription
        )
    }

    /// Everything that is not known to come right on its own is reported honestly rather
    /// than retried behind somebody's back: no remedy is promised, the status is shown,
    /// and nothing rereads it unasked. Both kinds still refuse to write.
    @MainActor
    func testAStoreThatCannotBeReadIsNotRetriedOnSomebodysBehalf() throws {
        let storage = UnreadableStorage(stored: AccountBook(accounts: [account("a")]))
        storage.readFailure = unreadable()
        let store = store(storage)

        storage.readFailure = nil
        store.reloadIfTransient()

        XCTAssertEqual(store.lastFailure?.kind, .unreadable)
        XCTAssertTrue(store.accountsUnreadable)
        XCTAssertEqual(storage.saves, 0)
        let failure = try XCTUnwrap(store.lastFailure)
        XCTAssertFalse(failure.consequence.contains("unlocking"))
    }

    /// -34018 reads like a provisioning mistake and is usually the keybag race at launch.
    /// Calling it permanent is what would have offered somebody the destruction of a
    /// payload that was readable all along.
    func testTheKeybagRaceIsTransientAndSoIsALockedDevice() {
        XCTAssertTrue(KeychainAccountStorage.isTransient(errSecInteractionNotAllowed))
        XCTAssertTrue(KeychainAccountStorage.isTransient(errSecMissingEntitlement))

        XCTAssertFalse(KeychainAccountStorage.isTransient(errSecDecode))
        XCTAssertFalse(KeychainAccountStorage.isTransient(errSecInvalidItemRef))
        XCTAssertFalse(KeychainAccountStorage.isTransient(errSecInvalidData))
    }

    /// Anything the app can ask for by hand it can ask for again, whichever kind — a read
    /// costs nothing, and a screen that says "try again" needs something to try.
    @MainActor
    func testTryingAgainReadsWhicheverKindOfFailureItWas() {
        let storage = UnreadableStorage(stored: AccountBook(accounts: [account("a")]))
        storage.readFailure = unreadable()
        let store = store(storage)

        XCTAssertFalse(store.retryRead())

        storage.readFailure = nil

        XCTAssertTrue(store.retryRead())
        XCTAssertEqual(store.accounts.map(\.id), ["a"])
        XCTAssertFalse(store.accountsUnreadable)
        XCTAssertNil(store.lastFailure)
    }

    /// The device was locked when imogen started and is not now. This is the ordinary
    /// case, and without it the seal lasts until somebody kills the app — including for a
    /// process the system launched in the background and the person then opened.
    @MainActor
    func testComingBackToAnUnlockedDeviceReadsTheAccountsAndLiftsTheSeal() {
        let storage = UnreadableStorage(
            stored: AccountBook(accounts: [account("a")], activeAccountId: "a")
        )
        let store = store(storage)
        XCTAssertTrue(store.accountsUnreadable)

        storage.readFailure = nil
        store.reloadIfTransient()

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
        let store = store(storage)

        _ = store.add(account("b"))

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.active)

        storage.readFailure = nil
        store.reloadIfTransient()

        XCTAssertEqual(store.accounts.map(\.id), ["a"])
        XCTAssertFalse(store.accountsUnreadable)
    }

    /// A read that is still refused leaves everything as it was, rather than reporting
    /// something new each time the app comes to the front.
    @MainActor
    func testARereadThatIsRefusedAgainChangesNothing() {
        let store = store(UnreadableStorage(stored: AccountBook()))

        store.reloadIfTransient()

        XCTAssertTrue(store.accountsUnreadable)
        XCTAssertEqual(store.lastFailure?.kind, .transient)
    }

    @MainActor
    func testARereadOnAStoreThatReadCleanlyDoesNothing() {
        let storage = MemoryAccountStorage(AccountBook(accounts: [account("a")]))
        let store = store(storage)

        store.reloadIfTransient()
        XCTAssertFalse(store.retryRead())

        XCTAssertNil(store.lastFailure)
        XCTAssertEqual(store.accounts.map(\.id), ["a"])
    }

    /// The opposite of what a failed *write* does, and for the same reason. A failed write
    /// keeps the change because the refreshed token in it is the only one that works; a
    /// failed read has no such token to keep, and holding a change would hide the failure
    /// behind an account that is not on the device.
    @MainActor
    func testASealedStoreHoldsNothingAtAll() {
        let store = store(UnreadableStorage(stored: AccountBook()))

        XCTAssertNil(store.add(account("b")))
        XCTAssertFalse(store.setBackupEnabled("b", true))

        XCTAssertTrue(store.accounts.isEmpty)
    }

    /// What made the pairing bug invisible: `add` handed back the account a sealed store
    /// had just thrown away, so a caller could not tell a stored account from a discarded
    /// one — and reported "signed in" over a spent invitation.
    @MainActor
    func testARefusedAddSaysSoRatherThanHandingTheAccountBack() {
        let sealed = store(UnreadableStorage(stored: AccountBook()))
        let working = store(MemoryAccountStorage())

        XCTAssertNil(sealed.add(account("b")))
        XCTAssertEqual(working.add(account("b"))?.id, "b")
    }

    /// A write the keychain refused is not a refusal to make the change: the book keeps
    /// it, the banner says it is not on disk, and the caller is told the change happened.
    /// Only a sealed store answers no.
    @MainActor
    func testAFailedWriteStillCountsAsAChangeThatWasMade() {
        let store = store(RefusingStorage())

        XCTAssertNotNil(store.add(account("a")))
        XCTAssertNotNil(store.lastFailure)
    }

    /// A device with nothing stored is the case that must still be allowed to write, and
    /// it is the one a seal is easiest to get wrong.
    @MainActor
    func testADeviceWithNoAccountsStoredIsNotAFailedRead() {
        let storage = MemoryAccountStorage()
        let store = store(storage)

        XCTAssertNil(store.lastFailure)
        XCTAssertFalse(store.accountsUnreadable)

        _ = store.add(account("a"))

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

/// The stored account payload, read by a build that is not the one that wrote it.
///
/// This is the app's compatibility surface with its own past and its own future, and the
/// only one this target has. Everything here works on payloads produced by the real
/// encoder, because a hand-rolled fixture only proves what the fixture's author expected.
final class StoredAccountCodingTests: XCTestCase {

    /// The whole of #43, simulated with production code only: a payload written by a build
    /// that predates a field, read by a build that has it.
    ///
    /// `backupEnabled` stands in for whatever field is added next — remove it from a real
    /// encoding and the result is byte-for-byte what the release before it wrote.
    func testAPayloadWrittenBeforeAFieldExistedStillDecodes() throws {
        let encoded = try JSONEncoder().encode(furnishedBook())
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var accounts = try XCTUnwrap(payload["accounts"] as? [[String: Any]])
        accounts[0].removeValue(forKey: "backupEnabled")
        payload["accounts"] = accounts

        let older = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(AccountBook.self, from: older)

        XCTAssertEqual(decoded.accounts.map(\.id), ["a"])
        // The safe default, not the one that was there: backup is somebody's decision to
        // make, and a field that has gone missing is not that decision.
        XCTAssertFalse(decoded.accounts[0].backupEnabled)
    }

    /// The teeth. Every key in a real payload is removed in turn, and the decode has to
    /// survive unless that key is named below with a reason.
    ///
    /// A field added tomorrow arrives here as a path nobody listed, and the choice about
    /// it gets made deliberately instead of being discovered by every device at once on
    /// upgrade. That is the part a rule could not do: a rule has to be remembered.
    func testOnlyTheKeysAnAccountCannotFunctionWithoutAreRequired() throws {
        let required: Set<String> = [
            // An absent list decodes as a device with no accounts and invites the write
            // that replaces the ones really there.
            "accounts",
            // The identity `activeAccountId` and every stored reference name.
            "accounts[].id",
            // Where this account is and who it is. Nothing can be asked without them.
            "accounts[].serverURL",
            "accounts[].userId",
            // The registration every refresh has to present again.
            "accounts[].clientId",
            // No credential at all is not an account, it is a row.
            "accounts[].tokens",
            "accounts[].tokens.accessToken",
        ]

        let payload = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(StoredAccounts(book: furnishedBook()))
        )
        let variants = payloadsMissingEachKey(payload)
        // A payload that walked to nothing would pass every assertion below by vacuity.
        XCTAssertGreaterThan(variants.count, 10)
        XCTAssertTrue(
            required.isSubset(of: Set(variants.map(\.path))),
            "required names a key that is no longer written: "
                + "\(required.subtracting(Set(variants.map(\.path))))"
        )

        for (path, without) in variants {
            let data = try JSONSerialization.data(withJSONObject: without)
            let decoded = try? JSONDecoder().decode(StoredAccounts.self, from: data)

            if required.contains(path) {
                XCTAssertNil(decoded, "\(path) is listed as required but decoding survived it")
            } else {
                XCTAssertNotNil(
                    decoded,
                    "a payload without \(path) did not decode. Either give it a default, "
                        + "or add it to `required` above with the reason it is one."
                )
            }
        }
    }

    /// The trap on the other side of a hand-written decoder: `encode(to:)` stays
    /// synthesized and writes every new field, so a decoder that forgets one ignores it
    /// silently and for ever. Round-tripping a fully furnished book is what notices.
    func testEveryStoredFieldSurvivesTheRoundTrip() throws {
        let book = furnishedBook()

        let encoded = try JSONEncoder().encode(StoredAccounts(book: book))
        let decoded = try JSONDecoder().decode(StoredAccounts.self, from: encoded)

        XCTAssertEqual(decoded.book, book)
        XCTAssertEqual(decoded.version, StoredAccounts.currentVersion)
    }

    /// And what keeps that test honest: a field the fixture left at its default would
    /// round-trip identically whether the decoder read it or dropped it. So every value
    /// the fixture writes has to differ from the value a bare book would write there.
    func testTheFixtureLeavesNoStoredFieldAtItsDefault() throws {
        let furnished = try leaves(of: StoredAccounts(book: furnishedBook()))
        let bare = try leaves(of: StoredAccounts(book: bareBook()))

        for (path, value) in furnished where path != "version" {
            // `version` is the format marker rather than a stored value: it is the same
            // in every payload this build writes, which is the whole of its job.
            guard let same = bare[path] else { continue }
            XCTAssertNotEqual(
                value, same,
                "the fixture leaves \(path) at its default, so the round-trip test cannot "
                    + "tell a decoder that reads it from one that drops it"
            )
        }
    }

    /// Every device in the field holds a payload with no marker on it. It is not corrupt
    /// and it is not from the future: it is the shape version 1 describes.
    func testAPayloadWithNoMarkerReadsAsTheShapeEveryDeviceAlreadyHolds() throws {
        let unmarked = try JSONEncoder().encode(furnishedBook())

        let decoded = try JSONDecoder().decode(StoredAccounts.self, from: unmarked)

        XCTAssertEqual(decoded.version, StoredAccounts.preMarkerVersion)
        XCTAssertEqual(decoded.book, furnishedBook())
    }

    /// The marker sits beside the book's keys rather than wrapping them precisely so that
    /// this holds: a build that predates the marker reads what this one writes. Wrapping
    /// would have manufactured the downgrade failure the marker exists to diagnose.
    func testABuildThatPredatesTheMarkerCanStillReadWhatThisOneWrites() throws {
        let marked = try JSONEncoder().encode(StoredAccounts(book: furnishedBook()))

        // The decoder such a build has is the book's own, reading the payload directly.
        XCTAssertEqual(try JSONDecoder().decode(AccountBook.self, from: marked), furnishedBook())
    }

    /// The case the marker is actually for. Nothing is corrupt, the accounts are intact,
    /// and telling somebody they are unreadable is what would have them destroy them.
    func testAPayloadFromANewerBuildSaysSoRatherThanReadingAsCorrupt() throws {
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(StoredAccounts(book: furnishedBook()))
            ) as? [String: Any]
        )
        payload["version"] = StoredAccounts.currentVersion + 1
        let fromTheFuture = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try JSONDecoder().decode(StoredAccounts.self, from: fromTheFuture)) {
            guard let newer = $0 as? AccountsFromNewerBuild else {
                return XCTFail("expected a newer-build refusal, got \($0)")
            }
            XCTAssertEqual(newer.version, StoredAccounts.currentVersion + 1)
            // The remedy has to be in it. "Unreadable" with no remedy is the diagnosis
            // that sends somebody to replace a payload that was fine all along.
            XCTAssertEqual(newer.errorDescription?.contains("updating imogen"), true)
        }
    }

    // MARK: - Walking a real payload

    /// A book with nothing left at its default, so that a key going missing shows in the
    /// value rather than hiding behind the value it would have defaulted to anyway.
    private func furnishedBook() -> AccountBook {
        var populated = account("a", backup: true)
        populated.email = "someone@example.com"
        populated.name = "Someone"
        populated.tokens = TokenSet(
            accessToken: "access", refreshToken: "refresh", obtainedAt: 1_700_000_000,
            expiresIn: 7_200, scope: "library:read library:write"
        )
        return AccountBook(accounts: [populated], activeAccountId: "a")
    }

    /// The same shape with every value left at whatever a default gives it.
    private func bareBook() -> AccountBook {
        AccountBook(
            accounts: [
                Account(
                    id: "", serverURL: "", userId: "", email: "", name: "", clientId: "",
                    tokens: TokenSet(
                        accessToken: "", refreshToken: nil, obtainedAt: 0, expiresIn: 0,
                        scope: ""
                    )
                )
            ]
        )
    }

    /// Every leaf of a real encoding, by path. Written through the encoder rather than
    /// listed by hand: a list is a thing to keep up to date, and this is what the test
    /// exists to avoid.
    private func leaves(of stored: StoredAccounts) throws -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ value: Any, at path: String) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    walk(child, at: path.isEmpty ? key : "\(path).\(key)")
                }
            } else if let array = value as? [Any] {
                for element in array { walk(element, at: "\(path)[]") }
            } else {
                found[path] = String(describing: value)
            }
        }
        walk(try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)), at: "")
        return found
    }

    /// One copy of the payload per key it contains, each with that key removed.
    ///
    /// Array indices collapse to `[]`: the fixture holds one account, and a path naming
    /// an index would read as being about that account rather than about the field.
    private func payloadsMissingEachKey(
        _ value: Any, at path: String = ""
    ) -> [(path: String, payload: Any)] {
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { key -> [(path: String, payload: Any)] in
                let here = path.isEmpty ? key : "\(path).\(key)"
                var without = object
                without.removeValue(forKey: key)

                let deeper = payloadsMissingEachKey(object[key] ?? NSNull(), at: here)
                return [(here, without)]
                    + deeper.map { found in
                        var rebuilt = object
                        rebuilt[key] = found.payload
                        return (found.path, rebuilt as Any)
                    }
            }
        }

        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, element in
                payloadsMissingEachKey(element, at: "\(path)[]").map { found in
                    var rebuilt = array
                    rebuilt[index] = found.payload
                    return (found.path, rebuilt as Any)
                }
            }
        }

        return []
    }
}

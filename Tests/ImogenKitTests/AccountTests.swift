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

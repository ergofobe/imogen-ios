import XCTest

@testable import ImogenKit

/// The ledger decides what a pass skips, so what it counts and what it forgets is the
/// difference between a backup that finishes and one that silently stops short.
final class UploadLedgerTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func ledger() -> UploadLedger { UploadLedger(directory: directory) }

    private func account(_ id: String) -> Account {
        Account(
            id: id,
            serverURL: "https://\(id).example.com",
            userId: "user-\(id)",
            email: "\(id)@example.com",
            name: id,
            clientId: "client-\(id)",
            tokens: TokenSet(
                accessToken: "at", refreshToken: "rt", obtainedAt: 0,
                expiresIn: 3600, scope: "library:read"
            ),
            backupEnabled: true
        )
    }

    func testCountsOnlyWhatActuallyArrived() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "acc")
        await ledger.put(UploadRecord(localId: "b", attempts: 1, lastError: "no"), for: "acc")

        // A failure is not a backup. This count is what the settings screen shows at rest,
        // and counting attempts here would tell somebody their photographs are safe when
        // they are not.
        let count = await ledger.uploadedCount(for: "acc")
        XCTAssertEqual(count, 1)
    }

    func testCountsAreKeptPerAccount() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "one")
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "two")
        await ledger.put(UploadRecord(localId: "b", assetId: "remote-b"), for: "two")

        let one = await ledger.uploadedCount(for: "one")
        let two = await ledger.uploadedCount(for: "two")
        XCTAssertEqual(one, 1)
        XCTAssertEqual(two, 2)
    }

    func testFailuresAreListedWithTheirReason() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "acc")
        await ledger.put(UploadRecord(localId: "b", attempts: 1, lastError: "rejected"), for: "acc")

        let failures = await ledger.failures(for: "acc")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.localId, "b")
        XCTAssertEqual(failures.first?.lastError, "rejected")
    }

    func testAFileThatSpentItsAttemptsIsSettledAndSoIsSkipped() async {
        let ledger = self.ledger()
        await ledger.put(
            UploadRecord(localId: "b", attempts: maxUploadAttempts, lastError: "rejected"),
            for: "acc"
        )

        let settled = await ledger.settled(for: "acc")
        XCTAssertTrue(settled.contains("b"))
    }

    func testRetryingPutsAGivenUpFileBackInTheRunning() async {
        let ledger = self.ledger()
        await ledger.put(
            UploadRecord(localId: "b", attempts: maxUploadAttempts, lastError: "rejected"),
            for: "acc"
        )

        await ledger.retry("b", for: "acc")

        // Settled is computed from the attempt count, so zeroing it is what actually
        // undoes the giving-up. Anything less leaves the file skipped for ever.
        let settled = await ledger.settled(for: "acc")
        XCTAssertFalse(settled.contains("b"))
        let attempts = await ledger.attempts("b", for: "acc")
        XCTAssertEqual(attempts, 0)
    }

    func testRetryingClearsTheStaleReason() async {
        let ledger = self.ledger()
        await ledger.put(
            UploadRecord(localId: "b", attempts: maxUploadAttempts, lastError: "rejected"),
            for: "acc"
        )

        await ledger.retry("b", for: "acc")

        let failures = await ledger.failures(for: "acc")
        XCTAssertEqual(failures.first?.lastError, nil)
    }

    func testRetryingEverythingLeavesNothingGivenUpOn() async {
        let ledger = self.ledger()
        for id in ["a", "b", "c"] {
            await ledger.put(
                UploadRecord(localId: id, attempts: maxUploadAttempts, lastError: "no"),
                for: "acc"
            )
        }

        await ledger.retryAll(for: "acc")

        let settled = await ledger.settled(for: "acc")
        XCTAssertTrue(settled.isEmpty)
    }

    func testRetryingDoesNotDisturbSomethingAlreadyUploaded() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "acc")

        await ledger.retryAll(for: "acc")

        // A done row has no attempts to reset, and clearing its assetId would send the
        // whole library up again.
        let count = await ledger.uploadedCount(for: "acc")
        XCTAssertEqual(count, 1)
        let settled = await ledger.settled(for: "acc")
        XCTAssertTrue(settled.contains("a"))
    }

    func testWhenAPassLastFinishedSurvivesBeingReadBack() async {
        let ledger = self.ledger()
        await ledger.recordCompleted(at: 1_700_000_000, for: "acc")

        let fresh = UploadLedger(directory: directory)
        let at = await fresh.lastCompleted(for: "acc")
        XCTAssertEqual(at, 1_700_000_000)
    }

    func testTheSamePhotographFailingOnTwoServersIsTwoFailures() async {
        // The headline case for several destinations: a family server and one of your
        // own. `localId` names the photograph, not the pair, so a list keyed on it shows
        // one of these two rows — and the destination whose row was dropped is never
        // offered the "Try again" that is its only way out of `givenUp`.
        let ledger = self.ledger()
        let family = account("family")
        let mine = account("mine")
        let givenUp = UploadRecord(
            localId: "ABC-123/L0/001", attempts: maxUploadAttempts, lastError: "rejected"
        )
        await ledger.put(givenUp, for: family.id)
        await ledger.put(givenUp, for: mine.id)

        let failures = await ledger.failures(for: [family, mine])

        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(Set(failures.map(\.id)).count, 2, "both destinations need their own row")
        XCTAssertEqual(Set(failures.map(\.account.id)), ["family", "mine"])
    }

    func testAFailureKeepsItsIdentityThroughTheRetryThatRewritesIt() async {
        // Every retry is followed by a reload. An identity made from the attempt count or
        // the error message — both of which `retry` clears — would change underneath the
        // list, and every row would jump.
        let ledger = self.ledger()
        let one = account("one")
        await ledger.put(
            UploadRecord(localId: "a", attempts: maxUploadAttempts, lastError: "rejected"),
            for: one.id
        )
        let before = await ledger.failures(for: [one]).first?.id

        await ledger.retry("a", for: one.id)

        let after = await ledger.failures(for: [one]).first?.id
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after)
    }

    func testOnlyTheNamedDestinationIsPutBackInTheRunning() async {
        // "Try again" acts on one pair. Retrying the photograph everywhere would quietly
        // re-upload it to a server that already has it.
        let ledger = self.ledger()
        let family = account("family")
        let mine = account("mine")
        let givenUp = UploadRecord(localId: "a", attempts: maxUploadAttempts, lastError: "no")
        await ledger.put(givenUp, for: family.id)
        await ledger.put(givenUp, for: mine.id)

        await ledger.retry("a", for: family.id)

        let familySettled = await ledger.settled(for: family.id)
        let mineSettled = await ledger.settled(for: mine.id)
        XCTAssertFalse(familySettled.contains("a"))
        XCTAssertTrue(mineSettled.contains("a"))
    }

    func testAnAccountThatHasNeverFinishedAPassSaysSo() async {
        let ledger = self.ledger()
        let at = await ledger.lastCompleted(for: "acc")
        XCTAssertNil(at)
    }
}

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

    func testAnAccountThatHasNeverFinishedAPassSaysSo() async {
        let ledger = self.ledger()
        let at = await ledger.lastCompleted(for: "acc")
        XCTAssertNil(at)
    }
}

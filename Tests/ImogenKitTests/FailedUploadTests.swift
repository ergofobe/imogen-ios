import XCTest

@testable import ImogenKit

final class FailedUploadTests: XCTestCase {

    private func record(attempts: Int, name: String? = "IMG_0042.HEIC") -> UploadRecord {
        UploadRecord(
            localId: "ABC-123/L0/001",
            attempts: attempts,
            lastError: "rejected",
            displayName: name
        )
    }

    func testAFileWithAttemptsLeftWillBeTriedAgain() {
        XCTAssertEqual(record(attempts: 1).failureState, .willRetry)
        XCTAssertEqual(record(attempts: maxUploadAttempts - 1).failureState, .willRetry)
    }

    func testAFileThatSpentItsAttemptsHasBeenGivenUpOn() {
        // `settled(for:)` folds these away, so nothing retries them and nothing mentions
        // them — the state that stranded a hundred photographs on the Android client.
        XCTAssertEqual(record(attempts: maxUploadAttempts).failureState, .givenUp)
    }

    func testAnAttemptCountPastTheLimitIsStillGivenUpOn() {
        XCTAssertEqual(record(attempts: maxUploadAttempts + 5).failureState, .givenUp)
    }

    func testARecordedNameIsWhatGetsShown() {
        XCTAssertEqual(record(attempts: 1).name, "IMG_0042.HEIC")
    }

    func testAFileWrittenBeforeNamesWereRecordedFallsBackToItsLocalIdentifier() {
        // A blank row would hide exactly the backlog the screen exists for.
        XCTAssertEqual(record(attempts: 1, name: nil).name, "ABC-123/L0/001")
    }

    func testTheSummarySeparatesWhatWillBeRetriedFromWhatIsAbandoned() {
        let summary = summarise([
            record(attempts: 1),
            record(attempts: 2),
            record(attempts: maxUploadAttempts),
            record(attempts: maxUploadAttempts),
        ])
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.willRetry, 2)
        XCTAssertEqual(summary.givenUp, 2)
    }

    func testNothingFailedIsASummaryOfNothing() {
        let summary = summarise([])
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.givenUp, 0)
    }

    // MARK: - What costs a file one of its three attempts

    func testACancelledTaskDoesNotSpendAnAttempt() {
        // `BGProcessingTask` expiring cancels the pass, and expiring is routine overnight
        // behaviour rather than a verdict on the file. Three ordinary expirations on one
        // large video would otherwise be enough to abandon it for good.
        XCTAssertFalse(uploadAttemptWasSpent(on: CancellationError()))
        // URLSession answers a cancelled task with this rather than a CancellationError,
        // so catching only the Swift one would miss the case that actually happens.
        XCTAssertFalse(uploadAttemptWasSpent(on: URLError(.cancelled)))
    }

    func testAConnectionThatDroppedDoesNotSpendAnAttempt() {
        // An upload is multipart, so the SDK will not replay it: the raw URLError lands in
        // the caller's generic catch looking exactly like a rejection. It is not one —
        // it is the same "the server's problem, not this file's" that the ImogenError
        // branch already refuses to charge to the file.
        for code: URLError.Code in [
            .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
            .dnsLookupFailed, .secureConnectionFailed,
        ] {
            XCTAssertFalse(uploadAttemptWasSpent(on: URLError(code)), "\(code)")
        }
    }

    func testSomethingWrongWithTheFileItselfStillSpendsAnAttempt() {
        // The counter exists so a permanently broken file is not read, hashed and posted
        // on every single pass. Anything not known to be transient keeps that behaviour.
        XCTAssertTrue(uploadAttemptWasSpent(on: URLError(.fileDoesNotExist)))
        XCTAssertTrue(uploadAttemptWasSpent(on: URLError(.dataLengthExceedsMaximum)))
        struct Unknown: Error {}
        XCTAssertTrue(uploadAttemptWasSpent(on: Unknown()))
    }

    /// The ledger is JSON on disk that predates this field. A row written by an older
    /// build must still decode, or a backup's whole history disappears on upgrade.
    func testARecordWrittenBeforeDisplayNameExistedStillDecodes() throws {
        let old = """
            {"localId":"ABC-123/L0/001","uploadedAt":1700000000,"attempts":2,"lastError":"no"}
            """
        let decoded = try JSONDecoder().decode(UploadRecord.self, from: Data(old.utf8))

        XCTAssertEqual(decoded.localId, "ABC-123/L0/001")
        XCTAssertEqual(decoded.attempts, 2)
        XCTAssertNil(decoded.displayName)
        XCTAssertEqual(decoded.name, "ABC-123/L0/001")
    }
}

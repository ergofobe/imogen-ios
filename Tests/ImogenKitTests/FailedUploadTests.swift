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

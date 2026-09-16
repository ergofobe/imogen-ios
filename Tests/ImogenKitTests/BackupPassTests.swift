import ImogenSDK
import XCTest

@testable import ImogenKit

/// The backup pass loop, which decides what is tried, what is given up on, and when a
/// destination may claim to be up to date.
///
/// It lived in `App/Sources/PhotoBackup.swift` until ergofobe/imogen-ios#40, where
/// `swift test` could not reach it — three review rounds of ergofobe/imogen-ios#37 each
/// introduced a regression into that file that only reading caught.
@MainActor
final class BackupPassTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL.temporaryDirectory.appending(path: "pass-\(UUID().uuidString)")
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

    /// The world, as the pass sees it: an export that always works, an upload answered
    /// from a table, and a record of everything that was disposed of.
    @MainActor
    private final class World {
        var answers: [String: Result<String, Error>] = [:]
        var exportFails: Set<String> = []
        var exported: [String] = []
        var disposed: [URL] = []
        var uploads: [(localId: String, accountId: String)] = []
        var progress: [BackupProgress?] = []
        var cancelAfterUploads: Int?

        func effects() -> BackupPassEffects {
            BackupPassEffects(
                export: { [unowned self] localId in
                    self.exported.append(localId)
                    if self.exportFails.contains(localId) { return nil }
                    return URL.temporaryDirectory.appending(path: "\(localId).jpg")
                },
                dispose: { [unowned self] url in self.disposed.append(url) },
                upload: { [unowned self] _, localId, account in
                    self.uploads.append((localId, account.id))
                    return self.answers["\(account.id)/\(localId)"]
                        ?? self.answers[localId]
                        ?? .success("remote-\(localId)")
                },
                report: { [unowned self] value in self.progress.append(value) },
                isCancelled: { [unowned self] in
                    guard let limit = self.cancelAfterUploads else { return false }
                    return self.uploads.count >= limit
                }
            )
        }
    }

    private func transient() -> ImogenError {
        ImogenError(status: 503, code: "unavailable", message: "Try later")
    }

    private func permanent() -> ImogenError {
        ImogenError(status: 415, code: "unsupported", message: "Not that sort of file")
    }

    // MARK: - What a pass does when everything works

    func testSendsEveryFileToEveryDestination() async {
        let ledger = self.ledger()
        let world = World()

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(outcome.uploaded, 4)
        XCTAssertEqual(outcome.completedDestinations.sorted(), ["one", "two"])
        XCTAssertNil(outcome.message)
        // Exported once per file, not once per destination. That is the whole reason one
        // pass serves every account.
        XCTAssertEqual(world.exported, ["a", "b"])
        XCTAssertEqual(world.disposed.count, 2)
    }

    func testSkipsWhatTheLedgerHasAlreadySettled() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "one")
        let world = World()

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(outcome.uploaded, 1)
        XCTAssertEqual(world.uploads.map(\.localId), ["b"])
    }

    func testStampsCompletionWhenThereWasNothingToDo() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "one")
        let world = World()

        let outcome = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(outcome.completedDestinations, ["one"])
        let stamped = await ledger.lastCompleted(for: "one")
        XCTAssertNotNil(stamped)
        // Nothing to send is not a reason to read the photo library's bytes.
        XCTAssertTrue(world.exported.isEmpty)
    }

    // MARK: - What a failure costs

    func testAPermanentRejectionSpendsAnAttemptAndThePassCarriesOn() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["a"] = .failure(permanent())

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(world.uploads.map(\.localId), ["a", "b"])
        XCTAssertEqual(outcome.uploaded, 1)
    }

    func testATransientFailureSpendsNothingAndStopsPushing() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["a"] = .failure(transient())

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        // "Anything transient is the server's problem, not this file's."
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(world.uploads.map(\.localId), ["a"])
        XCTAssertNotNil(outcome.message)
    }

    func testThreeRejectionsAreFoldedAwayByLaterPasses() async {
        let ledger = self.ledger()
        for pass in 1...maxUploadAttempts {
            let world = World()
            world.answers["a"] = .failure(permanent())
            _ = await runBackupPass(
                ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
            )
            let attempts = await ledger.attempts("a", for: "one")
            XCTAssertEqual(attempts, pass)
        }

        let after = World()
        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: after.effects()
        )
        XCTAssertTrue(after.uploads.isEmpty)
    }

    // MARK: - Exports

    func testTheExportIsDisposedOfOnEveryWayOutOfTheItem() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["a"] = .failure(transient())

        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        // The abort path is where ergofobe/imogen-ios#37 leaked a multi-gigabyte video.
        XCTAssertEqual(world.disposed.count, 1)
    }

    func testAnAssetThatCannotBeExportedIsNotUploaded() async {
        let ledger = self.ledger()
        let world = World()
        world.exportFails = ["a"]

        _ = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(world.uploads.map(\.localId), ["b"])
        // Only "b" was ever written to disk, so only "b" is disposed of.
        XCTAssertEqual(world.disposed.count, 1)

        // And nothing is recorded against it, so every later pass exports it again.
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
    }

    // MARK: - Stopping

    func testAStoppedPassClaimsNoCompletion() async {
        let ledger = self.ledger()
        let world = World()
        world.cancelAfterUploads = 1

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(world.uploads.map(\.localId), ["a"])
        XCTAssertTrue(outcome.completedDestinations.isEmpty)
        let stamped = await ledger.lastCompleted(for: "one")
        XCTAssertNil(stamped)
    }

    func testProgressIsClearedWhenThePassEnds() async {
        let ledger = self.ledger()
        let world = World()

        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertNil(world.progress.last ?? BackupProgress(completed: 0, total: 0))
    }
}

/// How an upload failure is classified, which is the decision ergofobe/imogen-ios#39 is
/// about. Kept apart from the loop because it is the one piece the loop asks a question of
/// rather than performs.
final class UploadDispositionTests: XCTestCase {

    func testAServerRejectionIsTheFilesOwnProblem() {
        let error = ImogenError(status: 415, code: "unsupported", message: "No")
        XCTAssertEqual(uploadDisposition(of: error), .rejected)
        XCTAssertTrue(uploadDisposition(of: error).spendsAttempt)
    }

    func testARetryableStatusIsTheServersProblem() {
        for status in [429, 500, 503] {
            let error = ImogenError(status: status, code: "busy", message: "Later")
            XCTAssertEqual(uploadDisposition(of: error), .unavailable)
            XCTAssertFalse(uploadDisposition(of: error).spendsAttempt)
        }
    }

    func testARequestThatNeverReachedAServerIsTheServersProblem() {
        let error = ImogenError(status: 0, code: "http_error", message: "Request failed")
        XCTAssertEqual(uploadDisposition(of: error), .unavailable)
    }
}

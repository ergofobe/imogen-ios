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
        var exportFails: [String: Error] = [:]
        var exported: [String] = []
        var disposed: [URL] = []
        var uploads: [(localId: String, accountId: String)] = []
        var progress: [BackupProgress?] = []
        var lastCompletedReported: Int { progress.compactMap { $0 }.last?.completed ?? -1 }
        var cancelAfterUploads: Int?

        func effects() -> BackupPassEffects {
            BackupPassEffects(
                export: { [unowned self] localId in
                    self.exported.append(localId)
                    if let error = self.exportFails[localId] { return .failure(error) }
                    return .success(URL.temporaryDirectory.appending(path: "\(localId).jpg"))
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
        world.exportFails = ["a": Unreadable()]

        _ = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(world.uploads.map(\.localId), ["b"])
        // Only "b" was ever written to disk, so only "b" is disposed of.
        XCTAssertEqual(world.disposed.count, 1)

        // Said out loud on the failures screen, so it is not silently exported afresh by
        // every pass for ever — but it costs the file nothing, because a local problem
        // passes and an abandoned photograph does not come back.
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
        let listed = await ledger.failures(for: "one").map(\.localId)
        XCTAssertEqual(listed, ["a"])
        let interruptions = await ledger.interruptions(for: "one")
        XCTAssertEqual(interruptions["a"], 1)
    }

    // MARK: - Being cut short

    func testACancellationSpendsNoAttempt() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["a"] = .failure(CancellationError())

        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        // A `BGProcessingTask` expiring is routine overnight behaviour, not this file's
        // fault. ergofobe/imogen-ios#39.
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
    }

    func testAURLSessionCancellationSpendsNoAttempt() async {
        let ledger = self.ledger()
        let world = World()
        // URLSession answers a cancelled task with this, not a `CancellationError`, and
        // the SDK rethrows it raw because a multipart body is not replayed.
        world.answers["a"] = .failure(URLError(.cancelled))

        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
    }

    func testACancelledPassDoesNotBlameTheServer() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["a"] = .failure(CancellationError())

        let outcome = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        // "Couldn't reach the server" is not what happened.
        XCTAssertNil(outcome.message)
        XCTAssertTrue(outcome.completedDestinations.isEmpty)
    }

    func testCancellationsNeverAbandonTheFile() async {
        let ledger = self.ledger()
        for _ in 1...(maxUploadAttempts + 1) {
            let world = World()
            world.answers["a"] = .failure(CancellationError())
            _ = await runBackupPass(
                ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
            )
        }

        // Three expiries used to reach `givenUp`, where `settled(for:)` folds the file
        // away and no later pass ever mentions it again.
        let settled = await ledger.settled(for: "one")
        XCTAssertFalse(settled.contains("a"))

        let after = World()
        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: after.effects()
        )
        XCTAssertEqual(after.uploads.map(\.localId), ["a"])
    }

    func testAFileCutShortRepeatedlyStopsHoldingUpTheQueue() async {
        let ledger = self.ledger()
        let one = account("one")

        // "b" is the big video: every window runs out before it finishes.
        for pass in 1...deferAfterInterruptions {
            let world = World()
            world.answers["b"] = .failure(CancellationError())
            _ = await runBackupPass(
                ["a", "b", "c"], to: [one], ledger: ledger, effects: world.effects()
            )
            // The pass stops where it was cut short, so "c" never gets a look in.
            XCTAssertFalse(world.uploads.map(\.localId).contains("c"), "pass \(pass)")
        }

        let world = World()
        world.answers["b"] = .failure(CancellationError())
        _ = await runBackupPass(
            ["a", "b", "c"], to: [one], ledger: ledger, effects: world.effects()
        )

        // "a" is settled by now, so this pass is "c" first and the video last — which is
        // the bound that replaces giving up on it.
        XCTAssertEqual(world.uploads.map(\.localId), ["c", "b"])
    }

    func testInterruptionsAreDroppedOnceNothingWillTryTheFileAgain() async {
        let ledger = self.ledger()
        await ledger.recordInterruption("a", for: "one")
        await ledger.put(
            UploadRecord(localId: "a", attempts: maxUploadAttempts, lastError: "no"),
            for: "one"
        )

        let world = World()
        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        // Read in full at the start of every pass, so a library that has given up on a few
        // hundred assets must not carry them for the life of the install.
        let left = await ledger.interruptions(for: "one")
        XCTAssertTrue(left.isEmpty)
    }

    func testARetryPutsACutShortFileBackInItsPlace() async {
        let ledger = self.ledger()
        await ledger.recordInterruption("a", for: "one")

        // A file that has only ever been cut short has an interruption and no record at
        // all, so a retry guarded on the record would never reach it.
        await ledger.retry("a", for: "one")

        let left = await ledger.interruptions(for: "one")
        XCTAssertTrue(left.isEmpty)
    }

    func testGettingThroughPutsTheFileBackInItsPlace() async {
        let ledger = self.ledger()
        await ledger.recordInterruption("b", for: "one")
        await ledger.recordInterruption("b", for: "one")

        let world = World()
        _ = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        let left = await ledger.interruptions(for: "one")
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: - One destination's bad day is not another's

    func testAnUnreachableDestinationDoesNotStopAHealthyOne() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["two/a"] = .failure(transient())
        world.answers["two/b"] = .failure(transient())

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        // Both files reach the healthy server; the dead one is dropped after one refusal
        // rather than being pushed at again.
        XCTAssertEqual(
            world.uploads.filter { $0.accountId == "one" }.map(\.localId), ["a", "b"]
        )
        XCTAssertEqual(
            world.uploads.filter { $0.accountId == "two" }.map(\.localId), ["a"]
        )
        XCTAssertEqual(outcome.uploaded, 2)
    }

    func testOnlyDestinationsThatGotEverythingAreStamped() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["two/a"] = .failure(transient())

        let outcome = await runBackupPass(
            ["a"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        // A dead second server freezing a healthy server's timestamp is the regression
        // ergofobe/imogen-ios#37 shipped a global flag for.
        XCTAssertEqual(outcome.completedDestinations, ["one"])
        let healthy = await ledger.lastCompleted(for: "one")
        let dead = await ledger.lastCompleted(for: "two")
        XCTAssertNotNil(healthy)
        XCTAssertNil(dead)
    }

    func testARejectionStillLetsTheDestinationBeUpToDate() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["a"] = .failure(permanent())

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        // The pass did everything it could, and the failure is counted on the same screen
        // as this timestamp. Withholding it instead freezes "last completed" for ever over
        // one bad photograph, which is ergofobe/imogen-ios#37's third regression.
        XCTAssertEqual(outcome.completedDestinations, ["one"])
        let listed = await ledger.failures(for: "one").map(\.localId)
        XCTAssertEqual(listed, ["a"])
    }

    func testProgressReachesTheEndWhenADestinationIsDropped() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["two/a"] = .failure(transient())

        _ = await runBackupPass(
            ["a", "b"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        // Four pairs were owed. Two went to the healthy server, one was refused and one
        // was never tried — and a progress bar frozen at half way for the rest of a pass
        // reads as a hang.
        let reported = world.progress.compactMap { $0 }
        XCTAssertEqual(reported.last?.total, 4)
        XCTAssertEqual(world.lastCompletedReported, 4)
    }

    // MARK: - An export is as interruptible as an upload

    func testAnExportCutShortCostsTheFileNothing() async {
        let ledger = self.ledger()
        let world = World()
        // `isNetworkAccessAllowed` means an export of an iCloud asset is a download, so an
        // expiring window lands here at least as often as in the upload — and this is the
        // long part of a big video, which is the case #39 is about.
        world.exportFails = ["a": CancellationError()]

        let outcome = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
        XCTAssertNil(outcome.message)
        let interruptions = await ledger.interruptions(for: "one")
        XCTAssertEqual(interruptions["a"], 1)
    }

    func testAnExportCutShortNeverAbandonsTheFile() async {
        let ledger = self.ledger()
        for _ in 1...(maxUploadAttempts + 1) {
            let world = World()
            world.exportFails = ["a": URLError(.cancelled)]
            _ = await runBackupPass(
                ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
            )
        }

        let settled = await ledger.settled(for: "one")
        XCTAssertFalse(settled.contains("a"))
    }

    func testAnExportFailureNeverTakesADestinationDown() async {
        let ledger = self.ledger()
        let world = World()
        // Exporting an iCloud original is a download, so it fails for network reasons —
        // which is the photo library's business and not this server's. Blaming the server
        // would stop the pass and leave the other 3,997 files untouched.
        world.exportFails = ["a": URLError(.notConnectedToInternet)]

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(world.uploads.map(\.localId), ["b"])
        XCTAssertEqual(outcome.completedDestinations, ["one"])
        XCTAssertNil(outcome.message)
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
        // And it is moved out of the way rather than blocking the same queue position on
        // every pass for ever.
        let interruptions = await ledger.interruptions(for: "one")
        XCTAssertEqual(interruptions["a"], 1)
    }

    func testAnExportFailureKeepsTheNameTheFileAlreadyHad() async {
        let ledger = self.ledger()
        await ledger.put(
            UploadRecord(
                localId: "a", attempts: 1, lastError: "no", displayName: "IMG_0421.HEIC"
            ),
            for: "one"
        )
        let world = World()
        world.exportFails = ["a": Unreadable()]

        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        // Nothing got as far as an export, so there is no filename to record — and the
        // opaque local identifier is not an improvement on the one already there.
        let listed = await ledger.failures(for: "one")
        XCTAssertEqual(listed.first?.displayName, "IMG_0421.HEIC")
        XCTAssertEqual(listed.first?.attempts, 1)
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


/// The queue order, which is what keeps one unfinishable file from holding up a library.
final class PassOrderTests: XCTestCase {

    func testNothingMovesWithoutInterruptions() {
        XCTAssertEqual(passOrder(["a", "b", "c"], deferring: [:]), ["a", "b", "c"])
    }

    func testAFileUnderTheLimitKeepsItsPlace() {
        let order = passOrder(
            ["a", "b", "c"], deferring: ["b": deferAfterInterruptions - 1]
        )
        XCTAssertEqual(order, ["a", "b", "c"])
    }

    func testARepeatedlyInterruptedFileGoesToTheBack() {
        let order = passOrder(["a", "b", "c"], deferring: ["a": deferAfterInterruptions])
        XCTAssertEqual(order, ["b", "c", "a"])
    }

    func testDeferredFilesKeepTheirOrderAmongstThemselves() {
        let order = passOrder(
            ["a", "b", "c", "d"],
            deferring: ["a": deferAfterInterruptions, "c": deferAfterInterruptions + 4]
        )
        // Oldest first still, within each group. The library was read in that order for a
        // reason, and shuffling it would make the count unreadable.
        XCTAssertEqual(order, ["b", "d", "a", "c"])
    }
}

/// The two shapes a cancellation arrives in. Verified against the SDK's own rethrow path:
/// `HTTPClient.send` sets `replayable = !options.isMultipart`, and a small upload is sent
/// `isMultipart: true`.
final class CancellationShapeTests: XCTestCase {

    func testACancellationErrorCostsNothing() {
        XCTAssertEqual(uploadDisposition(of: CancellationError()), .cancelled)
        XCTAssertFalse(uploadDisposition(of: CancellationError()).spendsAttempt)
    }

    func testURLSessionsCancellationCostsNothing() {
        let error = URLError(.cancelled)
        XCTAssertEqual(uploadDisposition(of: error), .cancelled)
        XCTAssertFalse(uploadDisposition(of: error).spendsAttempt)
    }

    func testAnotherURLErrorIsTheNetworksProblem() {
        for code in [URLError.notConnectedToInternet, .timedOut, .networkConnectionLost] {
            XCTAssertEqual(uploadDisposition(of: URLError(code)), .unavailable)
        }
    }

    func testALocalProblemCostsTheFileNothing() {
        // The SDK throws plain Cocoa errors from `fileSize(of:)`, `Data(contentsOf:)` and
        // `FileHandle`. A full disk is not a reason to give a photograph up for ever.
        XCTAssertEqual(uploadDisposition(of: Unreadable()), .deferred)
        XCTAssertFalse(uploadDisposition(of: Unreadable()).spendsAttempt)

        let outOfSpace = CocoaError(.fileWriteOutOfSpace)
        XCTAssertEqual(uploadDisposition(of: outOfSpace), .deferred)
    }

    func testOnlyAnAnswerFromTheServerSpendsAnAttempt() {
        let refusal = ImogenError(status: 415, code: "unsupported", message: "No")
        XCTAssertTrue(uploadDisposition(of: refusal).spendsAttempt)
        for other: Error in [CancellationError(), URLError(.cancelled), URLError(.timedOut), Unreadable()] {
            XCTAssertFalse(uploadDisposition(of: other).spendsAttempt)
        }
    }
}


/// Stands in for the Cocoa and PhotoKit errors the SDK and the photo library actually
/// throw, none of which is a `URLError` or an `ImogenError`.
struct Unreadable: Error {}

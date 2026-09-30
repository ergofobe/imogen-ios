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
        /// The clock running out during the export of this file, which is where a window
        /// expires on a big video.
        var cancelDuringExportOf: String?
        private var clockRanOut = false

        func effects() -> BackupPassEffects {
            BackupPassEffects(
                export: { [unowned self] localId in
                    self.exported.append(localId)
                    if localId == self.cancelDuringExportOf { self.clockRanOut = true }
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
                    if self.clockRanOut { return true }
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

        // A PhotoKit or Cocoa failure that is not a URLError is bounded. One pass
        // spends an attempt; it does not sit in the queue forever.
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 1)
        let listed = await ledger.failures(for: "one").map(\.localId)
        XCTAssertEqual(listed, ["a"])
        let interruptions = await ledger.interruptions(for: "one")
        XCTAssertTrue(interruptions.isEmpty)
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

    func testAnExportCutShortByTheClockIsNotTheFilesBadLuck() async {
        let ledger = self.ledger()
        let world = World()
        world.cancelDuringExportOf = "a"
        // PhotoKit answers a `writeData` it cannot finish with an `NSError` of its own,
        // never a `CancellationError` — so the error alone cannot tell the clock running
        // out from the file being bad, and the expiring window #39 is about is exactly the
        // case that arrives this way.
        world.exportFails = ["a": Unreadable()]

        let outcome = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
        XCTAssertNil(outcome.message)
        XCTAssertTrue(outcome.completedDestinations.isEmpty)
        // Recorded as a queue position, not as a failure: nothing went wrong.
        let listed = await ledger.failures(for: "one")
        XCTAssertTrue(listed.isEmpty)
        let interruptions = await ledger.interruptions(for: "one")
        XCTAssertEqual(interruptions["a"], 1)
    }

    func testAnAssetWithNothingToSendIsEventuallyFoldedAway() async {
        let ledger = self.ledger()
        for _ in 1...maxUploadAttempts {
            let world = World()
            world.exportFails = ["a": ExportFailure.noUsableResource]
            _ = await runBackupPass(
                ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
            )
        }

        // The photo library's "there is nothing here" does not change with the weather, so
        // it is the one local failure that counts against the file — otherwise it is
        // re-exported on every pass for the life of the install.
        let settled = await ledger.settled(for: "one")
        XCTAssertTrue(settled.contains("a"))
        let listed = await ledger.failures(for: "one")
        XCTAssertEqual(listed.first?.failureState, .givenUp)
    }

    func testAStaleTokenDoesNotGiveUpTheCameraRoll() async {
        let ledger = self.ledger()
        let unauthorised = ImogenError(status: 401, code: "unauthorized", message: "No")

        for _ in 1...(maxUploadAttempts + 1) {
            let world = World()
            world.answers["a"] = .failure(unauthorised)
            world.answers["b"] = .failure(unauthorised)
            _ = await runBackupPass(
                ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
            )
        }

        // Uploads are sent unreplayable, so the SDK's refresh-and-retry cannot fire and
        // the 401 arrives here. Spending an attempt on it gives up every photograph on the
        // device in three passes, without the user touching anything.
        let settled = await ledger.settled(for: "one")
        XCTAssertTrue(settled.isEmpty)
    }

    func testAnAuthErrorEndsTheDestinationWithoutSpendingAnAttempt() async {
        for status in [401, 403] {
            // One directory for both statuses made the 403 case read the 401 row.
            let ledger = UploadLedger(directory: directory.appending(path: "auth-\(status)"))
            let world = World()
            let auth = ImogenError(
                status: status, code: "unauthorized", message: "Session expired"
            )
            world.answers["a"] = .failure(auth)

            let outcome = await runBackupPass(
                ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
            )

            XCTAssertEqual(world.uploads.map(\.localId), ["a"], "status \(status)")
            XCTAssertEqual(world.exported, ["a"], "status \(status)")
            XCTAssertEqual(outcome.uploaded, 0, "status \(status)")
            XCTAssertTrue(outcome.completedDestinations.isEmpty, "status \(status)")
            XCTAssertEqual(
                outcome.message,
                "Sign in again. Backup will carry on once you do.",
                "status \(status)"
            )
            let attempts = await ledger.attempts("a", for: "one")
            XCTAssertEqual(attempts, 0, "status \(status)")
            let listed = await ledger.failures(for: "one")
            XCTAssertEqual(listed.map(\.localId), ["a"], "status \(status)")
            XCTAssertEqual(listed.first?.lastError, "Session expired", "status \(status)")
            let stamped = await ledger.lastCompleted(for: "one")
            XCTAssertNil(stamped, "status \(status)")
            let interruptions = await ledger.interruptions(for: "one")
            XCTAssertNil(interruptions["a"], "status \(status)")
        }
    }

    func testAnAuthErrorOnOneDestinationLeavesTheOtherWorking() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["two/a"] = .failure(
            ImogenError(status: 401, code: "unauthorized", message: "Session expired")
        )

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(
            world.uploads.filter { $0.accountId == "one" }.map(\.localId), ["a", "b"]
        )
        XCTAssertEqual(
            world.uploads.filter { $0.accountId == "two" }.map(\.localId), ["a"]
        )
        XCTAssertEqual(outcome.completedDestinations, ["one"])
        XCTAssertEqual(
            outcome.message, "Sign in again. Backup will carry on once you do."
        )
        let dead = await ledger.lastCompleted(for: "two")
        XCTAssertNil(dead)
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
        // A network failure while exporting is unavailable, not deferred, so it does not
        // earn an interruption — the same rule the upload-failure arm already follows.
        let interruptions = await ledger.interruptions(for: "one")
        XCTAssertTrue(interruptions.isEmpty)
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
        XCTAssertEqual(listed.first?.attempts, 2)
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

    func testLastCompletedStaysPutWhenNothingWasAccepted() async {
        let ledger = self.ledger()
        let deferred = World()
        deferred.answers["a"] = .failure(Unreadable())
        deferred.answers["b"] = .failure(Unreadable())
        let deferredOutcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: deferred.effects()
        )
        XCTAssertEqual(deferredOutcome.uploaded, 0)
        XCTAssertTrue(deferredOutcome.completedDestinations.isEmpty)
        let stamped = await ledger.lastCompleted(for: "one")
        XCTAssertNil(stamped)

        let rejected = World()
        rejected.answers["c"] = .failure(permanent())
        let rejectedOutcome = await runBackupPass(
            ["c"], to: [account("one")], ledger: ledger, effects: rejected.effects()
        )
        XCTAssertTrue(rejectedOutcome.completedDestinations.isEmpty)
        let still = await ledger.lastCompleted(for: "one")
        XCTAssertNil(still)
    }

    func testLastCompletedStaysPutWhenTheDestinationEndsAfterASuccess() async {
        let down = transient()
        let auth = ImogenError(status: 401, code: "unauthorized", message: "No")
        for (name, error) in [("down", down), ("auth", auth)] {
            let ledger = UploadLedger(directory: directory.appending(path: name))
            let world = World()
            world.answers["b"] = .failure(error)

            let outcome = await runBackupPass(
                ["a", "b", "c"], to: [account("one")], ledger: ledger, effects: world.effects()
            )

            // Something arrived, then the destination went unreachable or needed
            // a sign-in. Last completed does not move.
            XCTAssertEqual(outcome.uploaded, 1, name)
            XCTAssertEqual(world.uploads.map(\.localId), ["a", "b"], name)
            XCTAssertTrue(outcome.completedDestinations.isEmpty, name)
            let stamped = await ledger.lastCompleted(for: "one")
            XCTAssertNil(stamped, name)
        }
    }

    func testAnUpToDateDestinationIsStampedWhenAnotherDidWork() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "one")
        let world = World()

        let outcome = await runBackupPass(
            ["a"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(outcome.uploaded, 1)
        XCTAssertEqual(world.uploads.map { "\($0.accountId)/\($0.localId)" }, ["two/a"])
        XCTAssertEqual(outcome.completedDestinations.sorted(), ["one", "two"])
        let oneDone = await ledger.lastCompleted(for: "one")
        let twoDone = await ledger.lastCompleted(for: "two")
        XCTAssertNotNil(oneDone)
        XCTAssertNotNil(twoDone)
    }

    func testARefreshed401DoesNotAskForSignInOrDropTheDestination() async {
        let ledger = UploadLedger(directory: directory.appending(path: "refreshed"))
        let world = World()
        world.answers["a"] = .failure(
            ImogenError(status: 401, code: refreshedNotReplayed, message: "Session expired")
        )

        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(world.uploads.map(\.localId), ["a", "b"])
        XCTAssertEqual(outcome.uploaded, 1)
        XCTAssertNil(outcome.message)
        XCTAssertEqual(outcome.completedDestinations, ["one"])
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
        let listed = await ledger.failures(for: "one")
        XCTAssertTrue(listed.isEmpty)
    }

    func testCancellationKeepsAMessageThisPassAlreadyOwed() async {
        let signIn = "Sign in again. Backup will carry on once you do."
        let unreachable = "Couldn't reach the server. Backup will carry on later."
        let cases: [(String, Error, String)] = [
            ("auth", ImogenError(status: 401, code: "unauthorized", message: "No"), signIn),
            ("down", transient(), unreachable),
        ]
        for (name, error, expected) in cases {
            let ledger = UploadLedger(directory: directory.appending(path: "cancel-msg-\(name)"))
            let world = World()
            world.answers["one/a"] = .failure(error)
            world.cancelAfterUploads = 2
            let outcome = await runBackupPass(
                ["a", "b"], to: [account("one"), account("two")],
                ledger: ledger, effects: world.effects()
            )
            XCTAssertEqual(
                world.uploads.map { "\($0.accountId)/\($0.localId)" },
                ["one/a", "two/a"],
                name
            )
            XCTAssertEqual(outcome.message, expected, name)
            XCTAssertTrue(outcome.completedDestinations.isEmpty, name)
        }
    }

    func testASignInMessageSurvivesALaterUnreachableDestination() async {
        let ledger = self.ledger()
        let world = World()
        world.answers["one/a"] = .failure(
            ImogenError(status: 401, code: "unauthorized", message: "No")
        )
        world.answers["two/a"] = .failure(transient())

        let outcome = await runBackupPass(
            ["a"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(
            outcome.message, "Sign in again. Backup will carry on once you do."
        )
        XCTAssertTrue(outcome.completedDestinations.isEmpty)
    }

    func testAPermanentLocalFailureIsBounded() async {
        let ledger = self.ledger()
        for _ in 1...maxUploadAttempts {
            let world = World()
            world.answers["a"] = .failure(CocoaError(.fileReadUnknown))
            _ = await runBackupPass(
                ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
            )
        }

        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, maxUploadAttempts)
        let settled = await ledger.settled(for: "one")
        XCTAssertTrue(settled.contains("a"))
        let listed = await ledger.failures(for: "one")
        XCTAssertEqual(listed.first?.failureState, .givenUp)

        let again = World()
        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: again.effects()
        )
        XCTAssertTrue(again.uploads.isEmpty)
        XCTAssertTrue(again.exported.isEmpty)
    }

    func testACancelledUploadIsNotFiledAsAuthOrUnreachable() async {
        let cases: [Error] = [
            ImogenError(status: 401, code: "unauthorized", message: "No"),
            URLError(.networkConnectionLost),
        ]
        for (index, error) in cases.enumerated() {
            let ledger = UploadLedger(directory: directory.appending(path: "cancel-\(index)"))
            let world = World()
            world.answers["a"] = .failure(error)
            world.cancelAfterUploads = 1

            let outcome = await runBackupPass(
                ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
            )

            XCTAssertEqual(world.uploads.map(\.localId), ["a"], "case \(index)")
            XCTAssertNil(outcome.message, "case \(index)")
            XCTAssertTrue(outcome.completedDestinations.isEmpty, "case \(index)")
            let attempts = await ledger.attempts("a", for: "one")
            XCTAssertEqual(attempts, 0, "case \(index)")
            let interruptions = await ledger.interruptions(for: "one")
            XCTAssertEqual(interruptions["a"], 1, "case \(index)")
            let listed = await ledger.failures(for: "one")
            XCTAssertTrue(listed.isEmpty, "case \(index)")
        }
    }

    func testADecodeErrorAfterSuccessIsNotUploadedAgain() async {
        let ledger = self.ledger()
        let broken = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "not a body")
        )
        let world = World()
        world.answers["a"] = .failure(broken)
        let outcome = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(outcome.uploaded, 1)
        let attempts = await ledger.attempts("a", for: "one")
        XCTAssertEqual(attempts, 0)
        let record = await ledger.record("a", for: "one")
        XCTAssertNil(record?.assetId)
        XCTAssertEqual(record?.landed, true)
        XCTAssertNotEqual(record?.failureState, .givenUp)
        let settled = await ledger.settled(for: "one")
        XCTAssertTrue(settled.contains("a"))
        let listed = await ledger.failures(for: "one")
        XCTAssertFalse(listed.contains { $0.localId == "a" })

        let again = World()
        again.answers["a"] = .failure(broken)
        _ = await runBackupPass(
            ["a", "b"], to: [account("one")], ledger: ledger, effects: again.effects()
        )
        XCTAssertFalse(again.uploads.map(\.localId).contains("a"))
        XCTAssertFalse(again.exported.contains("a"))
    }

    func testOneDestinationsDeferralsDoNotReorderAnother() async {
        let ledger = self.ledger()
        for _ in 1...deferAfterInterruptions {
            await ledger.recordInterruption("a", for: "two")
        }
        let world = World()
        _ = await runBackupPass(
            ["a", "b"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(
            world.uploads.filter { $0.accountId == "one" }.map(\.localId), ["a", "b"]
        )
        XCTAssertEqual(
            world.uploads.filter { $0.accountId == "two" }.map(\.localId), ["a", "b"]
        )
    }

    func testAFileEveryDestinationKeepsMissingGoesToTheBack() async {
        let ledger = self.ledger()
        for accountId in ["one", "two"] {
            for _ in 1...deferAfterInterruptions {
                await ledger.recordInterruption("a", for: accountId)
            }
        }
        let world = World()
        _ = await runBackupPass(
            ["a", "b"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(
            world.uploads.map { "\($0.accountId)/\($0.localId)" },
            ["one/b", "two/b", "one/a", "two/a"]
        )
    }

    func testADeferralStillMovesTheFileWhenItIsTheOnlyDestinationLeft() async {
        let ledger = self.ledger()
        await ledger.put(UploadRecord(localId: "a", assetId: "remote-a"), for: "one")
        for _ in 1...deferAfterInterruptions {
            await ledger.recordInterruption("a", for: "two")
        }
        let world = World()
        _ = await runBackupPass(
            ["a", "b"], to: [account("one"), account("two")],
            ledger: ledger, effects: world.effects()
        )

        XCTAssertEqual(
            world.uploads.filter { $0.accountId == "two" }.map(\.localId), ["b", "a"]
        )
    }

    func testInterruptionsForAssetsThatAreGoneAreDropped() async {
        let ledger = self.ledger()
        await ledger.recordInterruption("deleted", for: "one")
        await ledger.recordInterruption("excluded", for: "one")
        let world = World()
        _ = await runBackupPass(
            ["a"], to: [account("one")], ledger: ledger, effects: world.effects()
        )

        let left = await ledger.interruptions(for: "one")
        XCTAssertNil(left["deleted"])
        XCTAssertNil(left["excluded"])
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

    func testAPermanentLocalFailureSpendsAnAttempt() {
        XCTAssertEqual(uploadDisposition(of: Unreadable()), .rejected)
        XCTAssertTrue(uploadDisposition(of: Unreadable()).spendsAttempt)

        let outOfSpace = CocoaError(.fileWriteOutOfSpace)
        XCTAssertEqual(uploadDisposition(of: outOfSpace), .rejected)
        XCTAssertTrue(uploadDisposition(of: outOfSpace).spendsAttempt)
    }

    func testOnlyASettledAnswerSpendsAnAttempt() {
        let refusal = ImogenError(status: 415, code: "unsupported", message: "No")
        XCTAssertTrue(uploadDisposition(of: refusal).spendsAttempt)
        XCTAssertTrue(uploadDisposition(of: ExportFailure.noUsableResource).spendsAttempt)

        let transientOnes: [Error] = [
            CancellationError(), URLError(.cancelled), URLError(.timedOut),
            ImogenError(status: 401, code: "unauthorized", message: "No"),
            ImogenError(status: 401, code: refreshedNotReplayed, message: "No"),
            ImogenError(status: 403, code: "forbidden", message: "No"),
            DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "not a body")
            ),
        ]
        for error in transientOnes {
            XCTAssertFalse(uploadDisposition(of: error).spendsAttempt, "\(error)")
        }
    }

    func testAStaleTokenIsTheSessionsProblem() {
        for status in [401, 403] {
            let error = ImogenError(status: status, code: "unauthorized", message: "No")
            XCTAssertEqual(uploadDisposition(of: error), .unauthorized)
            XCTAssertFalse(uploadDisposition(of: error).spendsAttempt)
        }
    }

    func testABodyThatWillNotDecodeOrEncodeIsBounded() {
        let decoded = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "not a body")
        )
        XCTAssertEqual(uploadDisposition(of: decoded), .landed)
        XCTAssertFalse(uploadDisposition(of: decoded).spendsAttempt)

        let accepted = ImogenError(status: 200, code: "unreadable_body", message: "No")
        XCTAssertEqual(uploadDisposition(of: accepted), .landed)
        XCTAssertFalse(uploadDisposition(of: accepted).spendsAttempt)

        let encoded = EncodingError.invalidValue(
            0, EncodingError.Context(codingPath: [], debugDescription: "not a body")
        )
        XCTAssertEqual(uploadDisposition(of: encoded), .rejected)
        XCTAssertTrue(uploadDisposition(of: encoded).spendsAttempt)
    }

    func testARefreshed401IsNotUnauthorised() {
        let error = ImogenError(status: 401, code: refreshedNotReplayed, message: "No")
        XCTAssertEqual(uploadDisposition(of: error), .deferred)
        XCTAssertFalse(uploadDisposition(of: error).spendsAttempt)
        XCTAssertNotEqual(uploadDisposition(of: error), .unauthorized)
    }
}


/// Stands in for the Cocoa and PhotoKit errors the SDK and the photo library actually
/// throw, none of which is a `URLError` or an `ImogenError`.
struct Unreadable: Error {}

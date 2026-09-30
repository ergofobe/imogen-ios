import Foundation
import ImogenSDK

/// How far a pass has got. Nil between passes.
public struct BackupProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int
    public var filename: String?

    public init(completed: Int, total: Int, filename: String? = nil) {
        self.completed = completed
        self.total = total
        self.filename = filename
    }
}

/// Why a file did not end up on the server.
///
/// They differ in what they cost, and the cost is the whole point. Only the first spends
/// one of the file's attempts, because only the first is an answer that will not change:
/// "Anything transient is the server's problem, not this file's, and must not spend its
/// attempts" — which is the rule ergofobe/imogen-ios#39 found being broken three lines
/// below where it was written.
public enum UploadDisposition: Equatable, Sendable {
    /// The server refused this file and will refuse it again — a type it will not take, a
    /// quota that is full.
    case rejected

    /// The server or the network is having a bad day. Nothing to do with this file.
    case unavailable

    /// The pass was stopped before it finished: the Stop button, or a `BGProcessingTask`
    /// expiring overnight, which is routine rather than an error.
    case cancelled

    /// Something that is not this file's settled answer and not a destination outage —
    /// a local read problem. Costs the file nothing and the destination nothing; it
    /// only moves the file out of the queue's way.
    case deferred

    /// The session will not authorise this destination. A 401 that reaches the pass
    /// is a refresh that came back empty; a 403 is never refreshed. This destination
    /// is done for the pass. The file's attempts are not.
    case unauthorized

    /// Whether this costs the file one of its `maxUploadAttempts`, after which
    /// `settled(for:)` folds it away and no later pass tries it again.
    public var spendsAttempt: Bool { self == .rejected }
}

/// The photo library had nothing to give. Unlike everything else that can go wrong
/// locally, this answer does not change with the weather, so it is the one local failure
/// that counts against the file.
public enum ExportFailure: Error, LocalizedError, Equatable, Sendable {
    /// The asset is no longer in the library.
    case noSuchAsset
    /// The asset carries no photograph or video resource to send.
    case noUsableResource

    public var errorDescription: String? {
        switch self {
        case .noSuchAsset: return "This photograph is no longer on the device."
        case .noUsableResource: return "This device would not hand over the file."
        }
    }
}

/// What one failure means for the file, for the destination, and for the pass.
///
/// Cancellation arrives in two shapes and both reach here. `URLSession` answers a
/// cancelled task with `URLError(.cancelled)` rather than a `CancellationError`, and the
/// SDK hands it straight back: a small upload is sent `isMultipart: true`, which makes it
/// unreplayable, so `HTTPClient.send` rethrows rather than retrying. A large one takes the
/// resumable route, whose chunks *are* replayable — so the SDK reaches its backoff, and
/// `Task.sleep` on a cancelled task throws `CancellationError`.
///
/// Everything that is neither the network nor a settled answer is `.deferred` rather than
/// the file's fault. The SDK throws plain Cocoa errors from `fileSize(of:)`,
/// `Data(contentsOf:)` and `FileHandle`, and the photo library throws its own while
/// fetching an asset that lives in iCloud — all of them conditions that pass.
///
/// A body that will not decode, or a value that will not encode, is not one of those.
/// The upload may already have landed, and leaving it `.deferred` re-exports it forever.
public func uploadDisposition(of error: Error) -> UploadDisposition {
    if error is CancellationError { return .cancelled }
    if let url = error as? URLError {
        return url.code == .cancelled ? .cancelled : .unavailable
    }
    if error is ExportFailure { return .rejected }
    if error is DecodingError || error is EncodingError { return .rejected }
    guard let imogen = error as? ImogenError else { return .deferred }
    // A 401 that arrives here is a refresh that came back empty. A 403 is never
    // refreshed. Neither is this file's fault, and neither is the server being down.
    if imogen.isAuthError { return .unauthorized }
    // Status 0 is the SDK's "the request never reached a server".
    return imogen.isRetryable || imogen.status == 0 ? .unavailable : .rejected
}

/// What to write against the file when a failure is recorded.
public func uploadFailureMessage(_ error: Error) -> String {
    (error as? ImogenError)?.message ?? error.localizedDescription
}

/// How many times a pass may be cut short on one file before later passes stop letting it
/// hold up the queue.
public let deferAfterInterruptions = 2

/// Oldest first, except for files a pass keeps being cut short on, which go to the back.
///
/// This is what bounds the loop now that a cancellation no longer spends a file's
/// attempts. It used to be bounded by accident: a video too big to finish inside a
/// background window reached `givenUp` after three overnight expiries, and `settled(for:)`
/// folded it away — which is the bug, not the bound. Moving it out of the way instead
/// means everything queued behind it gets through, while the file itself is still tried on
/// every pass, at the end, where a longer window eventually finishes it. Nothing is ever
/// abandoned.
///
/// Stable within each group, so the oldest-first order the library was read in survives.
public func passOrder(_ localIds: [String], deferring interruptions: [String: Int]) -> [String] {
    let held = Set(localIds.filter { (interruptions[$0] ?? 0) >= deferAfterInterruptions })
    guard !held.isEmpty else { return localIds }
    return localIds.filter { !held.contains($0) } + localIds.filter { held.contains($0) }
}

/// Everything a pass does to the world, gathered in one place so that a test can watch it.
///
/// The loop itself holds no PhotoKit, no URLSession and no clock, which is what lets it
/// live here rather than in the app target — `swift test` does not compile `App/Sources`
/// at all, so a decision left up there is a decision nothing can fail on.
@MainActor
public struct BackupPassEffects {
    /// Writes the asset's bytes somewhere the uploader can open them.
    ///
    /// The failure carries the reason, because it decides what happens next: an export
    /// cut short by an expiring window is the same `.cancelled` as an upload cut short,
    /// and treating it as the file's own fault is how a large video gets abandoned.
    public var export: (String) async -> Result<URL, Error>

    /// Gets rid of an export, whatever became of it.
    public var dispose: (URL) async -> Void

    /// Sends one file to one destination, answering with the remote asset id or why not.
    public var upload: (URL, String, Account) async -> Result<String, Error>

    /// Where the pass has got to, and nil when it is over.
    public var report: (BackupProgress?) -> Void

    /// Whether the pass has been stopped.
    public var isCancelled: () -> Bool

    public init(
        export: @escaping (String) async -> Result<URL, Error>,
        dispose: @escaping (URL) async -> Void,
        upload: @escaping (URL, String, Account) async -> Result<String, Error>,
        report: @escaping (BackupProgress?) -> Void,
        isCancelled: @escaping () -> Bool
    ) {
        self.export = export
        self.dispose = dispose
        self.upload = upload
        self.report = report
        self.isCancelled = isCancelled
    }
}

/// What a pass leaves behind.
public struct BackupPassOutcome: Equatable, Sendable {
    /// How many files actually arrived somewhere.
    public var uploaded: Int

    /// Destinations whose "last completed" this pass stamps. Nothing arriving does not.
    public var completedDestinations: [String]

    /// What to put on screen, and nil when nothing needs saying.
    public var message: String?

    public init(
        uploaded: Int = 0,
        completedDestinations: [String] = [],
        message: String? = nil
    ) {
        self.uploaded = uploaded
        self.completedDestinations = completedDestinations
        self.message = message
    }
}

/// One backup pass: every outstanding file, to every destination that asked for it.
///
/// One pass for all of them rather than one each, because the expensive step is getting a
/// two-gigabyte video out of the photo library and doing that once per destination instead
/// of once would make a second account cost twice as much battery as the first.
@MainActor
public func runBackupPass(
    _ localIds: [String],
    to destinations: [Account],
    ledger: UploadLedger,
    effects: BackupPassEffects
) async -> BackupPassOutcome {
    var outstanding: [String: Set<String>] = [:]
    var interruptions: [String: [String: Int]] = [:]
    for account in destinations {
        let settled = await ledger.settled(for: account.id)
        outstanding[account.id] = settled
        // Settled files will not be tried again, and an asset that is gone or excluded
        // is not in this pass's queue either. Both would otherwise sit in a file read
        // in full at the start of every pass.
        await ledger.pruneInterruptions(
            settled: settled, present: Set(localIds), for: account.id
        )
        interruptions[account.id] = await ledger.interruptions(for: account.id)
    }

    func wanted(_ localId: String, by account: Account) -> Bool {
        !(outstanding[account.id]?.contains(localId) ?? false)
    }

    var owed: [String: Int] = [:]
    for account in destinations {
        owed[account.id] = localIds.count { wanted($0, by: account) }
    }
    let total = owed.values.reduce(0, +)
    guard total > 0 else {
        // Everything is already there. Worth recording, because "up to date at 04:12" and
        // "nothing has ever run" are the two states this screen most needs to separate.
        let ids = destinations.map(\.id)
        await recordCompleted(ids, in: ledger)
        return BackupPassOutcome(completedDestinations: ids)
    }

    var uploaded = 0
    var completed = 0
    var message: String?
    var cancelled = false
    /// Destinations out for the rest of this pass. Only ever added to, which is what makes
    /// the walk below finite.
    var unreachable: Set<String> = []
    var accepted: Set<String> = []
    /// Pairs each destination has an answer about, so that dropping one can credit the
    /// rest of its queue to the progress bar rather than freezing it part-way.
    var dealtWith: [String: Int] = [:]

    /// One pair answered. `.unavailable` does not come through here: it ends the
    /// destination, and everything it still wanted is credited in one go.
    func answered(_ accountId: String) {
        dealtWith[accountId, default: 0] += 1
        completed += 1
    }

    /// This destination is out. Its whole remaining queue is as dealt with as it is going
    /// to get this pass.
    func drop(_ accountId: String) {
        completed += (owed[accountId] ?? 0) - (dealtWith[accountId] ?? 0)
        unreachable.insert(accountId)
    }

    effects.report(BackupProgress(completed: 0, total: total))
    defer { effects.report(nil) }

    // Held back only when every destination still waiting has been cut short on it.
    // One destination's deferrals must not reorder a destination that has not.
    var heldBack: [String: Int] = [:]
    for localId in localIds {
        let wanting = destinations.filter { wanted(localId, by: $0) }
        guard !wanting.isEmpty else { continue }
        let stuck = wanting.allSatisfy {
            (interruptions[$0.id]?[localId] ?? 0) >= deferAfterInterruptions
        }
        if stuck { heldBack[localId] = deferAfterInterruptions }
    }

    for localId in passOrder(localIds, deferring: heldBack) {
        if effects.isCancelled() {
            cancelled = true
            break
        }
        let wantedBy = destinations.filter {
            wanted(localId, by: $0) && !unreachable.contains($0.id)
        }
        if wantedBy.isEmpty {
            // Either the file is settled everywhere, or every destination still wanting it
            // has already had its bad day. Nothing left to push at.
            if unreachable.count == destinations.count { break }
            continue
        }

        // Fetched once, sent to each destination. This is the expensive step, and the long
        // one: a window that expires during a big video expires here, not in the upload.
        var file: URL?
        var exportFailure: Error?

        for account in wantedBy {
            if file == nil {
                switch await effects.export(localId) {
                case .success(let url): file = url
                case .failure(let error):
                    exportFailure = error
                }
                if file == nil { break }
            }
            guard let file else { break }

            effects.report(
                BackupProgress(
                    completed: completed, total: total, filename: file.lastPathComponent
                )
            )

            switch await effects.upload(file, localId, account) {
            case .success(let assetId):
                await ledger.put(
                    UploadRecord(localId: localId, assetId: assetId), for: account.id
                )
                await ledger.clearInterruption(localId, for: account.id)
                uploaded += 1
                accepted.insert(account.id)
                answered(account.id)
            case .failure(let error):
                // Before auth or reachability. A stop that arrives as
                // `networkConnectionLost`, or a cancelled refresh that arrives as a
                // 401, is the pass ending — not this destination being down, and not
                // a failure row for a file the pass was told to leave alone.
                let disposition = uploadDisposition(of: error)
                if disposition == .cancelled || effects.isCancelled() {
                    await ledger.recordInterruption(localId, for: account.id)
                    cancelled = true
                } else {
                    switch disposition {
                    case .unavailable:
                        // This server is having a bad day. Stop pushing at it — and only at
                        // it, because a dead second server must not hold up a healthy first.
                        message = "Couldn't reach the server. Backup will carry on later."
                        drop(account.id)
                    case .unauthorized:
                        message = "Sign in again. Backup will carry on once you do."
                        await recordProblem(
                            localId, for: account.id, because: uploadFailureMessage(error),
                            named: file.lastPathComponent,
                            spendingAttempt: disposition.spendsAttempt, in: ledger
                        )
                        drop(account.id)
                    case .rejected, .deferred:
                        // `spendsAttempt` asked rather than restated: the rule #39 is about
                        // must have one home, or changing it changes nothing here.
                        await recordProblem(
                            localId, for: account.id, because: uploadFailureMessage(error),
                            named: file.lastPathComponent,
                            spendingAttempt: disposition.spendsAttempt, in: ledger
                        )
                        if disposition == .deferred {
                            await ledger.recordInterruption(localId, for: account.id)
                        }
                        answered(account.id)
                    case .cancelled:
                        break
                    }
                }
            }

            if cancelled { break }
        }

        // One disposal site for every way out of the item, rather than one per `return`.
        // A missed one leaks a full-size export — up to a multi-gigabyte video — and
        // nothing sweeps that directory.
        if let file { await effects.dispose(file) }

        if let exportFailure {
            // Asked of the same classifier, but only to tell a cut-short pass from the
            // rest: whatever went wrong getting the bytes off this device, it is not a
            // destination's doing and must not take one down. The photo library's failures
            // are as transient as the network it reaches into for an asset in iCloud.
            //
            // `isCancelled` as well as the error, because PhotoKit answers a
            // `writeData` it cannot finish with an `NSError` of its own — never a
            // `CancellationError` — so the expiring window that #39 is about would
            // otherwise be read as the file's bad luck rather than the clock's.
            let disposition = uploadDisposition(of: exportFailure)
            if disposition == .cancelled || effects.isCancelled() {
                for account in wantedBy {
                    await ledger.recordInterruption(localId, for: account.id)
                }
                cancelled = true
            } else {
                for account in wantedBy {
                    await recordProblem(
                        localId, for: account.id,
                        because: uploadFailureMessage(exportFailure),
                        named: nil, spendingAttempt: disposition.spendsAttempt, in: ledger
                    )
                    if disposition == .deferred {
                        await ledger.recordInterruption(localId, for: account.id)
                    }
                    answered(account.id)
                }
            }
        }

        if cancelled { break }
        if unreachable.count == destinations.count { break }
    }

    // A pass that was stopped part-way knows nothing about what it did not reach, and says
    // so by claiming nothing — and by blaming nobody, because nothing went wrong.
    if cancelled { return BackupPassOutcome(uploaded: uploaded) }

    // The progress reported before each upload names the file being sent, so the last of
    // them is one short. Said once more at the end, so the bar arrives rather than stopping
    // just before the end and vanishing.
    effects.report(BackupProgress(completed: completed, total: total))

    // "Last completed" means something from this destination arrived. A pass that
    // delivered nothing — deferred, refused, or signed out — must not move it, or
    // settings says the backup finished. One bad photograph beside a file that did
    // arrive still stamps, which is the regression ergofobe/imogen-ios#37 shipped
    // a withheld timestamp for.
    let complete = destinations.map(\.id).filter { accepted.contains($0) }
    await recordCompleted(complete, in: ledger)
    return BackupPassOutcome(
        uploaded: uploaded, completedDestinations: complete, message: message
    )
}

private func recordCompleted(_ accountIds: [String], in ledger: UploadLedger) async {
    let now = Date().timeIntervalSince1970
    for accountId in accountIds {
        await ledger.recordCompleted(at: now, for: accountId)
    }
}

/// A file this destination could not take, on the failures screen where somebody can see
/// it. `spendingAttempt` is the whole of ergofobe/imogen-ios#39: only an answer that will
/// not change may move the file towards `givenUp`.
private func recordProblem(
    _ localId: String,
    for accountId: String,
    because message: String,
    named name: String?,
    spendingAttempt: Bool,
    in ledger: UploadLedger
) async {
    let existing = await ledger.record(localId, for: accountId)
    await ledger.put(
        UploadRecord(
            localId: localId,
            attempts: spendingAttempt ? (existing?.attempts ?? 0) + 1 : existing?.attempts ?? 0,
            lastError: message,
            // Recorded rather than looked up later: a PHAsset since deleted off the phone
            // still deserves to be nameable in a list of what went wrong. A failure with no
            // name of its own — nothing got as far as an export — keeps the one already
            // there rather than replacing it with the opaque local identifier.
            displayName: name ?? existing?.displayName
        ),
        for: accountId
    )
}


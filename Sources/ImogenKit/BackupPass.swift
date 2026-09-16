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

/// Why an upload did not leave the file on the server.
///
/// The three differ in what they cost, and the cost is the whole point: a rejection is the
/// file's own problem and spends one of its attempts, unavailability is the destination's
/// problem and costs it the rest of the pass, and being cut short is nobody's problem and
/// costs nothing at all.
public enum UploadDisposition: Equatable, Sendable {
    /// The server will keep refusing this file — a type it will not take, a quota that
    /// is full — or the device cannot read the file in the first place.
    case rejected

    /// The server or the network is having a bad day.
    case unavailable

    /// The upload was stopped before it finished: the Stop button, or a
    /// `BGProcessingTask` expiring overnight, which is routine rather than an error.
    case cancelled

    /// Whether this costs the file one of its `maxUploadAttempts`, after which
    /// `settled(for:)` folds it away and no later pass tries it again.
    public var spendsAttempt: Bool { self == .rejected }
}

/// What one upload failure means for the file and for the pass.
///
/// Cancellation arrives in two shapes and both reach here. `URLSession` answers a
/// cancelled task with `URLError(.cancelled)` rather than a `CancellationError`, and the
/// SDK hands it straight back: a small upload is sent `isMultipart: true`, which makes it
/// unreplayable, so `HTTPClient.send` rethrows rather than retrying. A large one goes the
/// resumable route, whose chunks *are* replayable — so the SDK reaches its backoff, and
/// `Task.sleep` on a cancelled task throws `CancellationError`. Neither is this file's
/// fault. ergofobe/imogen-ios#39.
public func uploadDisposition(of error: Error) -> UploadDisposition {
    if error is CancellationError { return .cancelled }
    if let url = error as? URLError {
        return url.code == .cancelled ? .cancelled : .unavailable
    }
    guard let imogen = error as? ImogenError else {
        // Not the network and not the server: something local went wrong with this file,
        // and that is the file's own problem. It has to spend attempts, or a file nothing
        // can read is exported afresh by every pass for ever.
        return .rejected
    }
    // Status 0 is the SDK's "the request never reached a server".
    return imogen.isRetryable || imogen.status == 0 ? .unavailable : .rejected
}

/// What to write against the file when a failure is recorded.
public func uploadFailureMessage(_ error: Error) -> String {
    (error as? ImogenError)?.message ?? error.localizedDescription
}

/// What is said about a file the device would not hand over.
public let exportFailureMessage = "This device would not hand over the file."

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
    /// Writes the asset's bytes somewhere the uploader can open them, or nil when the
    /// asset cannot be exported at all.
    public var export: (String) async -> URL?

    /// Gets rid of an export, whatever became of it.
    public var dispose: (URL) async -> Void

    /// Sends one file to one destination, answering with the remote asset id or why not.
    public var upload: (URL, String, Account) async -> Result<String, Error>

    /// Where the pass has got to, and nil when it is over.
    public var report: (BackupProgress?) -> Void

    /// Whether the pass has been stopped.
    public var isCancelled: () -> Bool

    public init(
        export: @escaping (String) async -> URL?,
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

    /// Destinations that received everything this pass set out to send them, and so have
    /// their "last completed" stamped.
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
    var interruptions: [String: Int] = [:]
    for account in destinations {
        outstanding[account.id] = await ledger.settled(for: account.id)
        // The worst any destination has seen. The expensive step is the export, which is
        // shared, so a file too big to finish is too big whichever server it was going to.
        for (localId, count) in await ledger.interruptions(for: account.id) {
            interruptions[localId] = max(interruptions[localId] ?? 0, count)
        }
    }

    func wanted(_ localId: String, by account: Account) -> Bool {
        !(outstanding[account.id]?.contains(localId) ?? false)
    }

    let total = localIds.reduce(0) { running, localId in
        running + destinations.count { wanted(localId, by: $0) }
    }
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
    /// Destinations that did not get everything, and so may not claim to be up to date.
    var shortfall: Set<String> = []

    effects.report(BackupProgress(completed: 0, total: total))
    defer { effects.report(nil) }

    for localId in passOrder(localIds, deferring: interruptions) {
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

        // Fetched once, sent to each destination. This is the expensive step.
        var file: URL?
        var exportFailed = false

        for account in wantedBy {
            if file == nil {
                file = await effects.export(localId)
                if file == nil {
                    exportFailed = true
                    break
                }
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
                completed += 1
            case .failure(let error):
                switch uploadDisposition(of: error) {
                case .rejected:
                    await spendAttempt(
                        localId,
                        for: account.id,
                        because: uploadFailureMessage(error),
                        named: file.lastPathComponent,
                        in: ledger
                    )
                    shortfall.insert(account.id)
                    // Only what is dealt with. Counting a transient failure here is what
                    // let a pass in which nothing arrived report the same progress as one
                    // that worked.
                    completed += 1
                case .unavailable:
                    // This server is having a bad day. Stop pushing at it — and only at
                    // it, because a dead second server must not hold up a healthy first.
                    message = "Couldn't reach the server. Backup will carry on later."
                    unreachable.insert(account.id)
                    shortfall.insert(account.id)
                case .cancelled:
                    await ledger.recordInterruption(localId, for: account.id)
                    cancelled = true
                }
            }

            if cancelled { break }
        }

        // One disposal site for every way out of the item, rather than one per `return`.
        // A missed one leaks a full-size export — up to a multi-gigabyte video — and
        // nothing sweeps that directory.
        if let file { await effects.dispose(file) }

        if exportFailed {
            for account in wantedBy {
                await spendAttempt(
                    localId,
                    for: account.id,
                    because: exportFailureMessage,
                    named: localId,
                    in: ledger
                )
                shortfall.insert(account.id)
                completed += 1
            }
        }

        if cancelled { break }
        if unreachable.count == destinations.count { break }
    }

    // A pass that was stopped part-way knows nothing about what it did not reach, and says
    // so by claiming nothing — and by blaming nobody, because nothing went wrong.
    if cancelled { return BackupPassOutcome(uploaded: uploaded) }

    let complete = destinations.map(\.id).filter { !shortfall.contains($0) }
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

private func spendAttempt(
    _ localId: String,
    for accountId: String,
    because message: String,
    named name: String,
    in ledger: UploadLedger
) async {
    let attempts = await ledger.attempts(localId, for: accountId)
    await ledger.put(
        UploadRecord(
            localId: localId,
            attempts: attempts + 1,
            lastError: message,
            // Recorded rather than looked up later: a PHAsset since deleted off the phone
            // still deserves to be nameable in a list of what went wrong.
            displayName: name
        ),
        for: accountId
    )
}

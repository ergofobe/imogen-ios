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
/// problem and spends none, and being cut short is nobody's problem at all.
public enum UploadDisposition: Equatable, Sendable {
    /// The server will keep refusing this file — a type it will not take, a quota that
    /// is full.
    case rejected

    /// The server or the network is having a bad day.
    case unavailable

    /// The upload was stopped before it finished: the Stop button, or a
    /// `BGProcessingTask` expiring overnight.
    case interrupted

    /// Whether this costs the file one of its `maxUploadAttempts`, after which
    /// `settled(for:)` folds it away and no later pass tries it again.
    public var spendsAttempt: Bool {
        switch self {
        case .rejected, .interrupted: return true
        case .unavailable: return false
        }
    }

    /// Whether there is any point carrying on with this pass.
    public var endsPass: Bool {
        switch self {
        case .rejected: return false
        case .unavailable, .interrupted: return true
        }
    }
}

/// What one upload failure means for the file and for the pass.
public func uploadDisposition(of error: Error) -> UploadDisposition {
    guard let imogen = error as? ImogenError else { return .interrupted }
    // Status 0 is the SDK's "the request never reached a server".
    return imogen.isRetryable || imogen.status == 0 ? .unavailable : .rejected
}

/// What to write against the file when a failure is recorded.
public func uploadFailureMessage(_ error: Error) -> String {
    (error as? ImogenError)?.message ?? error.localizedDescription
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
    for account in destinations {
        outstanding[account.id] = await ledger.settled(for: account.id)
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
        await recordCompleted(destinations, in: ledger)
        return BackupPassOutcome(completedDestinations: destinations.map(\.id))
    }

    var uploaded = 0
    var completed = 0
    var message: String?
    effects.report(BackupProgress(completed: 0, total: total))
    defer { effects.report(nil) }

    for localId in localIds {
        if effects.isCancelled() {
            return BackupPassOutcome(uploaded: uploaded)
        }

        // Fetched once, sent to each destination. This is the expensive step.
        var file: URL?
        var stop = false

        for account in destinations where wanted(localId, by: account) {
            if file == nil {
                file = await effects.export(localId)
                guard file != nil else { break }
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
                uploaded += 1
                completed += 1
            case .failure(let error):
                let disposition = uploadDisposition(of: error)
                if disposition.spendsAttempt {
                    await spendAttempt(
                        localId,
                        for: account.id,
                        because: uploadFailureMessage(error),
                        named: file.lastPathComponent,
                        in: ledger
                    )
                }
                if disposition.endsPass {
                    // The server or the network is having a bad day. Stop pushing at it;
                    // the next pass will pick up where this one left off.
                    message = "Couldn't reach the server. Backup will carry on later."
                    stop = true
                } else {
                    // Only what is dealt with. Counting a transient failure here is what
                    // let a pass in which nothing arrived report the same progress as one
                    // that worked.
                    completed += 1
                }
            }

            if stop { break }
        }

        // One disposal site for every way out of the item, rather than one per `return`.
        // A missed one leaks a full-size export — up to a multi-gigabyte video — and
        // nothing sweeps that directory.
        if let file { await effects.dispose(file) }
        if stop { return BackupPassOutcome(uploaded: uploaded, message: message) }
    }

    await recordCompleted(destinations, in: ledger)
    return BackupPassOutcome(
        uploaded: uploaded, completedDestinations: destinations.map(\.id)
    )
}

private func recordCompleted(_ destinations: [Account], in ledger: UploadLedger) async {
    let now = Date().timeIntervalSince1970
    for account in destinations {
        await ledger.recordCompleted(at: now, for: account.id)
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

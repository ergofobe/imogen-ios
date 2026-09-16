import Foundation

/// What has already gone where.
///
/// The account and the local asset together make the key, and that is the whole design:
/// choosing three accounts means three copies, so "already uploaded" is a question about a
/// pair, never about a photograph on its own.
///
/// The server would deduplicate a re-upload by checksum anyway. This exists so the phone
/// does not read, hash and post four thousand files every time the task wakes up in order
/// to be told it need not have bothered.
public struct UploadRecord: Codable, Hashable, Sendable {
    public var localId: String
    public var assetId: String?
    public var uploadedAt: Double
    /// A row with attempts and no `assetId` is a thing to try again later. Without it a
    /// permanently broken file is retried on every single pass.
    public var attempts: Int
    public var lastError: String?
    /// What the file was called when it was tried. Optional because rows written before
    /// this existed have none — and because a decoder that refused them would take a
    /// backup's whole history with it on upgrade.
    public var displayName: String?

    public init(
        localId: String,
        assetId: String? = nil,
        uploadedAt: Double = Date().timeIntervalSince1970,
        attempts: Int = 0,
        lastError: String? = nil,
        displayName: String? = nil
    ) {
        self.localId = localId
        self.assetId = assetId
        self.uploadedAt = uploadedAt
        self.attempts = attempts
        self.lastError = lastError
        self.displayName = displayName
    }

    public var isDone: Bool { assetId != nil }

    /// Whether this failure is still in the running.
    public var failureState: FailureState {
        attempts >= maxUploadAttempts ? .givenUp : .willRetry
    }

    /// The local identifier is a poor name, and still better than a blank row.
    public var name: String { displayName ?? localId }
}

/// One outstanding upload: a photograph *and* the destination it has not reached.
///
/// The ledger is keyed per account, so the same photograph failing on two servers is two
/// of these, not one. See `id` for why that has to be said out loud.
public struct UploadFailure: Identifiable, Hashable, Sendable {
    public var account: Account
    public var record: UploadRecord

    public init(account: Account, record: UploadRecord) {
        self.account = account
        self.record = record
    }

    /// Account and photograph together, which is the ledger's own key and the only pair
    /// that is unique: `localId` names the photograph, and choosing two destinations means
    /// the same one can fail twice. Keyed on the photograph alone, SwiftUI draws one row
    /// for two failures and the destination it dropped keeps its `givenUp` for ever.
    ///
    /// Two fields rather than a joined string because a `localId` contains slashes of its
    /// own, and nothing here is worth a separator that could be misread.
    ///
    /// Neither field moves when `retry` rewrites the row's attempts and error, so the
    /// reload that follows a retry leaves rows where they were instead of rebuilding them.
    public struct ID: Hashable, Sendable {
        public var accountId: String
        public var localId: String
    }

    public var id: ID { ID(accountId: account.id, localId: record.localId) }
}

/// Whether a failed file will be tried again on its own.
public enum FailureState: Equatable {
    /// Attempts remain; the next pass picks it up without being asked.
    case willRetry

    /// Attempts exhausted. `settled(for:)` folds these away, so nothing tries again and
    /// nothing mentions it — which is how a fixed bug becomes permanently missing
    /// photographs.
    case givenUp
}

public struct FailureSummary: Equatable {
    public var willRetry: Int
    public var givenUp: Int
    public var total: Int { willRetry + givenUp }
}

public func summarise(_ records: [UploadRecord]) -> FailureSummary {
    FailureSummary(
        willRetry: records.filter { $0.failureState == .willRetry }.count,
        givenUp: records.filter { $0.failureState == .givenUp }.count
    )
}

/// How many times a file is retried before it is left alone.
public let maxUploadAttempts = 3

/// The ledger, on disk as one JSON file per account.
///
/// Not Core Data. This is a set of identifiers with a counter attached, it is read once at
/// the start of a pass and appended to as the pass runs, and a store with a migration
/// story would be a great deal of ceremony for that.
public actor UploadLedger {
    private let directory: URL
    private var loaded: [String: [String: UploadRecord]] = [:]
    private var loadedInterruptions: [String: [String: Int]] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    public func records(for accountId: String) -> [String: UploadRecord] {
        if let cached = loaded[accountId] { return cached }
        let url = file(for: accountId)
        let decoded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: UploadRecord].self, from: $0) }
            ?? [:]
        loaded[accountId] = decoded
        return decoded
    }

    /// Local identifiers that need no further attention: done, or tried too often.
    public func settled(for accountId: String) -> Set<String> {
        Set(
            records(for: accountId)
                .filter { $0.value.isDone || $0.value.attempts >= maxUploadAttempts }
                .keys
        )
    }

    public func put(_ record: UploadRecord, for accountId: String) {
        var current = records(for: accountId)
        current[record.localId] = record
        loaded[accountId] = current
        persist(accountId)
    }

    public func attempts(_ localId: String, for accountId: String) -> Int {
        records(for: accountId)[localId]?.attempts ?? 0
    }

    public func record(_ localId: String, for accountId: String) -> UploadRecord? {
        records(for: accountId)[localId]
    }

    /// Everything outstanding for one account, newest first.
    public func failures(for accountId: String) -> [UploadRecord] {
        records(for: accountId).values
            .filter { !$0.isDone }
            .sorted { $0.uploadedAt > $1.uploadedAt }
    }

    /// Everything outstanding across several destinations, newest first.
    ///
    /// Flattened here rather than at the call site so that the pairing is covered by a
    /// test: one entry per destination, never one per photograph.
    public func failures(for accounts: [Account]) -> [UploadFailure] {
        accounts
            .flatMap { account in
                failures(for: account.id).map { UploadFailure(account: account, record: $0) }
            }
            .sorted(by: Self.newestFirst)
    }

    /// Newest first, then a fixed order. The ledger is a dictionary, so rows sharing a
    /// timestamp come out in no particular order and a bare sort on the timestamp alone
    /// would reshuffle them on every reload. The tie-break also puts one photograph's two
    /// destinations next to each other, which is where a reader expects them.
    private static func newestFirst(_ lhs: UploadFailure, _ rhs: UploadFailure) -> Bool {
        if lhs.record.uploadedAt != rhs.record.uploadedAt {
            return lhs.record.uploadedAt > rhs.record.uploadedAt
        }
        if lhs.record.localId != rhs.record.localId {
            return lhs.record.localId < rhs.record.localId
        }
        return lhs.account.id < rhs.account.id
    }

    /// Puts one file back in the running.
    ///
    /// `settled` is computed from the attempt count, so zeroing it is what actually undoes
    /// the giving-up — anything less leaves the file skipped by every future pass. The
    /// reason goes with it rather than staying to describe a failure that is no longer the
    /// current answer.
    public func retry(_ localId: String, for accountId: String) {
        // Before the guard: a file that has only ever been cut short mid-upload has an
        // interruption and no record, so a guard on the record would never reach this.
        clearInterruption(localId, for: accountId)
        guard let existing = records(for: accountId)[localId], !existing.isDone else { return }
        put(
            UploadRecord(
                localId: existing.localId,
                assetId: nil,
                uploadedAt: existing.uploadedAt,
                attempts: 0,
                lastError: nil,
                displayName: existing.displayName
            ),
            for: accountId
        )
    }

    /// Every failure for this account, back in the running. Anything already uploaded is
    /// left alone: clearing a done row would send the whole library up again.
    public func retryAll(for accountId: String) {
        for record in failures(for: accountId) {
            retry(record.localId, for: accountId)
        }
    }

    /// When this account was last brought up to date. Nil until a pass finishes one.
    public func lastCompleted(for accountId: String) -> Double? {
        let url = completedFile(for: accountId)
        guard let data = try? Data(contentsOf: url),
            let at = try? JSONDecoder().decode(Double.self, from: data)
        else { return nil }
        return at
    }

    /// How often a pass has been cut short while sending each file to this account.
    ///
    /// Beside the ledger rather than inside it, for the reason `completedFile` gives: the
    /// ledger's file is what must never be lost, and this is a hint about queue order that
    /// can be thrown away without costing anybody a photograph.
    public func interruptions(for accountId: String) -> [String: Int] {
        if let cached = loadedInterruptions[accountId] { return cached }
        let decoded = (try? Data(contentsOf: interruptionsFile(for: accountId)))
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }
            ?? [:]
        loadedInterruptions[accountId] = decoded
        return decoded
    }

    /// A pass was stopped part-way through this file. Deliberately not an attempt: being
    /// cut short is nobody's fault, and spending an attempt on it is what abandoned a
    /// large video after three overnight expiries. See `passOrder(_:deferring:)`.
    public func recordInterruption(_ localId: String, for accountId: String) {
        var current = interruptions(for: accountId)
        current[localId] = (current[localId] ?? 0) + 1
        writeInterruptions(current, for: accountId)
    }

    /// The file got through, or somebody asked for it to be tried properly. Either way it
    /// goes back to its place in the queue. Safe on a file that has none.
    public func clearInterruption(_ localId: String, for accountId: String) {
        var current = interruptions(for: accountId)
        guard current.removeValue(forKey: localId) != nil else { return }
        writeInterruptions(current, for: accountId)
    }

    /// Queue positions for files nothing will try again. Pruned rather than left, because
    /// this file is decoded in full at the start of every pass and a library that has given
    /// up on a few hundred assets would carry them for the life of the install.
    public func pruneInterruptions(settled: Set<String>, for accountId: String) {
        let current = interruptions(for: accountId)
        let kept = current.filter { !settled.contains($0.key) }
        guard kept.count != current.count else { return }
        writeInterruptions(kept, for: accountId)
    }

    public func recordCompleted(at moment: Double, for accountId: String) {
        guard let data = try? JSONEncoder().encode(moment) else { return }
        try? data.write(to: completedFile(for: accountId), options: .atomic)
    }

    public func uploadedCount(for accountId: String) -> Int {
        records(for: accountId).values.count(where: \.isDone)
    }

    public func forget(accountId: String) {
        loaded[accountId] = nil
        loadedInterruptions[accountId] = nil
        try? FileManager.default.removeItem(at: file(for: accountId))
        try? FileManager.default.removeItem(at: completedFile(for: accountId))
        try? FileManager.default.removeItem(at: interruptionsFile(for: accountId))
    }

    private func writeInterruptions(_ counts: [String: Int], for accountId: String) {
        loadedInterruptions[accountId] = counts
        guard let data = try? JSONEncoder().encode(counts) else { return }
        try? data.write(to: interruptionsFile(for: accountId), options: .atomic)
    }

    private func persist(_ accountId: String) {
        guard let records = loaded[accountId],
            let data = try? JSONEncoder().encode(records)
        else { return }
        try? data.write(to: file(for: accountId), options: .atomic)
    }

    private func file(for accountId: String) -> URL {
        directory.appendingPathComponent("uploads-\(accountId).json")
    }

    /// Beside the ledger rather than inside it: the ledger's file is a map of records and
    /// growing a second shape into it would mean migrating something that must never be
    /// lost, for the sake of one number.
    private func completedFile(for accountId: String) -> URL {
        directory.appendingPathComponent("completed-\(accountId).json")
    }

    private func interruptionsFile(for accountId: String) -> URL {
        directory.appendingPathComponent("interrupted-\(accountId).json")
    }
}

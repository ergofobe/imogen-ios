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

    public init(
        localId: String,
        assetId: String? = nil,
        uploadedAt: Double = Date().timeIntervalSince1970,
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.localId = localId
        self.assetId = assetId
        self.uploadedAt = uploadedAt
        self.attempts = attempts
        self.lastError = lastError
    }

    public var isDone: Bool { assetId != nil }
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

    /// Everything outstanding for one account, newest first.
    public func failures(for accountId: String) -> [UploadRecord] {
        records(for: accountId).values
            .filter { !$0.isDone }
            .sorted { $0.uploadedAt > $1.uploadedAt }
    }

    /// Puts one file back in the running.
    ///
    /// `settled` is computed from the attempt count, so zeroing it is what actually undoes
    /// the giving-up — anything less leaves the file skipped by every future pass. The
    /// reason goes with it rather than staying to describe a failure that is no longer the
    /// current answer.
    public func retry(_ localId: String, for accountId: String) {
        guard let existing = records(for: accountId)[localId], !existing.isDone else { return }
        put(
            UploadRecord(
                localId: existing.localId,
                assetId: nil,
                uploadedAt: existing.uploadedAt,
                attempts: 0,
                lastError: nil
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

    public func recordCompleted(at moment: Double, for accountId: String) {
        guard let data = try? JSONEncoder().encode(moment) else { return }
        try? data.write(to: completedFile(for: accountId), options: .atomic)
    }

    public func uploadedCount(for accountId: String) -> Int {
        records(for: accountId).values.count(where: \.isDone)
    }

    public func forget(accountId: String) {
        loaded[accountId] = nil
        try? FileManager.default.removeItem(at: file(for: accountId))
        try? FileManager.default.removeItem(at: completedFile(for: accountId))
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
}

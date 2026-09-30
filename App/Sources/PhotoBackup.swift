import BackgroundTasks
import Foundation
import ImogenKit
import ImogenSDK
import Observation
import Photos
import UIKit

/// How backup behaves, as opposed to where it goes — which account it copies to is a
/// property of the account, because it is chosen per account and there may be several.
@MainActor
@Observable
final class BackupSettings {
    /// Off until asked for. Uploading somebody's camera roll uninvited is not a default.
    var enabled: Bool { didSet { store("enabled", enabled) } }
    var wifiOnly: Bool { didSet { store("wifiOnly", wifiOnly) } }
    var includeVideos: Bool { didSet { store("includeVideos", includeVideos) } }
    /// Photographs this device took, rather than every image on it. Screenshots, saved
    /// pictures and things arriving from messaging apps are not what anybody means by
    /// "back up my photos".
    var cameraOnly: Bool { didSet { store("cameraOnly", cameraOnly) } }

    private let defaults = UserDefaults.standard

    init() {
        enabled = defaults.object(forKey: "backup.enabled") as? Bool ?? false
        wifiOnly = defaults.object(forKey: "backup.wifiOnly") as? Bool ?? true
        includeVideos = defaults.object(forKey: "backup.includeVideos") as? Bool ?? true
        cameraOnly = defaults.object(forKey: "backup.cameraOnly") as? Bool ?? true
    }

    private func store(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: "backup.\(key)")
    }
}

/// One destination, between passes.
struct RestingState: Equatable {
    var backedUp: Int
    var failures: Int
    var lastCompletedAt: Double?
}

/// Copying the camera roll to every account that asked for it.
///
/// One pass for all of them rather than one each: the expensive part is getting a
/// two-gigabyte video out of the photo library, and doing that once per destination
/// instead of once would make a second account cost twice as much battery as the first.
///
/// iOS does not let an app upload continuously in the background, and pretending otherwise
/// would mean promising something the system will not deliver. So a pass runs when the app
/// is in front, and `BGProcessingTask` asks the system for time when it is not — which the
/// system grants when it feels like it, usually overnight on a charger.
@MainActor
@Observable
final class PhotoBackup {
    static let shared = PhotoBackup()

    static let taskIdentifier = "com.imogen.ios.backup"

    private(set) var progress: BackupProgress?
    private(set) var lastError: String?
    /// What each destination holds and when it was last brought up to date. Read at rest,
    /// which is most of the time — a screen that goes blank between passes cannot tell a
    /// finished backup from a stalled one.
    private(set) var resting: [String: RestingState] = [:]

    private var running: Task<Void, Never>?
    private let ledger = UploadLedger(directory: URL.applicationSupportDirectory)

    private init() {}

    var isRunning: Bool { running != nil }

    /// Runs a pass unless one is already going.
    func runSoon(_ model: AppModel) {
        guard running == nil, model.backup.enabled else { return }
        running = Task {
            await run(model)
            running = nil
        }
    }

    func cancel() {
        running?.cancel()
        running = nil
        progress = nil
    }

    // MARK: - Background scheduling

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in
                self.handle(processing)
            }
        }
    }

    func scheduleBackgroundTask(_ model: AppModel) {
        guard model.backup.enabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        // Uploading a camera roll on battery is a way to hand somebody a flat phone.
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGProcessingTask) {
        guard let model = AppModelHolder.current else {
            return task.setTaskCompleted(success: false)
        }
        scheduleBackgroundTask(model)

        let work = Task { @MainActor in
            await run(model)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - The pass

    private func run(_ model: AppModel) async {
        lastError = nil
        let destinations = model.accounts.book.backingUpTo
        guard !destinations.isEmpty else {
            // Not an error, but not nothing either: the switch is on and no account was
            // chosen, which looks identical to working until somebody goes looking.
            lastError = "No account is set to receive your photographs."
            return
        }
        defer { Task { await self.refreshResting(destinations) } }

        guard await requestPhotoAccess() else {
            lastError = "imogen needs access to your photographs to back them up."
            return
        }

        let settings = model.backup
        let items = fetchLocalMedia(
            includeVideos: settings.includeVideos,
            cameraOnly: settings.cameraOnly
        )
        let assets = Dictionary(
            items.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first }
        )

        // The loop itself is in ImogenKit, where `swift test` can reach it. Everything
        // that only exists on a phone — PhotoKit, the network, the clock — arrives here.
        let outcome = await runBackupPass(
            items.map(\.localIdentifier),
            to: destinations,
            ledger: ledger,
            effects: BackupPassEffects(
                export: { localId in
                    guard let asset = assets[localId] else {
                        return .failure(ExportFailure.noSuchAsset)
                    }
                    return await self.export(asset)
                },
                dispose: { url in try? FileManager.default.removeItem(at: url) },
                upload: { file, localId, account in
                    await self.send(
                        file, localId, assets[localId], to: model.session(for: account)
                    )
                },
                report: { self.progress = $0 },
                isCancelled: { Task.isCancelled }
            )
        )
        lastError = outcome.message
    }

    /// Refreshed after a pass rather than polled: the numbers only move when one runs.
    func refreshResting(_ destinations: [Account]) async {
        var next: [String: RestingState] = [:]
        for account in destinations {
            next[account.id] = RestingState(
                backedUp: await ledger.uploadedCount(for: account.id),
                failures: await ledger.failures(for: account.id).count,
                lastCompletedAt: await ledger.lastCompleted(for: account.id)
            )
        }
        resting = next
    }

    /// One file to one destination, reduced to the remote asset id or the reason not.
    /// What that reason costs is `uploadDisposition(of:)`'s to say, not this method's.
    private func send(
        _ file: URL, _ localId: String, _ asset: PHAsset?, to session: Session
    ) async -> Result<String, Error> {
        // HTTPClient.send throws the same 401 when refresh returned nil and when
        // it returned a token but did not replay the multipart body. A changed
        // access token is the only fact on this side of that call.
        let before = await session.accessToken()
        do {
            let result = try await session.client.assets.upload(
                file,
                options: UploadOptions(
                    metadata: AssetUploadMetadata(
                        deviceAssetId: localId,
                        capturedAt: isoInstant(asset?.creationDate ?? Date()),
                        filename: file.lastPathComponent
                    )
                )
            )
            return .success(result.asset.id)
        } catch {
            if let imogen = error as? ImogenError, imogen.status == 401 {
                let after = await session.accessToken()
                if let after, after != before {
                    return .failure(
                        ImogenError(
                            status: 401,
                            code: refreshedNotReplayed,
                            message: imogen.message,
                            details: imogen.details
                        )
                    )
                }
            }
            return .failure(error)
        }
    }

    /// Everything outstanding, across every destination.
    func failures(_ model: AppModel) async -> [UploadFailure] {
        await ledger.failures(for: model.accounts.book.backingUpTo)
    }

    func retry(_ localId: String, for accountId: String, model: AppModel) async {
        await ledger.retry(localId, for: accountId)
        await refreshResting(model.accounts.book.backingUpTo)
        runSoon(model)
    }

    func retryAll(_ model: AppModel) async {
        for account in model.accounts.book.backingUpTo {
            await ledger.retryAll(for: account.id)
        }
        await refreshResting(model.accounts.book.backingUpTo)
        runSoon(model)
    }

    // MARK: - The photo library

    private func requestPhotoAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }
        if status == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return granted == .authorized || granted == .limited
        }
        return false
    }

    /// Oldest first. A backup that starts today and works backwards leaves somebody
    /// watching the count go up with no idea whether it will ever reach the bottom.
    private func fetchLocalMedia(includeVideos: Bool, cameraOnly: Bool) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = includeVideos
            ? NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        // The camera roll is a smart album, so "what this device photographed" is a
        // question PhotoKit already answers — no guessing from folder names.
        let collection = cameraOnly
            ? PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil
            ).firstObject
            : nil

        let result = collection.map { PHAsset.fetchAssets(in: $0, options: options) }
            ?? PHAsset.fetchAssets(with: options)

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// The original bytes, written somewhere the uploader can open them.
    ///
    /// `PHAssetResourceManager` rather than a request for image data: it hands over the
    /// file the camera wrote, EXIF and all, rather than something re-encoded on the way
    /// out. A photograph that arrives on the server without its capture date is a
    /// photograph in the wrong place in the timeline for ever.
    /// Remembers the request `requestData` returns. A cancellation can arrive before
    /// that identifier does, and the download still has to be stopped.
    private final class ExportTransfer: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHAssetResourceDataRequestID?
        private var cancelRequested = false
        private var handle: FileHandle?
        private var writeError: Error?
        private var resumed = false

        func store(_ handle: FileHandle) {
            lock.lock()
            self.handle = handle
            lock.unlock()
        }

        func arm(_ id: PHAssetResourceDataRequestID) -> PHAssetResourceDataRequestID? {
            lock.lock()
            requestID = id
            let cancel = cancelRequested
            lock.unlock()
            return cancel ? id : nil
        }

        func cancel() -> PHAssetResourceDataRequestID? {
            lock.lock()
            cancelRequested = true
            let id = requestID
            lock.unlock()
            return id
        }

        func receive(_ data: Data) {
            var cancelID: PHAssetResourceDataRequestID?
            lock.lock()
            if let handle {
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    if writeError == nil { writeError = error }
                    cancelID = requestID
                }
            }
            lock.unlock()
            if let cancelID {
                PHAssetResourceManager.default().cancelDataRequest(cancelID)
            }
        }

        func finish(_ error: Error?) -> (resume: Bool, failure: Error?) {
            lock.lock()
            let failure = writeError ?? error
            let handle = self.handle
            self.handle = nil
            let resume = !resumed
            resumed = true
            lock.unlock()
            try? handle?.close()
            return (resume, failure)
        }
    }

    private func export(_ asset: PHAsset) async -> Result<URL, Error> {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = [
            .photo, .video, .fullSizePhoto, .fullSizeVideo,
        ]
        guard let resource = preferred.compactMap({ type in
            resources.first { $0.type == type }
        }).first else { return .failure(ExportFailure.noUsableResource) }

        let target = URL.temporaryDirectory
            .appending(path: "imogen-upload")
            .appending(path: resource.originalFilename)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: target)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        // The reason is kept rather than collapsed to nil: `isNetworkAccessAllowed` means
        // this can be a download from iCloud, so it fails for network reasons and for an
        // expiring background window as readily as for a broken file, and only
        // `uploadDisposition(of:)` may decide which of those costs the file anything.
        // `writeData` returns no request identifier, so a Stop or an expiring window
        // cannot interrupt a multi-gigabyte iCloud download. These are the same bytes.
        let transfer = ExportTransfer()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                FileManager.default.createFile(atPath: target.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: target) else {
                    continuation.resume(returning: .failure(CocoaError(.fileWriteUnknown)))
                    return
                }
                transfer.store(handle)
                let id = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { transfer.receive($0) },
                    completionHandler: { error in
                        let finished = transfer.finish(error)
                        guard finished.resume else { return }
                        if let failure = finished.failure {
                            // A part-written export is bytes nothing will ever sweep up,
                            // and a file that is no longer given up on after three tries
                            // is one that would leave a fresh partial video in tmp on
                            // every pass.
                            try? FileManager.default.removeItem(at: target)
                            continuation.resume(returning: .failure(failure))
                        } else {
                            continuation.resume(returning: .success(target))
                        }
                    }
                )
                if let id = transfer.arm(id) {
                    PHAssetResourceManager.default().cancelDataRequest(id)
                }
            }
        }, onCancel: {
            if let id = transfer.cancel() {
                PHAssetResourceManager.default().cancelDataRequest(id)
            }
        })
    }
}

/// The background task handler is registered before any view exists and is handed a bare
/// identifier, so it needs somewhere to find the model. One reference, set at launch.
@MainActor
enum AppModelHolder {
    static var current: AppModel?
}

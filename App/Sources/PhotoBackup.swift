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

struct BackupProgress: Equatable {
    var completed: Int
    var total: Int
    var filename: String?
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
        guard !destinations.isEmpty else { return }

        guard await requestPhotoAccess() else {
            lastError = "imogen needs access to your photographs to back them up."
            return
        }

        let settings = model.backup
        let items = fetchLocalMedia(
            includeVideos: settings.includeVideos,
            cameraOnly: settings.cameraOnly
        )
        guard !items.isEmpty else { return }

        var outstanding: [String: Set<String>] = [:]
        for account in destinations {
            outstanding[account.id] = await ledger.settled(for: account.id)
        }

        let total = destinations.reduce(0) { running, account in
            running + items.filter { !(outstanding[account.id]?.contains($0.localIdentifier) ?? false) }.count
        }
        guard total > 0 else { return }

        var completed = 0
        progress = BackupProgress(completed: 0, total: total, filename: nil)
        defer { progress = nil }

        for item in items {
            if Task.isCancelled { return }

            // Fetched once, sent to each destination. This is the expensive step.
            var file: URL?
            for account in destinations {
                if outstanding[account.id]?.contains(item.localIdentifier) == true { continue }

                if file == nil {
                    file = await export(item)
                    guard file != nil else { break }
                }
                guard let file else { break }

                progress = BackupProgress(
                    completed: completed,
                    total: total,
                    filename: file.lastPathComponent
                )

                let outcome = await upload(file, item, to: model.session(for: account), account)
                completed += 1
                if outcome == .unavailable {
                    // The server or the network is having a bad day. Stop pushing at it;
                    // the next pass will pick up where this one left off.
                    try? FileManager.default.removeItem(at: file)
                    return
                }
            }
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

    private enum Outcome { case uploaded, rejected, unavailable }

    private func upload(
        _ file: URL, _ item: PHAsset, to session: Session, _ account: Account
    ) async -> Outcome {
        let localId = item.localIdentifier
        do {
            let result = try await session.client.assets.upload(
                file,
                options: UploadOptions(
                    metadata: AssetUploadMetadata(
                        deviceAssetId: localId,
                        capturedAt: isoInstant(item.creationDate ?? Date()),
                        filename: file.lastPathComponent
                    )
                )
            )
            await ledger.put(
                UploadRecord(localId: localId, assetId: result.asset.id),
                for: account.id
            )
            return .uploaded
        } catch let error as ImogenError {
            // A rejection the server will keep making — a file type it will not take, a
            // quota that is full — is recorded against this file. Anything transient is
            // the server's problem, not this file's, and must not spend its attempts.
            if error.isRetryable || error.status == 0 { return .unavailable }
            await recordFailure(localId, account.id, error.message)
            return .rejected
        } catch {
            await recordFailure(localId, account.id, error.localizedDescription)
            return .unavailable
        }
    }

    private func recordFailure(_ localId: String, _ accountId: String, _ message: String) async {
        let attempts = await ledger.attempts(localId, for: accountId)
        await ledger.put(
            UploadRecord(localId: localId, attempts: attempts + 1, lastError: message),
            for: accountId
        )
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
    private func export(_ asset: PHAsset) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = [
            .photo, .video, .fullSizePhoto, .fullSizeVideo,
        ]
        guard let resource = preferred.compactMap({ type in
            resources.first { $0.type == type }
        }).first else { return nil }

        let target = URL.temporaryDirectory
            .appending(path: "imogen-upload")
            .appending(path: resource.originalFilename)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: target)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: target, options: options
            ) { error in
                continuation.resume(returning: error == nil ? target : nil)
            }
        }
    }
}

/// The background task handler is registered before any view exists and is handed a bare
/// identifier, so it needs somewhere to find the model. One reference, set at launch.
@MainActor
enum AppModelHolder {
    static var current: AppModel?
}

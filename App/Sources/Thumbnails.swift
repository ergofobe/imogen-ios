import ImogenKit
import ImogenSDK
import SwiftUI

/// Images from the server, cached.
///
/// `AsyncImage` cannot do this: the media routes are ordinary API routes and want a bearer
/// token, and `AsyncImage` has nowhere to put a header. So this is the same idea with an
/// authenticated fetch underneath and a cache that outlives a scroll.
///
/// Two caches. The memory one is what makes scrolling back up instant; the disk one is
/// what makes opening the app instant, and matters far more on a library reached over a
/// domestic uplink than on one reached over a LAN.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    /// Requests already in flight, so a grid that composes the same cell twice while
    /// scrolling fetches it once.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        directory = URL.cachesDirectory.appending(path: "thumbnails")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Counted in pixels rather than in images: a preview is a hundred times the size
        // of a thumbnail, and a limit in items would mean either too few of one or far too
        // many of the other.
        memory.totalCostLimit = 256 * 1024 * 1024
    }

    func image(for url: URL, key: String, session: Session) async -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> { [directory] in
            let file = directory.appending(path: Self.filename(for: key))

            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                return image
            }
            guard let data = try? await session.data(from: url),
                let image = UIImage(data: data)
            else { return nil }

            try? data.write(to: file, options: .atomic)
            return image
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            memory.setObject(image, forKey: key as NSString, cost: image.approximateBytes)
        }
        return image
    }

    /// Signing out takes the photographs with it. Leaving them in a cache directory would
    /// mean an account that is gone from the app is still legible on the disk.
    func forget(accountId: String) {
        memory.removeAllObjects()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let prefix = Self.filename(for: accountId)
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Cache keys carry an account id and an asset id, and neither is safe in a path.
    private static func filename(for key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

extension UIImage {
    var approximateBytes: Int {
        Int(size.width * size.height * scale * scale * 4)
    }
}

/// One photograph, with its own dominant colour underneath it until it arrives.
///
/// The placeholder is the asset's own colour, which the server computed when it made the
/// thumbnail. A grid of grey rectangles resolving into photographs looks like a page
/// failing to load; a grid of the right colours looks like the photographs arriving.
struct AssetImage: View {
    let session: Session
    let asset: Asset
    var variant: String = "thumbnail"
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                placeholder
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: cacheKey) { await load() }
    }

    private var placeholder: some View {
        (asset.placeholderColor.flatMap(Color.init(hex:)) ?? Color.secondary.opacity(0.2))
            .ignoresSafeArea(edges: [])
    }

    // Two accounts can hold the same asset id. Without the account in the key the cache
    // would answer one server's request with the other's photograph.
    private var cacheKey: String { "\(session.accountId):\(asset.id):\(variant)" }

    private func load() async {
        guard let url = session.assetURL(asset.id, variant: variant) else { return }
        let loaded = await ThumbnailCache.shared.image(for: url, key: cacheKey, session: session)
        withAnimation(.easeOut(duration: 0.15)) { image = loaded }
    }
}

extension Color {
    /// `#rrggbb`, which is what the server sends. Anything else is not a colour.
    init?(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

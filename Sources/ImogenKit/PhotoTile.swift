import Foundation
import ImogenSDK

/// What a grid cell and the pager actually read.
///
/// The timeline is drawn from `TimelineTile`, which is the server's answer to "what does a
/// square need" — around 200 bytes against an `Asset`'s 800, and none of the checksum, exif
/// or filename that a square never shows. The bounded feeds are still drawn from `Asset`,
/// because they already have one.
///
/// So the cell and the pager are written against the smaller of the two, and an `Asset`
/// satisfies it by having more than is asked for.
public protocol PhotoTile: Identifiable, Sendable {
    var id: String { get }
    var capturedAt: String { get }
    var type: AssetType { get }
    var favorite: Bool { get }
    var placeholderColor: String? { get }
    /// What VoiceOver reads. A tile has no filename to fall back on, so it says what it is.
    var spokenLabel: String { get }
}

extension TimelineTile: PhotoTile {
    public var spokenLabel: String { type == .video ? "Video" : "Photograph" }
}

extension Asset: PhotoTile {
    public var spokenLabel: String { description ?? originalFilename }
}

/// The day a photograph belongs to, which is the key its grid section is filed under.
///
/// The server's buckets are UTC days and `capturedAt` is an ISO-8601 instant, so the first
/// ten characters are the bucket. Parsing it into a `Date` and formatting it back would
/// shift every heading by a day for anybody west of Greenwich.
public func dayKey(of tile: some PhotoTile) -> String {
    String(tile.capturedAt.prefix(10))
}

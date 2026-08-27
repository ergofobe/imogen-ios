import Foundation
import ImogenSDK

/// The shape of the whole library, without any of it loaded.
///
/// A library of fifty thousand photographs cannot be paged into a grid a hundred at a
/// time and still be scrollable: reaching 2011 means four hundred round trips, and the
/// scrollbar lies about how much there is until the last one lands.
///
/// The server already answers a cheaper question. `/assets/timeline` returns one row per
/// day with a count — a few thousand rows for a lifetime of photographs, one request, no
/// images. From that the exact number of cells is known before anything is fetched, which
/// is what makes the grid the right length from the first frame and makes jumping to a
/// date arithmetic rather than a search.
///
/// Sections are laid out as one per day, so `SwiftUI`'s grid can pin the headers itself;
/// what this owns is the arithmetic that turns a scrubber position into a day and back.
public struct TimelineIndex: Equatable, Sendable {
    public let buckets: [TimelineBucket]

    /// `starts[b]` is the cell index of the first photograph in day `b`; one extra entry
    /// holds the total, so the count of any day is a subtraction.
    private let starts: [Int]

    public init(buckets: [TimelineBucket]) {
        self.buckets = buckets
        var running = 0
        var starts: [Int] = []
        starts.reserveCapacity(buckets.count + 1)
        for bucket in buckets {
            starts.append(running)
            running += bucket.count
        }
        starts.append(running)
        self.starts = starts
    }

    public var isEmpty: Bool { buckets.isEmpty }

    /// Every photograph in the library, known without fetching one.
    public var photoCount: Int { starts.last ?? 0 }

    public var dayCount: Int { buckets.count }

    public func date(ofDay day: Int) -> String {
        buckets[day.clamped(to: 0...(buckets.count - 1))].date
    }

    public func count(ofDay day: Int) -> Int {
        buckets[day.clamped(to: 0...(buckets.count - 1))].count
    }

    public func firstPhoto(ofDay day: Int) -> Int {
        starts[day.clamped(to: 0...(buckets.count - 1))]
    }

    /// Which day a photograph position belongs to.
    public func day(ofPhoto photo: Int) -> Int {
        guard !buckets.isEmpty else { return 0 }
        var low = 0
        var high = buckets.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= photo { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The day a fraction of the way down, for a scrubber.
    ///
    /// Weighted by photographs rather than by days, so dragging halfway down lands halfway
    /// through the library — not halfway through the list of dates, which on a library with
    /// one holiday and ten years of Tuesdays is somewhere quite different.
    public func day(atFraction fraction: Double) -> Int {
        guard photoCount > 0 else { return 0 }
        let photo = Int(Double(photoCount) * min(max(fraction, 0), 1))
        return day(ofPhoto: min(photo, photoCount - 1))
    }

    /// How far down a day sits, for drawing the thumb at rest.
    public func fraction(ofDay day: Int) -> Double {
        guard photoCount > 0 else { return 0 }
        return Double(firstPhoto(ofDay: day)) / Double(photoCount)
    }

    /// Removes photographs from days, and days that empty.
    ///
    /// Trashing something has to shorten the grid immediately. Refetching the buckets would
    /// be a round trip in the middle of a gesture, and would put the scroll position
    /// somewhere else while somebody was looking at it.
    public func removing(_ counts: [String: Int]) -> TimelineIndex {
        guard !counts.isEmpty else { return self }
        let updated = buckets.compactMap { bucket -> TimelineBucket? in
            guard let removed = counts[bucket.date] else { return bucket }
            let remaining = bucket.count - removed
            return remaining > 0 ? TimelineBucket(date: bucket.date, count: remaining) : nil
        }
        return TimelineIndex(buckets: updated)
    }
}

/// The instants bounding one UTC day, as the API wants them.
public func dayBounds(_ date: String) -> (after: String, before: String) {
    ("\(date)T00:00:00.000Z", "\(date)T23:59:59.999Z")
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        // An empty library gives an inverted range; there is nothing to clamp into, and
        // the caller has already guarded against using the answer.
        guard range.lowerBound <= range.upperBound else { return range.lowerBound }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

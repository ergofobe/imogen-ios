import Foundation

/// What the grid is drawn with. Enough to estimate a day's height without measuring it.
public struct TimelineMetrics: Equatable, Sendable {
    public var columns: Int
    /// One row of cells, including the gap under it.
    public var rowHeight: Double
    /// A day heading, including its padding.
    public var headerHeight: Double
    /// How much of the timeline is on screen, so the thumb can reach the bottom.
    public var viewportHeight: Double

    public init(columns: Int, rowHeight: Double, headerHeight: Double, viewportHeight: Double) {
        self.columns = max(columns, 1)
        self.rowHeight = max(rowHeight, 1)
        self.headerHeight = max(headerHeight, 0)
        self.viewportHeight = max(viewportHeight, 0)
    }
}

public struct YearMark: Equatable, Sendable {
    public let year: Int
    /// Where the year begins, as a fraction of the scrollable extent.
    public let fraction: Double
}

/// Where every day sits, in pixels, before a single photograph is fetched.
///
/// A scrubber that maps its thumb from a photograph's *position in the list* is a
/// scrubber that jumps: a day holding one photograph and a day holding twenty-five are
/// two list entries apart at the top of each, but nine rows apart on screen. Dragging
/// feels like the timeline is fighting back, because it is — the thumb and the content
/// are measuring different things.
///
/// So this measures the same thing the grid does. Each day is a heading plus however many
/// rows its count needs, which is exact for a loaded day and a good estimate for one that
/// has not arrived — good enough that the extent is right from the first frame and does
/// not lurch as days load.
///
/// This is the mobile half of the segment table in the timeline scrubbing design; the web
/// grid computes the same thing and replaces the estimate with a measured height once
/// `justify()` has run. There is nothing to replace here: the grid is uniform squares, so
/// the estimate *is* the measurement.
public struct TimelineLayout: Equatable, Sendable {
    public let index: TimelineIndex
    public let metrics: TimelineMetrics

    /// The top edge of each day. One extra entry holds the total height.
    private let tops: [Double]

    public init(index: TimelineIndex, metrics: TimelineMetrics) {
        self.index = index
        self.metrics = metrics

        var running = 0.0
        var tops: [Double] = []
        tops.reserveCapacity(index.dayCount + 1)
        for day in 0..<index.dayCount {
            tops.append(running)
            let rows = (index.count(ofDay: day) + metrics.columns - 1) / metrics.columns
            running += metrics.headerHeight + Double(rows) * metrics.rowHeight
        }
        tops.append(running)
        self.tops = tops
    }

    public var totalHeight: Double { tops.last ?? 0 }

    /// How far the content can actually scroll. The last screenful is not scrolled past,
    /// so a thumb driven by `totalHeight` alone stops short of the bottom.
    public var scrollableHeight: Double {
        max(totalHeight - metrics.viewportHeight, 1)
    }

    public func top(ofDay day: Int) -> Double {
        guard index.dayCount > 0 else { return 0 }
        return tops[day.clamped(to: 0...(index.dayCount - 1))]
    }

    public func height(ofDay day: Int) -> Double {
        guard index.dayCount > 0 else { return 0 }
        let position = day.clamped(to: 0...(index.dayCount - 1))
        return tops[position + 1] - tops[position]
    }

    public func day(atOffset offset: Double) -> Int {
        guard index.dayCount > 0 else { return 0 }
        var low = 0
        var high = index.dayCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if tops[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Where a day sits on the rail.
    public func fraction(ofDay day: Int) -> Double {
        guard index.dayCount > 0 else { return 0 }
        return min(max(top(ofDay: day) / scrollableHeight, 0), 1)
    }

    /// What the rail is pointing at.
    public func day(atFraction fraction: Double) -> Int {
        guard index.dayCount > 0 else { return 0 }
        return day(atOffset: min(max(fraction, 0), 1) * scrollableHeight)
    }

    /// Where each year starts, for labelling the rail.
    ///
    /// Proportional to height rather than to time, which is the point: a year of nine
    /// thousand photographs takes more rail than a year of two hundred, so the labels sit
    /// where that year's photographs actually are.
    public func yearMarks() -> [YearMark] {
        var marks: [YearMark] = []
        var seen: Int?
        for day in 0..<index.dayCount {
            guard let year = Int(index.date(ofDay: day).prefix(4)) else { continue }
            if year != seen {
                marks.append(YearMark(year: year, fraction: fraction(ofDay: day)))
                seen = year
            }
        }
        return marks
    }

    /// Year marks thinned so their labels do not overlap on a rail this tall.
    ///
    /// A twenty-year library has twenty labels and a phone has room for about eight, so
    /// the rest are dropped rather than drawn on top of each other. The first is always
    /// kept, because a rail whose top is unlabelled reads as broken.
    public func yearMarks(spacedBy minimumGap: Double, railHeight: Double) -> [YearMark] {
        let all = yearMarks()
        guard railHeight > 0, minimumGap > 0 else { return all }

        var kept: [YearMark] = []
        var lastPosition = -Double.infinity
        for mark in all {
            let position = mark.fraction * railHeight
            if position - lastPosition >= minimumGap {
                kept.append(mark)
                lastPosition = position
            }
        }
        return kept
    }
}

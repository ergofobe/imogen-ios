import Foundation

/// A drag on the timeline scrubber's thumb, from the moment a finger takes hold of it
/// until the finger lifts or the gesture is taken away.
///
/// This is here rather than in the view because both of the ways it went wrong were
/// decisions rather than drawing, and a decision in `App/Sources` is a decision no test
/// can reach.
///
/// The first was seeking on every `DragGesture` value. The grid is a `LazyVGrid` with a
/// section per day, and moving it means `ScrollViewProxy.scrollTo(day)`, which has to lay
/// out every section between here and the target before it knows where the target is. Run
/// once per pointer move across a decade, that is thousands of layout passes to answer a
/// question nobody asked: the thumb had not even changed day. So the rail follows the
/// finger and reports only what changed, and the grid is moved once, by `finish()`, when
/// the finger lifts. The bubble and the year marks are what say where the thumb is before
/// letting go — which is the whole reason the control exists.
///
/// The second was assuming a drag ends. SwiftUI cancels gestures — a system edge swipe, a
/// call, the app going to the background — and `onEnded` simply never arrives. The
/// timeline suspends fetching while `isActive`, so a drag that is never ended is a
/// timeline that never loads another day. `cancel()` is the way out, and the view drives
/// it from `@GestureState`, which SwiftUI resets on a cancellation as well as on an end.
public struct ScrubDrag: Equatable, Sendable {
    /// A day the thumb has newly arrived on.
    public struct Landing: Equatable, Sendable {
        public let day: Int
        /// Whether that crossed into a different month, which is when the rail buzzes.
        /// One tick per day would buzz continuously across a decade.
        public let crossedMonth: Bool
    }

    /// The day under the thumb.
    public private(set) var day: Int
    /// Where the thumb is on the rail, from 0 at the top to 1 at the bottom.
    public private(set) var fraction: Double
    /// False once the drag has been finished or cancelled. The timeline fetches nothing
    /// while it is true.
    public private(set) var isActive = true

    /// Where the thumb was when the finger took hold of it. The drag is measured from
    /// there, so the thumb moves with the finger rather than snapping under it on touch.
    private let startFraction: Double
    /// The day the grid was already showing when the finger took hold. A drag that ends
    /// on it has nothing to ask for — see `finish()`.
    private let startDay: Int

    public init(fromDay day: Int, in layout: TimelineLayout) {
        self.day = day
        self.startDay = day
        self.startFraction = layout.fraction(ofDay: day)
        self.fraction = startFraction
    }

    /// Follows the finger.
    ///
    /// `translation` is the drag's total offset from where it began, not the step since
    /// the last value: a thumb that moves under the finger cannot disturb it, where a
    /// position in the thumb's own space would chase itself.
    ///
    /// Returns the day only when the thumb has arrived on a new one, so a slow drag
    /// within a single day reports nothing at all.
    @discardableResult
    public mutating func move(
        by translation: Double, over travel: Double, in layout: TimelineLayout
    ) -> Landing? {
        guard isActive else { return nil }
        fraction = min(max(startFraction + translation / max(travel, 1), 0), 1)

        let landing = layout.day(atFraction: fraction)
        guard landing != day else { return nil }

        // Against the day just left, not against the grid's day: the grid no longer
        // moves during a drag, so comparing with it would call every day after the first
        // month boundary a month change.
        let was = layout.index.date(ofDay: day)
        day = landing
        return Landing(
            day: landing,
            crossedMonth: month(of: layout.index.date(ofDay: landing)) != month(of: was)
        )
    }

    /// Ends the drag, and answers with the day the grid should be moved to — or nothing,
    /// when it is already showing it.
    ///
    /// Compared by day rather than by distance dragged, which spares the arbitrary
    /// threshold a distance would need: `DragGesture(minimumDistance: 0)` reports a value
    /// as soon as a finger lands and keeps reporting them a fraction of a point apart
    /// while it rests there, and treating those as a drag snapped the grid to the top of
    /// a day it was already halfway through — from a touch that went nowhere.
    public mutating func finish() -> Int? {
        guard isActive else { return nil }
        isActive = false
        return day == startDay ? nil : day
    }

    /// Ends a drag that was taken away rather than let go of. Nothing is sought: there is
    /// no destination to honour, only a flag that has to stop guarding the timeline.
    public mutating func cancel() {
        isActive = false
    }

    /// The ISO day's month, compared as text. `monthHeading` would do, but it is a
    /// `DateFormatter` and this is asked on the way past every day of a fifteen-year drag.
    private func month(of date: String) -> Substring { date.prefix(7) }
}

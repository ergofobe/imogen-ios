import ImogenSDK
import XCTest

@testable import ImogenKit

final class ScrubDragTests: XCTestCase {

    private let metrics = TimelineMetrics(
        columns: 3, rowHeight: 100, headerHeight: 40, viewportHeight: 0
    )

    /// Three days in January and three in February, each one row tall, so every day is
    /// an equal slice of the rail and a translation can be aimed at one exactly.
    private func layout(_ buckets: [(String, Int)]) -> TimelineLayout {
        TimelineLayout(
            index: TimelineIndex(
                buckets: buckets.map { TimelineBucket(date: $0.0, count: $0.1) }
            ),
            metrics: metrics
        )
    }

    private var months: TimelineLayout {
        layout([
            ("2026-02-03", 1), ("2026-02-02", 1), ("2026-02-01", 1),
            ("2026-01-03", 1), ("2026-01-02", 1), ("2026-01-01", 1),
        ])
    }

    // MARK: - Seeking only when it means something (#27)

    /// The bug. `update(to:)` sought on every `DragGesture.onChanged`, so a slow drag
    /// within a single day asked the grid to scroll to the day it was already on, dozens
    /// of times a second.
    func testStayingOnOneDayLandsOnce() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        let travel = 600.0
        // A sixth of the rail is one day, so 100pt is the width of a day. Creep across
        // the first one without leaving it.
        XCTAssertNil(drag.move(by: 10, over: travel, in: months))
        XCTAssertNil(drag.move(by: 20, over: travel, in: months))
        XCTAssertNil(drag.move(by: 30, over: travel, in: months))
        XCTAssertEqual(drag.day, 0)
    }

    func testADayIsReportedOnlyAsItIsCrossed() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        let travel = 600.0

        XCTAssertEqual(drag.move(by: 110, over: travel, in: months)?.day, 1)
        // Still day 1: nothing to report, however many events arrive.
        XCTAssertNil(drag.move(by: 120, over: travel, in: months))
        XCTAssertNil(drag.move(by: 130, over: travel, in: months))
        XCTAssertEqual(drag.move(by: 210, over: travel, in: months)?.day, 2)
        XCTAssertEqual(drag.day, 2)
    }

    func testDraggingBackReportsTheDayAgain() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        let travel = 600.0

        XCTAssertEqual(drag.move(by: 110, over: travel, in: months)?.day, 1)
        XCTAssertEqual(drag.move(by: 10, over: travel, in: months)?.day, 0)
    }

    // MARK: - The haptic

    /// One tick per day crossed would buzz continuously across a decade.
    func testTheRailBuzzesWhenTheMonthChangesAndNotWhenTheDayDoes() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        let travel = 600.0

        // 2026-02-03 -> 2026-02-02: a new day in the same month.
        XCTAssertEqual(drag.move(by: 110, over: travel, in: months)?.crossedMonth, false)
        // ...-02-01 -> ...-01-03: a new month.
        XCTAssertEqual(drag.move(by: 310, over: travel, in: months)?.crossedMonth, true)
        XCTAssertEqual(drag.move(by: 410, over: travel, in: months)?.crossedMonth, false)
    }

    /// The month is compared against the day the drag was last on, not against the day
    /// the grid is showing: the grid no longer moves during a drag, so comparing with it
    /// would buzz on every day crossed after the first month boundary.
    func testTheMonthIsComparedWithThePreviousLandingNotTheStart() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        let travel = 600.0

        XCTAssertEqual(drag.move(by: 310, over: travel, in: months)?.crossedMonth, true)
        // Two more days into January. The drag started in February, so a comparison
        // against the starting day would call each of these a month change.
        XCTAssertEqual(drag.move(by: 410, over: travel, in: months)?.crossedMonth, false)
        XCTAssertEqual(drag.move(by: 510, over: travel, in: months)?.crossedMonth, false)
    }

    // MARK: - The ends of the rail

    func testTheThumbStopsAtBothEnds() {
        var drag = ScrubDrag(fromDay: 3, in: months)
        let travel = 600.0

        drag.move(by: -5000, over: travel, in: months)
        XCTAssertEqual(drag.fraction, 0)
        XCTAssertEqual(drag.day, 0)

        drag.move(by: 5000, over: travel, in: months)
        XCTAssertEqual(drag.fraction, 1)
        XCTAssertEqual(drag.day, 5)
    }

    /// The thumb is taken hold of where it is rather than snapped under the finger, so a
    /// drag that starts halfway down the rail measures from halfway down.
    func testTheDragIsMeasuredFromWhereTheThumbWas() {
        var drag = ScrubDrag(fromDay: 3, in: months)
        XCTAssertEqual(drag.fraction, months.fraction(ofDay: 3), accuracy: 0.0001)

        drag.move(by: 0, over: 600, in: months)
        XCTAssertEqual(drag.day, 3)
    }

    // MARK: - Ending, and being taken away (#25)

    /// A touch that takes hold and lets go must leave the grid exactly where it was.
    func testATouchThatNeverMovedSeeksNothing() {
        var drag = ScrubDrag(fromDay: 2, in: months)
        XCTAssertNil(drag.finish())
    }

    /// `DragGesture(minimumDistance: 0)` reports a value the moment a finger lands, and a
    /// finger resting on glass goes on producing them a fraction of a point apart. None of
    /// those is a drag, and the grid — which is already showing this day — must not snap
    /// its heading to the top of the screen because somebody touched the thumb.
    func testADragThatEndsOnTheDayItStartedOnSeeksNothing() {
        var drag = ScrubDrag(fromDay: 2, in: months)
        drag.move(by: 0.4, over: 600, in: months)
        XCTAssertNil(drag.finish())
    }

    /// And a drag that wanders off and comes back is the same. The grid is only moved on
    /// release, so it is still exactly where it was.
    func testADragThatReturnsToWhereItStartedSeeksNothing() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        drag.move(by: 310, over: 600, in: months)
        drag.move(by: 0, over: 600, in: months)

        XCTAssertEqual(drag.day, 0)
        XCTAssertNil(drag.finish())
    }

    func testAFinishedDragSeeksTheDayUnderTheThumb() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        drag.move(by: 210, over: 600, in: months)
        XCTAssertEqual(drag.finish(), 2)
    }

    /// The grid is moved once, when the finger lifts — not on every pointer move. A
    /// finished drag is therefore inert, and a second `finish()` cannot seek again.
    func testAFinishedDragIsOver() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        drag.move(by: 210, over: 600, in: months)

        XCTAssertEqual(drag.finish(), 2)
        XCTAssertFalse(drag.isActive)
        XCTAssertNil(drag.finish())
    }

    /// #25. When SwiftUI cancels the gesture — a system edge swipe, a call, the app going
    /// to the background — `onEnded` never arrives. The drag has to end anyway, or the
    /// timeline stays in scrubbing mode and `TimelineStore.load(around:)` refuses to
    /// fetch anything for the rest of the session.
    func testACancelledDragStopsScrubbing() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        drag.move(by: 210, over: 600, in: months)
        XCTAssertTrue(drag.isActive)

        drag.cancel()
        XCTAssertFalse(drag.isActive)
    }

    /// And it seeks nothing: the finger was taken away rather than lifted, so there is no
    /// destination to honour.
    func testACancelledDragSeeksNothing() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        drag.move(by: 210, over: 600, in: months)
        drag.cancel()

        XCTAssertNil(drag.finish())
    }

    /// A cancelled drag also stops following the finger. SwiftUI delivers no more values
    /// after a cancellation, but the flag is what guards the rest of the session.
    func testACancelledDragIgnoresFurtherMovement() {
        var drag = ScrubDrag(fromDay: 0, in: months)
        drag.cancel()

        XCTAssertNil(drag.move(by: 210, over: 600, in: months))
        XCTAssertEqual(drag.day, 0)
    }
}

import ImogenSDK
import XCTest

@testable import ImogenKit

final class TimelineLayoutTests: XCTestCase {

    private let metrics = TimelineMetrics(
        columns: 3, rowHeight: 100, headerHeight: 40, viewportHeight: 0
    )

    private func layout(_ buckets: [(String, Int)]) -> TimelineLayout {
        TimelineLayout(
            index: TimelineIndex(
                buckets: buckets.map { TimelineBucket(date: $0.0, count: $0.1) }
            ),
            metrics: metrics
        )
    }

    func testADayIsAHeadingPlusHoweverManyRowsItsCountNeeds() {
        // 3 columns: 1 photo is one row, 3 is one row, 4 is two.
        let one = layout([("2026-08-27", 1)])
        XCTAssertEqual(one.totalHeight, 40 + 100)

        let three = layout([("2026-08-27", 3)])
        XCTAssertEqual(three.totalHeight, 40 + 100)

        let four = layout([("2026-08-27", 4)])
        XCTAssertEqual(four.totalHeight, 40 + 200)
    }

    func testDaysStackAndTopsAreMonotonic() {
        let stacked = layout([("2026-08-27", 3), ("2026-08-26", 1), ("2026-08-25", 7)])

        XCTAssertEqual(stacked.top(ofDay: 0), 0)
        XCTAssertEqual(stacked.top(ofDay: 1), 140)
        XCTAssertEqual(stacked.top(ofDay: 2), 280)
        XCTAssertEqual(stacked.height(ofDay: 2), 40 + 300)
        XCTAssertEqual(stacked.totalHeight, 280 + 340)
    }

    /// The bug this exists to fix.
    ///
    /// Driving a scrubber from a photograph's position in the list makes a one-photograph
    /// day and a twenty-five-photograph day nearly adjacent to the thumb while being nine
    /// rows apart on screen. The thumb then jumps as the content scrolls smoothly, which
    /// is what "janky" was.
    func testTheRailMeasuresTheSameThingTheGridDoes() {
        // One enormous day, then two small ones. By photograph count the big day is 90%
        // of the library; by height it is much less, because the small days each still
        // cost a heading and a row.
        let uneven = layout([("2026-08-27", 90), ("2020-01-01", 5), ("2019-01-01", 5)])

        // 90 photos over 3 columns is 30 rows: 40 + 3000. Each small day is 40 + 200.
        XCTAssertEqual(uneven.totalHeight, 3040 + 240 + 240)
        XCTAssertEqual(uneven.fraction(ofDay: 1), 3040 / 3520, accuracy: 0.0001)

        // By photograph count that boundary would have been at 0.9; by height it is at
        // 0.86, and the second small day at 0.93 rather than 0.95. Those differences are
        // the jump.
        XCTAssertEqual(uneven.fraction(ofDay: 2), 3280 / 3520, accuracy: 0.0001)
    }

    func testDraggingTheRailAndReadingItBackAgree() {
        let stacked = layout([("2026-08-27", 30), ("2026-08-26", 1), ("2026-08-25", 12)])

        for day in 0..<3 {
            XCTAssertEqual(stacked.day(atFraction: stacked.fraction(ofDay: day)), day)
        }
    }

    func testTheThumbReachesTheBottomBecauseTheLastScreenfulIsNotScrolledPast() {
        let index = TimelineIndex(buckets: [TimelineBucket(date: "2026-08-27", count: 30)])
        let onScreen = TimelineLayout(
            index: index,
            metrics: TimelineMetrics(
                columns: 3, rowHeight: 100, headerHeight: 40, viewportHeight: 500
            )
        )

        // 40 + 1000 tall, 500 of it visible, so 540 of scrolling.
        XCTAssertEqual(onScreen.scrollableHeight, 540)
        XCTAssertEqual(onScreen.day(atFraction: 1), 0)
    }

    func testAViewportTallerThanTheLibraryDoesNotDivideByZero() {
        let tiny = TimelineLayout(
            index: TimelineIndex(buckets: [TimelineBucket(date: "2026-08-27", count: 1)]),
            metrics: TimelineMetrics(
                columns: 3, rowHeight: 100, headerHeight: 40, viewportHeight: 9_000
            )
        )

        XCTAssertEqual(tiny.scrollableHeight, 1)
        XCTAssertEqual(tiny.fraction(ofDay: 0), 0)
    }

    func testYearsAreMarkedWhereTheirPhotographsAreNotWhereTheirDatesAre() {
        let years = layout([
            ("2026-08-27", 90),
            ("2026-01-01", 3),
            ("2020-06-01", 3),
            ("2019-06-01", 3),
        ])

        let marks = years.yearMarks()
        XCTAssertEqual(marks.map(\.year), [2026, 2020, 2019])
        XCTAssertEqual(marks[0].fraction, 0, accuracy: 0.0001)
        // 2026 holds nearly everything, so 2020 starts most of the way down.
        XCTAssertGreaterThan(marks[1].fraction, 0.8)
    }

    func testLabelsThatWouldOverlapAreDroppedAndTheFirstIsAlwaysKept() {
        // Twenty years, one photograph each: every mark within a few points of the last.
        let crowded = layout((0..<20).map { ("\(2026 - $0)-06-01", 1) })

        let thinned = crowded.yearMarks(spacedBy: 44, railHeight: 400)

        XCTAssertEqual(thinned.first?.year, 2026)
        XCTAssertLessThan(thinned.count, 20)
        for (earlier, later) in zip(thinned, thinned.dropFirst()) {
            XCTAssertGreaterThanOrEqual((later.fraction - earlier.fraction) * 400, 44)
        }
    }

    func testAnEmptyLibraryHasNoHeightAndNoMarks() {
        let empty = layout([])

        XCTAssertEqual(empty.totalHeight, 0)
        XCTAssertEqual(empty.day(atFraction: 0.5), 0)
        XCTAssertTrue(empty.yearMarks().isEmpty)
    }

    func testASingleEnormousDayIsOneSegmentOfTheRightHeight() {
        let wedding = layout([("2026-06-13", 4_000)])

        XCTAssertEqual(wedding.totalHeight, 40 + Double((4_000 / 3 + 1)) * 100)
        XCTAssertEqual(wedding.day(atFraction: 0.7), 0)
    }
}

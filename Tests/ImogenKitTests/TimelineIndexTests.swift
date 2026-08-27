import ImogenSDK
import XCTest

@testable import ImogenKit

final class TimelineIndexTests: XCTestCase {

    // Three photographs on the 27th, one on the 26th, two on the 25th.
    private let index = TimelineIndex(
        buckets: [
            TimelineBucket(date: "2026-08-27", count: 3),
            TimelineBucket(date: "2026-08-26", count: 1),
            TimelineBucket(date: "2026-08-25", count: 2),
        ]
    )

    func testKnowsHowManyPhotographsThereAreWithoutFetchingAny() {
        XCTAssertEqual(index.photoCount, 6)
        XCTAssertEqual(index.dayCount, 3)
    }

    func testEachDayStartsWhereTheLastOneEnded() {
        XCTAssertEqual(index.firstPhoto(ofDay: 0), 0)
        XCTAssertEqual(index.firstPhoto(ofDay: 1), 3)
        XCTAssertEqual(index.firstPhoto(ofDay: 2), 4)
    }

    func testAPhotographKnowsWhichDayItBelongsTo() {
        XCTAssertEqual(index.day(ofPhoto: 0), 0)
        XCTAssertEqual(index.day(ofPhoto: 2), 0)
        XCTAssertEqual(index.day(ofPhoto: 3), 1)
        XCTAssertEqual(index.day(ofPhoto: 4), 2)
        XCTAssertEqual(index.day(ofPhoto: 5), 2)
    }

    /// The whole point of the scrubber: dragging halfway lands halfway through the
    /// photographs, not halfway through the list of dates.
    func testTheScrubberIsWeightedByPhotographsNotByDays() {
        let lopsided = TimelineIndex(
            buckets: [
                TimelineBucket(date: "2026-08-27", count: 900),
                TimelineBucket(date: "2020-01-01", count: 50),
                TimelineBucket(date: "2019-01-01", count: 50),
            ]
        )

        // Halfway is still inside the big day, because nine tenths of the library is in
        // it. A scrubber weighted by dates would have been two days further on.
        XCTAssertEqual(lopsided.day(atFraction: 0.5), 0)
        XCTAssertEqual(lopsided.day(atFraction: 0.92), 1)
        XCTAssertEqual(lopsided.day(atFraction: 0.96), 2)
        XCTAssertEqual(lopsided.day(atFraction: 1.0), 2)
    }

    func testTheScrubberStaysInsideTheListAtBothExtremes() {
        XCTAssertEqual(index.day(atFraction: 0), 0)
        XCTAssertEqual(index.day(atFraction: 1), 2)
        // Out of range input is somebody's finger leaving the track, not a bug.
        XCTAssertEqual(index.day(atFraction: -3), 0)
        XCTAssertEqual(index.day(atFraction: 4), 2)
    }

    func testAtRestTheThumbSitsWhereTheDayDoes() {
        XCTAssertEqual(index.fraction(ofDay: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(index.fraction(ofDay: 1), 0.5, accuracy: 0.0001)
    }

    func testTrashingShortensTheDayRatherThanRefetchingTheWholeShape() {
        let after = index.removing(["2026-08-27": 1])

        XCTAssertEqual(after.photoCount, 5)
        XCTAssertEqual(after.count(ofDay: 0), 2)
        XCTAssertEqual(after.dayCount, 3)
    }

    func testEmptyingADayRemovesTheDay() {
        let after = index.removing(["2026-08-26": 1])

        XCTAssertEqual(after.buckets.map(\.date), ["2026-08-27", "2026-08-25"])
        XCTAssertEqual(after.photoCount, 5)
    }

    func testAnEmptyLibraryHasNothingToScroll() {
        let empty = TimelineIndex(buckets: [])

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.photoCount, 0)
        XCTAssertEqual(empty.day(atFraction: 0.5), 0)
        XCTAssertEqual(empty.fraction(ofDay: 0), 0)
    }

    func testASingleEnormousDayStillIndexesCorrectly() {
        let wedding = TimelineIndex(buckets: [TimelineBucket(date: "2026-06-13", count: 4_000)])

        XCTAssertEqual(wedding.photoCount, 4_000)
        XCTAssertEqual(wedding.day(ofPhoto: 3_999), 0)
        XCTAssertEqual(wedding.day(atFraction: 0.7), 0)
    }

    func testADayIsFetchedAsTheWholeUTCDayBothEndsIncluded() {
        let bounds = dayBounds("2026-08-27")

        XCTAssertEqual(bounds.after, "2026-08-27T00:00:00.000Z")
        XCTAssertEqual(bounds.before, "2026-08-27T23:59:59.999Z")
    }
}

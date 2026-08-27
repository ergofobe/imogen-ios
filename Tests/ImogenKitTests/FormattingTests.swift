import XCTest

@testable import ImogenKit

final class FormattingTests: XCTestCase {

    /// Late in the UTC day, so any timezone west of Greenwich is already on the day
    /// before — which is exactly the condition that produced the bug below.
    private let lateOnTheTwentySeventh = Date(timeIntervalSince1970: 1_724_800_000)

    /// The bug this exists to keep fixed.
    ///
    /// The server groups the timeline by UTC calendar date, so a bucket key is a UTC day.
    /// Rendering one with a local-time formatter shifted it back a day for everybody west
    /// of Greenwich: every heading wrong, every photograph apparently filed under the day
    /// before. Caught by looking at the running app in a US timezone and noticing the top
    /// of the timeline said the 21st when the newest photograph was taken on the 22nd.
    func testADayHeadingIsTheServersDayNotTheReadersDay() {
        XCTAssertTrue(
            dayHeading("2024-07-22", now: lateOnTheTwentySeventh).contains("22"),
            "the heading must name the UTC day the server filed the photograph under"
        )
        XCTAssertTrue(dayHeading("2019-12-31", now: lateOnTheTwentySeventh).contains("31"))
    }

    func testThisYearDropsTheYearAndOtherYearsKeepIt() {
        XCTAssertFalse(dayHeading("2024-07-22", now: lateOnTheTwentySeventh).contains("2024"))
        XCTAssertTrue(dayHeading("2019-07-22", now: lateOnTheTwentySeventh).contains("2019"))
    }

    func testTodayAndYesterdayAreNamedRatherThanDated() {
        XCTAssertEqual(dayHeading("2024-08-27", now: lateOnTheTwentySeventh), "Today")
        XCTAssertEqual(dayHeading("2024-08-26", now: lateOnTheTwentySeventh), "Yesterday")
        XCTAssertNotEqual(dayHeading("2024-08-25", now: lateOnTheTwentySeventh), "Yesterday")
    }

    func testTheScrubbersLabelIsTheMonthTheServerFiledItUnder() {
        XCTAssertTrue(monthHeading("2024-07-22").contains("2024"))
        XCTAssertFalse(monthHeading("2024-07-22").contains("22"))
    }

    func testSomethingThatIsNotADateIsPassedThroughRatherThanGuessedAt() {
        XCTAssertEqual(dayHeading("not a date"), "not a date")
        XCTAssertEqual(monthHeading(""), "")
    }

    /// Capture times go on the wire as UTC, whatever the phone's timezone is.
    func testCaptureTimesAreWrittenAsUTC() {
        XCTAssertEqual(isoInstant(Date(timeIntervalSince1970: 1_609_459_200)), "2021-01-01T00:00:00.000Z")
    }

    func testDurationsAreMinutesAndSecondsZeroPadded() {
        XCTAssertEqual(formatDuration(7), "0:07")
        XCTAssertEqual(formatDuration(65.4), "1:05")
        XCTAssertEqual(formatDuration(719.6), "12:00")
    }

    /// Shutter speeds are read as fractions, not as decimals of a second.
    func testShutterSpeedsAreFractions() {
        XCTAssertEqual(formatShutter(0.008), "1/125 s")
        XCTAssertEqual(formatShutter(2), "2.0 s")
    }
}

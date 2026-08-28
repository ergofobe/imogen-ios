import Foundation

/// Turning what the API says into what a person reads.
///
/// Timestamps stay strings all the way from the server, because the contract says ISO-8601
/// and a client that parses into a date type and formats on the way back out eventually
/// sends the server something it did not give.  So the formatting happens here, at the
/// last possible moment, and only for display.

private let isoDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

private let isoInstantParser: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

/// ISO-8601 in UTC, which is the only format the contract accepts.
public func isoInstant(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

/// A calendar and formatters fixed to UTC.
///
/// The day strings these render are the server's bucket keys, and the server groups by the
/// UTC calendar date. Parsing one as UTC midnight and then formatting it in local time
/// shifts it by a day for everybody west of Greenwich — which is a timeline where every
/// heading is wrong and every photograph looks filed under the day before.
private var utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func utcFormatter(template: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
}

/// The heading for one day, in the reader's language.
///
/// The year is dropped for this year: a timeline of mostly-recent photographs repeating
/// the same four digits down the page is noise.
public func dayHeading(_ date: String, now: Date = Date()) -> String {
    guard let parsed = isoDay.date(from: String(date.prefix(10))) else { return date }

    if utcCalendar.isDate(parsed, inSameDayAs: now) { return "Today" }
    if let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: now),
        utcCalendar.isDate(parsed, inSameDayAs: yesterday) {
        return "Yesterday"
    }

    let sameYear = utcCalendar.isDate(parsed, equalTo: now, toGranularity: .year)
    return utcFormatter(template: sameYear ? "EEEEdMMMM" : "dMMMMyyyy").string(from: parsed)
}

/// "August 2014" — the granularity somebody actually remembers a photograph by, and what
/// the scrubber shows under a dragging thumb.
public func monthHeading(_ date: String) -> String {
    guard let parsed = isoDay.date(from: String(date.prefix(10))) else { return date }
    return utcFormatter(template: "MMMMyyyy").string(from: parsed)
}

/// Built once, like every other formatter here. This one is read by the accessibility
/// label of every cell in the grid, and a `DateFormatter` per visible square of a
/// ninety-thousand photograph timeline is a lot of work to do while somebody is scrolling.
private let readableInstant: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    return formatter
}()

public func fullDate(_ iso: String) -> String {
    guard let parsed = isoInstantParser.date(from: String(iso.prefix(19))) else { return iso }
    return readableInstant.string(from: parsed)
}

public func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

public func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Shutter speeds are read as fractions, not as decimals of a second.
public func formatShutter(_ exposure: Double) -> String {
    exposure >= 1
        ? String(format: "%.1f s", exposure)
        : "1/\(Int((1 / exposure).rounded())) s"
}

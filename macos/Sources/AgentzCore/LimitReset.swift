import Foundation

/// When the rate limit in `message` resets, as the agent said it when it
/// stopped, at `at`:
///
/// - Claude: `resets 6:50pm (Europe/Istanbul)`, `resets 4pm`, or with a
///   day, `resets Aug 31 at 6:19pm (Europe/London)`. Without a zone, in
///   this Mac's zone.
/// - Codex: `try again at Aug 5th, 2026 9:34 AM`, in this Mac's zone.
///
/// A time without a day is the next one after `at`.
public func limitReset(_ message: String, at: Date) -> Date? {
    if let m = firstMatch(claudeReset, in: message) {
        let zone = m[6].flatMap { TimeZone(identifier: $0) } ?? .current
        return moment(month: m[1], day: m[2], year: nil, hour: m[3], minute: m[4], half: m[5], zone: zone, after: at)
    }
    if let m = firstMatch(codexReset, in: message) {
        return moment(month: m[1], day: m[2], year: m[3], hour: m[4], minute: m[5], half: m[6], zone: .current, after: at)
    }
    return nil
}

/// When the window of `usage` that is used up starts over, if one is and
/// does so after `at`: for when the agent's own words have no time.
public func limitReset(_ usage: Usage?, after at: Date) -> Date? {
    [usage?.session, usage?.week].compactMap(\.self)
        .filter { $0.used >= 100 }
        .map { Date(timeIntervalSince1970: TimeInterval($0.resetsAt)) }
        .filter { $0 > at }
        .max()
}

private let claudeReset = try! NSRegularExpression(
    pattern: #"resets (?:at )?(?:([a-z]{3,9})\.? (\d{1,2})(?:st|nd|rd|th)?,? (?:at )?)?(\d{1,2})(?::(\d{2}))? ?([ap]m)(?: \(([^)]+)\))?"#,
    options: .caseInsensitive
)

private let codexReset = try! NSRegularExpression(
    pattern: #"try again at ([a-z]{3,9})\.? (\d{1,2})(?:st|nd|rd|th)?,? (\d{4}),? (\d{1,2}):(\d{2}) ?([ap]m)"#,
    options: .caseInsensitive
)

/// The groups of the first match, nil where a group did not take part.
private func firstMatch(_ regex: NSRegularExpression, in text: String) -> [String?]? {
    let range = NSRange(text.startIndex..., in: text)
    guard let m = regex.firstMatch(in: text, range: range) else { return nil }
    return (0 ..< m.numberOfRanges).map { i in
        Range(m.range(at: i), in: text).map { String(text[$0]) }
    }
}

private let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

private func moment(
    month: String?, day: String?, year: String?, hour: String?, minute: String?, half: String?,
    zone: TimeZone, after at: Date
) -> Date? {
    guard let hour = hour.flatMap(Int.init), (1 ... 12).contains(hour) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var c = calendar.dateComponents([.year, .month, .day], from: at)
    let pm = half?.lowercased() == "pm"
    c.hour = hour % 12 + (pm ? 12 : 0)
    c.minute = minute.flatMap(Int.init) ?? 0
    let dated = month != nil
    if let month {
        guard let i = months.firstIndex(of: String(month.lowercased().prefix(3))), let day = day.flatMap(Int.init)
        else { return nil }
        c.month = i + 1
        c.day = day
    }
    if let year = year.flatMap(Int.init) { c.year = year }
    guard var date = calendar.date(from: c) else { return nil }
    // A reset that seems to be before the stop is the next one: tomorrow,
    // or next year for a day without a year.
    if year == nil, date < at - 60 {
        date = calendar.date(byAdding: dated ? .year : .day, value: 1, to: date) ?? date
    }
    return date
}

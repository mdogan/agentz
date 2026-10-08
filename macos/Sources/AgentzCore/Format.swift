import Foundation

/// A time span like `42m`, `2h10m` or `3d4h`.
public func until(_ secs: UInt64) -> String {
    let m = (secs + 59) / 60
    switch m {
    case ..<60: return "\(m)m"
    case ..<1440: return "\(m / 60)h" + String(format: "%02dm", m % 60)
    default: return "\(m / 1440)d\(m % 1440 / 60)h"
    }
}

/// How long something took, e.g. `12s`, `1m 3s` or `2h 5m`.
public func elapsed(_ seconds: TimeInterval) -> String {
    let s = Int(max(seconds, 0).rounded())
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s"
    default: return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// How long something has gone on, in whole minutes after the first one,
/// e.g. `40s`, `3m` or `1h 5m`.
public func goingOn(_ seconds: TimeInterval) -> String {
    seconds < 60 ? elapsed(seconds) : elapsed((seconds / 60).rounded(.down) * 60)
}

/// How long ago `t` was, e.g. `now`, `5m ago`, `3d ago`.
public func age(now: Date, _ t: Date) -> String {
    let s = UInt64(max(now.timeIntervalSince(t), 0))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(s / 60)m ago"
    case ..<86400: return "\(s / 3600)h ago"
    case ..<2_592_000: return "\(s / 86400)d ago"
    default: return "\(s / 2_592_000)mo ago"
    }
}

/// `s` on one line, cut to at most `max` characters with `…`.
public func short(_ s: String, _ max: Int) -> String {
    let s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return s.count > max ? s.prefix(max) + "…" : s
}

/// An amount of memory, e.g. `840 MB` or `1.2 GB`.
public func memorySize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}

/// A time of day, e.g. `2:10 PM`, with `tomorrow` or the weekday when it
/// is not today.
public func clockTime(_ date: Date, now: Date = Date()) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    return dayName(date, now: now).map { "\($0) \(time)" } ?? time
}

/// When something happens, to go after a verb: `at 2:10 PM`, `tomorrow at
/// 9:00 AM` or `on Friday at 9:00 AM`.
public func atTime(_ date: Date, now: Date = Date()) -> String {
    let time = "at " + date.formatted(date: .omitted, time: .shortened)
    switch dayName(date, now: now) {
    case nil: return time
    case "tomorrow": return "tomorrow \(time)"
    case let day?: return "on \(day) \(time)"
    }
}

/// Nil for today, else `tomorrow` or the weekday.
private func dayName(_ date: Date, now: Date) -> String? {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return nil }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
        return "tomorrow"
    }
    return date.formatted(.dateTime.weekday(.wide))
}

/// The path with the home folder as `~`.
public func tilde(_ path: String) -> String {
    let home = Paths.home
    if pathStarts(path, with: home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

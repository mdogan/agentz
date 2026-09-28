// Ghostty's `notify-on-command-finish` settings: whether and how to tell the
// user that a command in a shell ended. Ghostty only reports the end; the
// app around the terminal decides what to do, so we read them ourselves.

import Foundation

public struct CommandFinishSettings: Equatable, Sendable {
    public enum When: String, Sendable {
        case never, unfocused, always
    }

    public var when = When.never
    /// Ghostty's bell: by default it bounces the Dock icon and marks the
    /// tab until the user looks.
    public var bell = true
    /// A desktop notification.
    public var notify = false
    /// Commands that ran shorter than this are not reported.
    public var after: TimeInterval = 5

    public init() {}

    /// The settings in Ghostty config text. The last line of a key wins;
    /// an empty or unknown value keeps Ghostty's default.
    public init(config: String) {
        for (key, value) in TerminalColors.parse(config) {
            switch key {
            case "notify-on-command-finish":
                when = When(rawValue: value) ?? .never
            case "notify-on-command-finish-action":
                (bell, notify) = Self.actions(value)
            case "notify-on-command-finish-after":
                after = parseDuration(value) ?? 5
            default: break
            }
        }
    }

    /// Whether to tell the user about a command that ran `seconds`.
    /// `looking` is true when the user looks at its terminal.
    public func applies(seconds: TimeInterval, looking: Bool) -> Bool {
        switch when {
        case .never: false
        case .unfocused: !looking && seconds >= after
        case .always: seconds >= after
        }
    }

    /// `bell,notify`, `no-bell`, `true` or `false`. Like Ghostty, a flag not
    /// named keeps its default: `notify` alone means `bell,notify`.
    static func actions(_ value: String) -> (bell: Bool, notify: Bool) {
        var bell = true, notify = false
        for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "true": (bell, notify) = (true, true)
            case "false": (bell, notify) = (false, false)
            case "bell": bell = true
            case "no-bell": bell = false
            case "notify": notify = true
            case "no-notify": notify = false
            default: break
            }
        }
        return (bell, notify)
    }
}

/// A Ghostty duration like `5s`, `1h30m` or `1m 30s`, in seconds.
public func parseDuration(_ text: String) -> TimeInterval? {
    let units: [(String, TimeInterval)] = [
        ("ms", 1e-3), ("us", 1e-6), ("µs", 1e-6), ("ns", 1e-9),
        ("y", 365 * 86400), ("w", 7 * 86400), ("d", 86400), ("h", 3600), ("m", 60), ("s", 1),
    ]
    var rest = Substring(text.trimmingCharacters(in: .whitespaces))
    guard !rest.isEmpty else { return nil }
    var total: TimeInterval = 0
    while !rest.isEmpty {
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let n = Double(digits) else { return nil }
        rest = rest.dropFirst(digits.count).drop(while: { $0 == " " })
        guard let (unit, scale) = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
        total += n * scale
        rest = rest.dropFirst(unit.count).drop(while: { $0 == " " })
    }
    return total
}

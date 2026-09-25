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

/// The path with the home folder as `~`.
public func tilde(_ path: String) -> String {
    let home = Paths.home
    if pathStarts(path, with: home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

// The terminal's colors, read from Ghostty config text, so the rest of the
// window can match the terminals.

import Foundation

/// A color with 0-1 components.
public struct RGB: Equatable, Sendable {
    public var r, g, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        (self.r, self.g, self.b) = (r, g, b)
    }

    /// `#RRGGBB` or `RRGGBB`. Ghostty also knows X11 color names; those are
    /// not read here.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Perceived brightness, 0-1.
    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    /// This color moved `amount` (0-1) of the way to `other`.
    public func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
    }
}

public struct TerminalColors: Equatable, Sendable {
    public var background: RGB
    public var foreground: RGB
    /// ANSI colors by index: 1 red, 2 green, 3 yellow, 4 blue, ...
    public var palette: [Int: RGB] = [:]
    public var cursor: RGB?
    public var selection: RGB?

    public init(background: RGB, foreground: RGB) {
        self.background = background
        self.foreground = foreground
    }

    public var isDark: Bool { background.luminance < 0.5 }

    /// Ghostty's own defaults.
    public static let ghostty = TerminalColors(background: RGB(hex: "282C34")!, foreground: RGB(hex: "FFFFFF")!)

    /// The colors in Ghostty config text: its theme's first, then its own
    /// color settings on top, as Ghostty does. `dark` picks the side of a
    /// `light:...,dark:...` theme. `readTheme` returns a theme file's text.
    public static func from(config: String, dark: Bool, readTheme: (String) -> String?) -> TerminalColors {
        var colors = ghostty
        let settings = parse(config)
        if let theme = settings.last(where: { $0.key == "theme" })?.value,
           let name = pickTheme(theme, dark: dark), let text = readTheme(name)
        {
            colors.apply(parse(text))
        }
        colors.apply(settings)
        return colors
    }

    private mutating func apply(_ settings: [(key: String, value: String)]) {
        for (key, value) in settings {
            switch key {
            case "background": background = RGB(hex: value) ?? background
            case "foreground": foreground = RGB(hex: value) ?? foreground
            case "cursor-color": cursor = RGB(hex: value) ?? cursor
            case "selection-background": selection = RGB(hex: value) ?? selection
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let i = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   let c = RGB(hex: String(parts[1]))
                {
                    palette[i] = c
                }
            default: break
            }
        }
    }

    /// `key = value` lines, without comments and blank lines.
    static func parse(_ text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return (key, value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
    }

    /// `Name` or `light:Name,dark:Name`.
    static func pickTheme(_ value: String, dark: Bool) -> String? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let wanted = dark ? "dark:" : "light:"
        if let side = parts.first(where: { $0.hasPrefix(wanted) }) {
            return String(side.dropFirst(wanted.count))
        }
        return parts.first { !$0.hasPrefix("light:") && !$0.hasPrefix("dark:") } ?? parts.first
    }
}

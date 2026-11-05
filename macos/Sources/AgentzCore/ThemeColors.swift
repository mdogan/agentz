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

    /// This color in OKLab, where equal distances look about equally
    /// different.
    fileprivate var oklab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear(r), linear(g), linear(b))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
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

/// A Ghostty theme agentz can switch to.
public struct GhosttyTheme: Hashable, Sendable {
    public var name: String
    public var isDark: Bool
    /// Looks the same in agentz as another theme, so the Theme menu leaves
    /// it out. It still works when picked or named in the Ghostty config.
    public var isLookalike: Bool

    public init(name: String, isDark: Bool, isLookalike: Bool = false) {
        (self.name, self.isDark, self.isLookalike) = (name, isDark, isLookalike)
    }
}

/// The Ghostty themes on disk, and configs that use one of them.
public enum GhosttyThemes {
    /// Where the user's own themes live.
    public static func ownDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return [
            xdg + "/ghostty/themes",
            home + "/Library/Application Support/com.mitchellh.ghostty/themes",
        ]
    }

    /// Where Ghostty looks for themes by name. User themes come first.
    public static func directories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String] {
        ownDirectories(environment: environment, home: home) + [
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
            home + "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
    }

    /// The file of the theme `name`, an absolute path or a name found in
    /// `directories`.
    public static func path(of name: String, in directories: [String] = directories()) -> String? {
        if name.hasPrefix("/") { return FileManager.default.fileExists(atPath: name) ? name : nil }
        return directories.map { $0 + "/" + name }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every theme name in `directories`, each once, in Finder's order.
    public static func names(in directories: [String] = directories()) -> [String] {
        let fileManager = FileManager.default
        var names = Set<String>()
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: directory + "/" + entry, isDirectory: &isDirectory),
                   !isDirectory.boolValue
                {
                    names.insert(entry)
                }
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Each named theme with whether its background is dark, for the Light
    /// and Dark theme menus, and whether it is a lookalike of another one.
    /// A theme without a background keeps Ghostty's dark one. Themes in
    /// `own` are never lookalikes.
    public static func themes(
        named names: [String],
        in directories: [String] = directories(),
        own: [String] = []
    ) -> [GhosttyTheme] {
        var alwaysKept = wellKnown
        let colors = names.map { name in
            let path = path(of: name, in: directories)
            if let path, own.contains(where: { path.hasPrefix($0 + "/") }) { alwaysKept.insert(name) }
            let text = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            return TerminalColors.from(config: text ?? "", dark: true) { _ in nil }
        }
        let lookalikes = lookalikes(names: names, colors: colors, alwaysKept: alwaysKept)
        return zip(names, colors).map { name, colors in
            GhosttyTheme(name: name, isDark: colors.isDark, isLookalike: lookalikes.contains(name))
        }
    }

    /// Popular themes people look for by name. They stay in the menu even
    /// when they look like another theme.
    static let wellKnown: Set<String> = [
        "Atom One Dark", "Atom One Light", "Ayu", "Ayu Light", "Ayu Mirage",
        "Catppuccin Frappe", "Catppuccin Latte", "Catppuccin Macchiato", "Catppuccin Mocha",
        "Claude", "Claude Light", "Dracula", "Everforest Dark Hard", "Ghostty Default Style Dark",
        "GitHub Dark Default", "GitHub Light Default", "Gruvbox Dark", "Gruvbox Light",
        "Kanagawa Dragon", "Kanagawa Lotus", "Kanagawa Wave", "Monokai Pro", "Night Owl", "Nightfox", "Nord",
        "One Half Dark", "One Half Light", "Rose Pine", "Rose Pine Dawn", "Rose Pine Moon",
        "TokyoNight", "TokyoNight Day", "TokyoNight Moon", "TokyoNight Storm",
    ]

    /// The names of themes that look the same as a theme kept before them.
    /// `alwaysKept` go first, then short names, as "Modus Vivendi" is the one
    /// to keep over "Modus Vivendi Tritanopia".
    private static func lookalikes(names: [String], colors: [TerminalColors], alwaysKept: Set<String>) -> Set<String> {
        let looks = colors.map(ThemeLook.init)
        let order = names.indices.sorted {
            let (a, b) = (alwaysKept.contains(names[$0]), alwaysKept.contains(names[$1]))
            if a != b { return a }
            return (names[$0].count, $0) < (names[$1].count, $1)
        }
        var kept: [ThemeLook] = []
        var lookalikes = Set<String>()
        for i in order {
            if !alwaysKept.contains(names[i]), kept.contains(where: { $0.isSame(as: looks[i]) }) {
                lookalikes.insert(names[i])
            } else {
                kept.append(looks[i])
            }
        }
        return lookalikes
    }

    /// Settings a theme sets, which a picked theme replaces.
    static let colorKeys: Set<String> = [
        "theme", "background", "foreground", "palette", "cursor-color", "cursor-text",
        "selection-background", "selection-foreground", "bold-color",
    ]

    /// `config` with the theme file at `path` in place of its own theme
    /// and colors, so the picked theme shows on Ghostty's defaults alone.
    public static func config(_ config: String, using path: String) -> String {
        let kept = config.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard let key = TerminalColors.parse(String(line)).first?.key else { return true }
            return !colorKeys.contains(key)
        }
        return (kept + ["theme = " + path]).joined(separator: "\n")
    }
}

/// The colors agentz shows of a theme: the background and text everywhere,
/// the first ANSI colors for status and accents, in OKLab.
private struct ThemeLook {
    typealias Lab = (l: Double, a: Double, b: Double)

    /// How far apart colors can be and still look the same, picked by
    /// comparing the themes Ghostty ships side by side. Accents are small
    /// and can differ the most.
    static let maxBackground = 0.035
    static let maxForeground = 0.07
    static let maxAccent = 0.2
    /// A tint gives a background its character but measures small on dark
    /// and pale colors, so it counts this many times over.
    static let tintWeight = 3.0

    let isDark: Bool
    let background, foreground: Lab
    /// Nil where a theme leaves the color to Ghostty.
    let accents: [Lab?]

    init(_ colors: TerminalColors) {
        isDark = colors.isDark
        background = colors.background.oklab
        foreground = colors.foreground.oklab
        accents = (1 ... 5).map { colors.palette[$0]?.oklab }
    }

    func isSame(as other: ThemeLook) -> Bool {
        isDark == other.isDark
            && Self.distance(background, other.background, tint: Self.tintWeight) < Self.maxBackground
            && Self.distance(foreground, other.foreground, tint: Self.tintWeight) < Self.maxForeground
            && zip(accents, other.accents).allSatisfy { a, b in
                guard let a, let b else { return a == nil && b == nil }
                return Self.distance(a, b, tint: 1) < Self.maxAccent
            }
    }

    private static func distance(_ x: Lab, _ y: Lab, tint: Double) -> Double {
        let (l, a, b) = (x.l - y.l, tint * (x.a - y.a), tint * (x.b - y.b))
        return (l * l + a * a + b * b).squareRoot()
    }
}

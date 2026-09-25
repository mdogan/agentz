import AgentzCore
import AppKit
import SwiftUI

/// The window's colors, taken from the terminals' Ghostty theme so the
/// sidebar and title bar match them. Follows the system appearance for
/// themes with a light and a dark side.
@MainActor
@Observable
final class Look {
    private(set) var colors: TerminalColors
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        colors = GhosttyApp.colors(dark: Self.systemIsDark)
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func update() {
        let new = GhosttyApp.colors(dark: Self.systemIsDark)
        if new != colors { colors = new }
    }

    var isDark: Bool { colors.isDark }
    var background: Color { Color(colors.background) }
    /// A little apart from the terminal, toward the text color.
    var sidebar: Color { Color(colors.background.mixed(with: colors.foreground, isDark ? 0.045 : 0.035)) }
    var text: Color { Color(colors.foreground) }
    var secondary: Color { Color(colors.foreground).opacity(0.58) }
    var faint: Color { Color(colors.foreground).opacity(0.3) }
    var hover: Color { Color(colors.foreground).opacity(0.05) }
    var selection: Color { Color(colors.foreground).opacity(0.11) }
    var fieldBackground: Color { Color(colors.foreground).opacity(0.07) }
    var divider: Color { Color(colors.foreground).opacity(0.12) }

    private func ansi(_ i: Int, _ fallback: RGB) -> Color {
        Color(colors.palette[i] ?? fallback)
    }

    var accent: Color { ansi(4, isDark ? RGB(0.47, 0.63, 1) : RGB(0.18, 0.37, 0.84)) }
    var green: Color { ansi(2, isDark ? RGB(0.47, 0.78, 0.55) : RGB(0.1, 0.53, 0.25)) }
    var yellow: Color { ansi(3, isDark ? RGB(0.9, 0.75, 0.24) : RGB(0.65, 0.41, 0)) }
    var red: Color { ansi(1, isDark ? RGB(0.94, 0.4, 0.4) : RGB(0.75, 0.15, 0.15)) }

    func color(for agent: Agent) -> Color {
        switch agent {
        case .claude: Color(isDark ? RGB(0.85, 0.47, 0.34) : RGB(0.75, 0.33, 0.2))
        case .codex: accent
        case .shell: secondary
        }
    }

    /// Makes the window chrome match: its background shows through the
    /// title bar, and its appearance sets light or dark controls.
    func style(_ window: NSWindow) {
        window.backgroundColor = NSColor(colors.background)
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if window.appearance?.name != appearance?.name { window.appearance = appearance }
    }
}

extension Color {
    init(_ c: RGB) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b)
    }
}

extension NSColor {
    convenience init(_ c: RGB) {
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

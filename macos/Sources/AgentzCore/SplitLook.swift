// How split panes look, from Ghostty's split settings. Ghostty.app draws
// its splits itself, not the terminal library, so we read them ourselves.

import Foundation

public struct SplitLook: Equatable, Sendable {
    /// How much of the pane the user does not work in shows through, from
    /// 0.15 to 1. Ghostty fades it a little so the focused one stands out;
    /// 1 does not fade it.
    public var unfocusedOpacity = 0.7
    /// The color the unfocused pane fades into. Nil for the background.
    public var unfocusedFill: RGB?
    /// The line between panes. Nil for one made from the theme.
    public var divider: RGB?

    public init() {}

    /// The settings in Ghostty config text. The last line of a key wins;
    /// an empty or unknown value keeps Ghostty's default.
    public init(config: String) {
        for (key, value) in TerminalColors.parse(config) {
            switch key {
            case "unfocused-split-opacity":
                unfocusedOpacity = Double(value).map { min(max($0, 0.15), 1) } ?? 0.7
            case "unfocused-split-fill":
                unfocusedFill = RGB(hex: value)
            case "split-divider-color":
                divider = RGB(hex: value)
            default: break
            }
        }
    }
}

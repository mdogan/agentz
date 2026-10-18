// Ghostty's quick terminal settings: where the drop-down terminal shows,
// how big it is, how it comes and goes, and the global key that toggles
// it. Ghostty.app makes its quick terminal itself, not the terminal
// library, so we read them ourselves.

import CoreGraphics
import Foundation

public struct QuickTerminalSettings: Equatable, Sendable {
    public enum Position: String, Sendable {
        case top, bottom, left, right, center
    }

    public enum Screen: String, Sendable {
        /// The one with the keyboard focus.
        case main
        /// The one under the mouse.
        case mouse
        /// The one with the menu bar in Displays settings.
        case menuBar = "macos-menu-bar"
    }

    public enum SpaceBehavior: String, Sendable {
        /// It comes along to the space the user switches to.
        case move
        /// It stays in the space it was shown in.
        case remain
    }

    /// A length on the screen: a share of its width or height, or points.
    public enum Length: Equatable, Sendable {
        case percent(Double)
        case points(Double)

        /// `50%` or `500px`. A bare number is an error in Ghostty.
        init?(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("%"), let n = Double(text.dropLast()), n >= 0 {
                self = .percent(n)
            } else if text.hasSuffix("px"), let n = Double(text.dropLast(2)), n >= 0 {
                self = .points(n)
            } else {
                return nil
            }
        }

        func points(of whole: CGFloat) -> CGFloat {
            switch self {
            case let .percent(n): whole * n / 100
            case let .points(n): n
            }
        }
    }

    public var position = Position.top
    /// Along the edge it slides in from: its height at the top or bottom,
    /// its width at the left or right. Nil for Ghostty's default.
    public var primarySize: Length?
    /// The other way. Nil for Ghostty's default.
    public var secondarySize: Length?
    public var screen = Screen.main
    /// How long it takes to slide in or out; 0 for no animation.
    public var animationDuration: TimeInterval = 0.2
    /// Hides it when another window gets the keyboard.
    public var autohide = true
    public var spaceBehavior = SpaceBehavior.move
    /// The `global:` key bound to `toggle_quick_terminal`, if any.
    public var hotKey: KeyTrigger?

    public init() {}

    /// The settings in Ghostty config text. The last line of a key wins;
    /// an empty or unknown value keeps Ghostty's default.
    public init(config: String) {
        for (key, value) in TerminalColors.parse(config) {
            switch key {
            case "quick-terminal-position":
                position = Position(rawValue: value) ?? .top
            case "quick-terminal-size":
                let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { Length(String($0)) }
                if parts.count <= 2, !parts.contains(nil) {
                    primarySize = parts.first ?? nil
                    secondarySize = parts.count == 2 ? parts[1] : nil
                } else {
                    (primarySize, secondarySize) = (nil, nil)
                }
            case "quick-terminal-screen":
                screen = Screen(rawValue: value) ?? .main
            case "quick-terminal-animation-duration":
                animationDuration = Double(value).map { max($0, 0) } ?? 0.2
            case "quick-terminal-autohide":
                autohide = value != "false"
            case "quick-terminal-space-behavior":
                spaceBehavior = SpaceBehavior(rawValue: value) ?? .move
            case "keybind":
                bind(value)
            default: break
            }
        }
    }

    /// One `keybind` value. `clear` drops what came before, and another
    /// action for the same key replaces the toggle, as in Ghostty.
    private mutating func bind(_ value: String) {
        if value == "clear" {
            hotKey = nil
            return
        }
        guard let (trigger, action) = KeyTrigger.binding(value) else { return }
        if action == "toggle_quick_terminal", trigger.global {
            hotKey = trigger
        } else if trigger.sameKey(as: hotKey) {
            hotKey = nil
        }
    }

    /// Its size on a screen whose free area (without the menu bar and the
    /// Dock) is `screen`, like Ghostty's: a side it does not set is the
    /// whole screen, or a fixed size for a centered one.
    public func size(on screen: CGSize) -> CGSize {
        let w = screen.width, h = screen.height
        let primary = { (whole: CGFloat, fallback: CGFloat) in primarySize?.points(of: whole) ?? fallback }
        let secondary = { (whole: CGFloat, fallback: CGFloat) in secondarySize?.points(of: whole) ?? fallback }
        let size: CGSize = switch position {
        case .top, .bottom:
            CGSize(width: secondary(w, w), height: primary(h, 400))
        case .left, .right:
            CGSize(width: primary(w, 400), height: secondary(h, h))
        case .center where w >= h:
            CGSize(width: secondary(w, 800), height: primary(h, 400))
        case .center:
            CGSize(width: primary(w, 400), height: secondary(h, 800))
        }
        return CGSize(width: min(size.width, w).rounded(), height: min(size.height, h).rounded())
    }

    /// Where it is when shown: at its edge of the free area `visible`, in
    /// the middle of that edge.
    public func shownFrame(visible: CGRect) -> CGRect {
        let size = size(on: visible.size)
        let midX = (visible.midX - size.width / 2).rounded()
        let midY = (visible.midY - size.height / 2).rounded()
        let origin = switch position {
        case .top: CGPoint(x: midX, y: visible.maxY - size.height)
        case .bottom: CGPoint(x: midX, y: visible.minY)
        case .left: CGPoint(x: visible.minX, y: midY)
        case .right: CGPoint(x: visible.maxX - size.width, y: midY)
        case .center: CGPoint(x: midX, y: midY)
        }
        return CGRect(origin: origin, size: size)
    }

    /// Where it slides from and back to: just past its edge of the whole
    /// screen `frame`. A centered one stays in place and fades.
    public func hiddenFrame(visible: CGRect, frame: CGRect) -> CGRect {
        var hidden = shownFrame(visible: visible)
        switch position {
        case .top: hidden.origin.y = frame.maxY
        case .bottom: hidden.origin.y = frame.minY - hidden.height
        case .left: hidden.origin.x = frame.minX - hidden.width
        case .right: hidden.origin.x = frame.maxX
        case .center: break
        }
        return hidden
    }
}

/// A Ghostty keybind trigger, like `ctrl+grave_accent` or `super+shift+t`.
public struct KeyTrigger: Equatable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var modifiers: Modifiers
    /// A key name like `backquote`, `key_a` or `f12`, or the one character
    /// the key types, like `` ` ``.
    public var key: String
    /// Works in every app, not only while the terminal has the keyboard.
    public var global = false

    public init(modifiers: Modifiers, key: String, global: Bool = false) {
        self.modifiers = modifiers
        self.key = key
        self.global = global
    }

    /// `global:ctrl+` + "`", with its prefixes. Nil for a sequence like
    /// `ctrl+a>n`, or an unknown modifier.
    public init?(_ text: String) {
        var rest = Substring(text)
        var global = false
        while let prefix = ["global:", "all:", "unconsumed:", "performable:"].first(where: { rest.hasPrefix($0) }) {
            if prefix == "global:" { global = true }
            rest = rest.dropFirst(prefix.count)
        }
        // A `+` key is written `ctrl++`.
        var parts = rest.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if rest.hasSuffix("++") { parts = parts.dropLast(2) + ["+"] }
        guard let key = parts.last, !key.isEmpty, !key.contains(">") else { return nil }
        var modifiers: Modifiers = []
        for name in parts.dropLast() {
            switch name.lowercased() {
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "super", "cmd", "command": modifiers.insert(.command)
            default: return nil
            }
        }
        self.init(modifiers: modifiers, key: key.lowercased(), global: global)
    }

    /// The trigger and action of a `keybind` value, like
    /// `global:ctrl+` + "`" + `=toggle_quick_terminal`. A `=` right after
    /// a `+` or at the start is the key itself.
    static func binding(_ value: String) -> (KeyTrigger, String)? {
        let chars = Array(value)
        guard let eq = chars.indices.first(where: { $0 > 0 && chars[$0] == "=" && chars[$0 - 1] != "+" }),
              let trigger = KeyTrigger(String(chars[..<eq]))
        else { return nil }
        return (trigger, String(chars[(eq + 1)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Like Ghostty writes it, e.g. `ctrl+shift+t`, for messages.
    public var description: String {
        let names: [(Modifiers, String)] = [(.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "super")]
        return names.filter { modifiers.contains($0.0) }.map { $0.1 + "+" }.joined() + key
    }

    /// The same keys, with or without `global:`.
    func sameKey(as other: KeyTrigger?) -> Bool {
        other.map { $0.modifiers == modifiers && $0.key == key } ?? false
    }
}

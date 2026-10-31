import SwiftUI

/// GitFork's colors. The status and diff colors come from the user's Ghostty
/// theme through `Look`, so they match the terminal.
@MainActor
enum GitForkTheme {
    static var accent: Color { Look.shared.accent }
    static var blue: Color { Look.shared.accent }
    static var green: Color { Look.shared.green }
    static var red: Color { Look.shared.red }
    static var purple: Color { Look.shared.magenta }
    static var orange: Color { Look.shared.yellow }

    /// A curated, harmonious palette used to give authors and labels a stable,
    /// recognizable color. High chroma so each hue is unmistakable, with value
    /// held low enough that white glyphs stay legible on top.
    static let identityPalette: [Color] = [
        Color(red: 0.94, green: 0.22, blue: 0.35),  // rose
        Color(red: 0.98, green: 0.52, blue: 0.09),  // orange
        Color(red: 0.87, green: 0.60, blue: 0.05),  // amber
        Color(red: 0.09, green: 0.70, blue: 0.37),  // green
        Color(red: 0.02, green: 0.66, blue: 0.63),  // teal
        Color(red: 0.11, green: 0.51, blue: 0.97),  // blue
        Color(red: 0.31, green: 0.36, blue: 0.94),  // indigo
        Color(red: 0.56, green: 0.30, blue: 0.90),  // purple
        Color(red: 0.94, green: 0.26, blue: 0.64)   // pink
    ]

    /// Deterministically maps a seed (e.g. an author name) to a palette color,
    /// so the same person keeps the same color across launches.
    static func identityColor(for seed: String) -> Color {
        guard !identityPalette.isEmpty else { return accent }
        var hash: UInt64 = 1469598103934665603  // FNV-1a offset basis
        for byte in seed.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return identityPalette[Int(hash % UInt64(identityPalette.count))]
    }

    /// Gives each repository name a stable window-toolbar color from the same
    /// curated deterministic palette as identities.
    static func repositoryColor(for name: String) -> Color {
        identityColor(for: name)
    }

    /// Foreground for added diff lines: the theme's green, as a terminal
    /// shows it.
    static func diffAddition(_: ColorScheme) -> Color {
        green
    }

    /// Foreground for removed diff lines: the theme's red.
    static func diffDeletion(_: ColorScheme) -> Color {
        red
    }
}

/// A colorful, deterministic avatar built from a person's initials. The fill
/// color is derived from `name`, so each author is visually recognizable.
struct IdentityAvatar: View {
    let name: String
    let initials: String
    var size: CGFloat = 18

    private var color: Color { GitForkTheme.identityColor(for: name) }

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: max(7, size * 0.42), weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
            .overlay {
                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
            .shadow(color: color.opacity(0.35), radius: size * 0.08, y: 0.5)
    }
}

enum GitForkHoverButtonVariant {
    case toolbarAction
    case icon
    case text
    case row(isSelected: Bool)
    case compactRow(isSelected: Bool)
}

struct GitForkHoverButtonStyle: ButtonStyle {
    let variant: GitForkHoverButtonVariant

    init(_ variant: GitForkHoverButtonVariant) {
        self.variant = variant
    }

    func makeBody(configuration: Configuration) -> some View {
        GitForkHoverButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            variant: variant
        )
    }
}

/// The hover and pressed appearance behind `GitForkHoverButtonStyle`, also used
/// directly by rows that cannot be a `Button`, such as draggable sidebar rows.
struct GitForkHoverButtonBody<Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let label: Label
    let isPressed: Bool
    let variant: GitForkHoverButtonVariant

    var body: some View {
        label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(
                maxWidth: expandsHorizontally ? .infinity : nil,
                alignment: .leading
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(isPressed && isEnabled ? 0.97 : 1)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    private var expandsHorizontally: Bool {
        switch variant {
        case .row, .compactRow: true
        default: false
        }
    }

    private var horizontalPadding: CGFloat {
        switch variant {
        case .toolbarAction: 7
        case .icon: 5
        case .text: 6
        case .row: 7
        case .compactRow: 5
        }
    }

    private var verticalPadding: CGFloat {
        switch variant {
        case .toolbarAction: 5
        case .icon: 4
        case .text: 3
        case .row: 5
        case .compactRow: 2
        }
    }

    private var cornerRadius: CGFloat {
        switch variant {
        case .row: 7
        case .compactRow: 6
        default: 6
        }
    }

    private var backgroundColor: Color {
        if isPressed && isEnabled {
            return GitForkTheme.accent.opacity(0.32)
        }

        switch variant {
        case let .row(isSelected), let .compactRow(isSelected):
            if isSelected {
                return GitForkTheme.accent.opacity(isHovering ? 0.30 : 0.20)
            }
            return isHovering ? neutralHoverColor : .clear

        case .toolbarAction, .icon:
            return isHovering && isEnabled
                ? GitForkTheme.accent.opacity(0.20)
                : .clear

        case .text:
            return isHovering && isEnabled
                ? GitForkTheme.accent.opacity(0.18)
                : .clear
        }
    }

    private var borderColor: Color {
        guard isHovering && isEnabled else { return .clear }
        switch variant {
        case .row, .compactRow:
            return GitForkTheme.accent.opacity(0.40)
        case .toolbarAction, .icon, .text:
            return GitForkTheme.accent.opacity(0.55)
        }
    }

    private var neutralHoverColor: Color {
        Look.shared.text.opacity(colorScheme == .dark ? 0.10 : 0.065)
    }
}

extension Color {
    @MainActor
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "A": GitForkTheme.green
        case "D": GitForkTheme.red
        case "R": GitForkTheme.purple
        case "U": GitForkTheme.orange
        default: GitForkTheme.blue
        }
    }
}

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

/// A round, flat avatar with a person's initials. The fill color comes
/// from `name`, so each author keeps a color of their own.
struct IdentityAvatar: View {
    let name: String
    let initials: String
    var size: CGFloat = 18

    private var color: Color { GitForkTheme.identityColor(for: name) }

    var body: some View {
        Circle()
            .fill(color.opacity(0.85))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: max(7, size * 0.42), weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
    }
}

enum GitForkHoverButtonVariant {
    case toolbarAction
    case icon
    case text
    case row(isSelected: Bool)
    case compactRow(isSelected: Bool)
}

/// The app's look for the git views' buttons and rows: a faint gray on
/// hover and a stronger gray when picked, as in the session list.
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

/// The hover and pressed look behind `GitForkHoverButtonStyle`, also used
/// directly by rows that cannot be a `Button`, such as draggable rows.
struct GitForkHoverButtonBody<Label: View>: View {
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
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private var expandsHorizontally: Bool {
        switch variant {
        case .row, .compactRow: true
        default: false
        }
    }

    private var horizontalPadding: CGFloat {
        switch variant {
        case .toolbarAction: 6
        case .icon: 3
        case .text: 5
        case .row: 8
        case .compactRow: 6
        }
    }

    private var verticalPadding: CGFloat {
        switch variant {
        case .toolbarAction: 3
        case .icon: 1
        case .text: 2
        case .row: 5
        case .compactRow: 3
        }
    }

    private var cornerRadius: CGFloat {
        switch variant {
        case .row, .compactRow: 6
        default: 5
        }
    }

    private var backgroundColor: Color {
        let look = Look.shared
        switch variant {
        case let .row(isSelected), let .compactRow(isSelected):
            if isSelected || isPressed && isEnabled { return look.selection }
            return isHovering ? look.hover : .clear
        case .toolbarAction, .icon, .text:
            if isPressed && isEnabled { return look.selection.opacity(1.6) }
            return isHovering && isEnabled ? look.selection : .clear
        }
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

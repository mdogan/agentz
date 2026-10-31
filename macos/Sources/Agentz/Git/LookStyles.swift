import AppKit
import SwiftUI

// The git views' helpers for drawing in agentz's colors, from GitFork's
// Look.swift. Colors come from `Look.shared`, agentz's own.

/// Paints a window in the Ghostty theme: text, accent, background, and the
/// window's own background and light or dark appearance.
private struct LookWindowStyle: ViewModifier {
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        let look = Look.shared
        content
            .foregroundStyle(look.text)
            .tint(look.accent)
            .background(look.background)
            .background(
                HostingWindowReader { window in
                    if self.window !== window { self.window = window }
                    if let window { look.style(window) }
                }
            )
            .onChange(of: look.colors) { _, _ in
                if let window { look.style(window) }
            }
    }
}

/// A text field drawn on the theme instead of the system's white box with a
/// blue focus ring: a faint fill, and an accent border while it has focus.
private struct LookField: ViewModifier {
    let isFocused: Bool
    let systemImage: String?

    func body(content: Content) -> some View {
        let look = Look.shared
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(isFocused ? look.accent : look.secondary)
            }
            content
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(look.fieldBackground, in: shape)
        .overlay(
            shape.strokeBorder(
                isFocused ? look.accent.opacity(0.75) : look.divider,
                lineWidth: isFocused ? 1.5 : 1
            )
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

extension View {
    /// Apply last, after `.focused` and key handlers, to a `TextField`.
    func lookField(isFocused: Bool, systemImage: String? = nil) -> some View {
        modifier(LookField(isFocused: isFocused, systemImage: systemImage))
    }

    func lookWindowStyle() -> some View {
        modifier(LookWindowStyle())
    }

    /// A list drawn on a theme surface instead of the system one.
    func lookListBackground(_ color: Color) -> some View {
        scrollContentBackground(.hidden)
            .background(color)
    }
}

/// A `List` row's background in the theme: a soft accent fill when selected,
/// like the sidebar rows. It also turns off the system selection highlight,
/// whose blue and white text ignore the theme and hide the row's own colors.
struct LookListRowBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? Look.shared.accent.opacity(0.20) : .clear)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(SystemSelectionHighlightRemover())
    }
}

/// Finds the table that AppKit hosts a `List` in and stops it drawing its
/// selection. Selection, keyboard navigation, and clicks keep working; if the
/// table is not found, the list keeps the system highlight.
struct SystemSelectionHighlightRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        RemoverView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? RemoverView)?.hideSelection()
    }

    private final class RemoverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hideSelection()
        }

        func hideSelection() {
            var view = superview
            while let current = view {
                if let table = current as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// Reports the AppKit window hosting a SwiftUI view, so it can take the
/// theme's look.
struct HostingWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onChange(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onChange(view.window) }
    }
}

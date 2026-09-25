import AppKit
import SwiftUI

/// Help › Keyboard Shortcuts. Most rows come from the menus, so the list
/// stays right when a shortcut changes; the rest are keys no menu shows.
struct ShortcutGroup: Identifiable {
    struct Row: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    let title: String
    let rows: [Row]
    var id: String { title }

    init(_ title: String, _ rows: [(String, String)]) {
        self.title = title
        self.rows = rows.map { Row(keys: $0.0, action: $0.1) }
    }
}

@MainActor
func shortcutGroups(_ menu: NSMenu) -> [ShortcutGroup] {
    let fromMenus = menu.items.compactMap { item -> ShortcutGroup? in
        let rows = (item.submenu?.items ?? [])
            .filter { !$0.keyEquivalent.isEmpty }
            .map { (shortcut($0), $0.title) }
        return rows.isEmpty ? nil : ShortcutGroup(item.title, rows)
    }
    // Keep in sync with the list's onKeyPress handlers in Sidebar.swift and
    // the Ghostty keybinds in Terminal.swift.
    return fromMenus + [
        ShortcutGroup("Session List", [
            ("↑ / ↓", "Select the previous / next session"),
            ("⇞ / ⇟", "Move ten sessions"),
            ("↖ / ↘", "Select the first / last session"),
            ("↩", "Open the selected session"),
            ("⎋", "Go to the terminal"),
        ]),
        ShortcutGroup("Filter", [
            ("↩", "Go to the session list"),
            ("⎋", "Clear the filter"),
        ]),
        ShortcutGroup("Terminal", [
            ("⌘+ / ⌘- / ⌘0", "Bigger / smaller / default font"),
            ("⌘K", "Clear the screen"),
            ("⌘← / ⌘→", "Go to the start / end of the line"),
            ("⌘⌫", "Delete to the start of the line"),
            ("⌥← / ⌥→", "Go to the previous / next word"),
            ("⌘↑ / ⌘↓", "Scroll to the previous / next prompt"),
            ("⌘↖ / ⌘↘", "Scroll to the top / bottom"),
            ("⌘⇞ / ⌘⇟", "Scroll a page up / down"),
            ("⇧ + arrows", "Move the end of the selection"),
            ("⇧⌘J", "Paste the path of a file with the screen's text"),
            ("⇧↩", "New line in the prompt"),
        ]),
    ]
}

/// A menu item's shortcut as macOS shows it, e.g. ⇧⌘N.
@MainActor
func shortcut(_ item: NSMenuItem) -> String {
    var key = item.keyEquivalent
    var mods = item.keyEquivalentModifierMask
    // An uppercase key equivalent means Shift.
    if key.lowercased() != key { mods.insert(.shift) }
    key = key.uppercased()
    var s = ""
    if mods.contains(.control) { s += "⌃" }
    if mods.contains(.option) { s += "⌥" }
    if mods.contains(.shift) { s += "⇧" }
    if mods.contains(.command) { s += "⌘" }
    return s + key
}

struct ShortcutsView: View {
    let groups: [ShortcutGroup]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                            ForEach(group.rows) { row in
                                GridRow {
                                    Text(row.keys)
                                        .font(.system(.body, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 110, alignment: .trailing)
                                    Text(row.action)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, idealWidth: 420, minHeight: 300, idealHeight: 640)
    }
}

@MainActor
final class ShortcutsWindowController: NSWindowController {
    init(menu: NSMenu) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsView(groups: shortcutGroups(menu))))
        window.title = "Keyboard Shortcuts"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 420, height: 640))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

import AppKit
import SwiftUI

/// Keeps the actual menu item: actions such as selecting a session range
/// or a theme need its tag or representedObject as their sender.
@MainActor
struct PaletteCommand: Identifiable {
    let id: ObjectIdentifier
    let item: NSMenuItem
    let category: String
    let title: String
    let keys: String
    let isEnabled: Bool
    let isOn: Bool

    init(item: NSMenuItem, category: String) {
        id = ObjectIdentifier(item)
        self.item = item
        self.category = category
        title = item.title
        keys = item.keyEquivalent.isEmpty ? "" : shortcut(item)
        isEnabled = item.isEnabled
        isOn = item.state == .on
    }

    /// Refreshes dynamic menus, including themes, and snapshots availability
    /// before the palette takes the keyboard from the original responder.
    /// Lists only the app's own commands, the ones targeting `owner`, so
    /// standard macOS items such as Copy, Hide or Minimize, and the ones
    /// AppKit adds by itself, stay out.
    static func collect(from menu: NSMenu, owner: AnyObject, excluding action: Selector) -> [PaletteCommand] {
        func visit(_ menu: NSMenu, path: [String]) -> [PaletteCommand] {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            // Put the application menu's commands last.
            let items = path.isEmpty ? Array(menu.items.dropFirst()) + Array(menu.items.prefix(1)) : menu.items
            return items.flatMap { item -> [PaletteCommand] in
                guard !item.isSeparatorItem, !item.isHidden else { return [] }
                if let submenu = item.submenu {
                    return visit(submenu, path: path + [item.title])
                }
                guard item.target === owner, let selector = item.action, selector != action else { return [] }
                return [PaletteCommand(item: item, category: path.joined(separator: " › "))]
            }
        }
        return visit(menu, path: [])
    }

    /// Called after the original window and responder have the keyboard.
    /// Revalidate then, since the session may have ended while searching.
    @discardableResult
    func perform() -> Bool {
        guard isEnabled, let action = item.action,
              let target = NSApp.target(forAction: action, to: item.target, from: item)
        else { return false }
        if let validator = target as? NSMenuItemValidation {
            guard validator.validateMenuItem(item) else { return false }
        } else if let validator = target as? NSUserInterfaceValidations {
            guard validator.validateUserInterfaceItem(item) else { return false }
        }
        return NSApp.sendAction(action, to: target, from: item)
    }
}

@MainActor
enum PaletteSearch {
    /// Each word can match the command or its menu path. Title matches come
    /// first; a subsequence also matches, e.g. "splr" finds "Split Right".
    static func filter(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        rank(commands, query: query, title: \.title, detail: \.category)
    }

    /// Each word can match an item's title or its detail. Title matches
    /// come first; a subsequence of the title also matches. Equal matches
    /// keep their order.
    static func rank<Item>(_ items: [Item], query: String, title: (Item) -> String, detail: (Item) -> String) -> [Item] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return items }
        return items.enumerated().compactMap { index, item -> (Int, Int, Item)? in
            let title = normalized(title(item))
            let detail = normalized(detail(item))
            var score = 0
            for word in words {
                if title.hasPrefix(word) {
                    continue
                } else if title.contains(word) {
                    score += 1
                } else if detail.contains(word) {
                    score += 2
                } else {
                    var remaining = word[...]
                    for character in title where character == remaining.first {
                        remaining = remaining.dropFirst()
                        if remaining.isEmpty { break }
                    }
                    guard remaining.isEmpty else { return nil }
                    score += 3
                }
            }
            return (score, index, item)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map { $0.2 }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// A searchable list in a sheet, such as All Actions or Go to Session.
/// What the user picked runs once the original responder has the keyboard
/// back, so Find and Copy Session Contents apply to the view the user
/// opened it from. A sheet can also belong to the quick terminal or another
/// app window. Only one shows at a time.
@MainActor
final class PaletteSheet {
    private(set) var sheet: NSWindow?

    var isShown: Bool { sheet != nil }

    /// `content` gets a `close`, to call once with what to run after the
    /// sheet, or with nil.
    func show<Content: View>(in parent: NSWindow, title: String,
                             content: (_ close: @escaping (_ then: (() -> Void)?) -> Void) -> Content)
    {
        guard sheet == nil, parent.sheetParent == nil, parent.attachedSheet == nil else { return }
        let responder = parent.firstResponder
        var then: (() -> Void)?
        let host = NSHostingController(rootView: content { [weak self, weak parent] action in
            guard let sheet = self?.sheet else { return }
            then = action
            parent?.endSheet(sheet)
        }.lookWindowStyle())
        host.sizingOptions = .preferredContentSize
        let sheet = NSPanel(contentViewController: host)
        sheet.title = title
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        Look.shared.style(sheet)
        self.sheet = sheet
        parent.beginSheet(sheet) { [weak self, weak parent, weak responder] _ in
            sheet.orderOut(nil)
            self?.sheet = nil
            // Ending a sheet and returning focus finish on the next pass.
            // An action may itself present a sheet or change window focus.
            DispatchQueue.main.async { [weak parent, weak responder] in
                guard let parent, parent.isVisible else { return }
                parent.makeKey()
                if let responder { parent.makeFirstResponder(responder) }
                then?()
            }
        }
    }

    /// All Actions: the app's menu commands.
    func showCommands(in parent: NSWindow, menu: NSMenu, owner: AnyObject, excluding action: Selector) {
        let commands = PaletteCommand.collect(from: menu, owner: owner, excluding: action)
        show(in: parent, title: "All Actions") { close in
            PaletteView(
                title: "All Actions", keys: "⇧⌘P", prompt: "Search commands…", empty: "No matching commands", verb: "run",
                items: commands, search: PaletteSearch.filter, isEnabled: \.isEnabled,
                label: { "\($0.category), \($0.title)" },
                row: { CommandRow(command: $0) }
            ) { command in
                close(command.map { command in { if !command.perform() { NSSound.beep() } } })
            }
        }
    }
}

/// The search field, list and key hints of a palette sheet.
struct PaletteView<Item: Identifiable, Row: View>: View {
    let title: String
    /// The shortcut that opens it.
    let keys: String
    let prompt: String
    /// What the list says when nothing matches.
    let empty: String
    /// What Return does to the selection, e.g. "run".
    let verb: String
    let items: [Item]
    let search: (_ items: [Item], _ query: String) -> [Item]
    var isEnabled: (Item) -> Bool = { _ in true }
    /// The item to select first among the shown ones; nil selects the first
    /// enabled one.
    var start: ((_ shown: [Item], _ query: String) -> Item.ID?)?
    /// For VoiceOver.
    let label: (Item) -> String
    let row: (Item) -> Row
    /// Called once, with the picked item or nil.
    let choose: (Item?) -> Void
    @State private var query = ""
    @State private var selection: Item.ID?
    @State private var done = false

    private var shown: [Item] { search(items, query) }

    var body: some View {
        let look = Look.shared
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(keys).font(.system(size: 12)).foregroundStyle(look.secondary)
            }
            .padding(.bottom, 12)
            PickerField(text: $query, prompt: prompt, move: move, submit: submit, cancel: cancel)
                .lookField(isFocused: true, systemImage: "magnifyingglass")
                .padding(.bottom, 14)
            Divider()
            list.padding(.vertical, 6)
            Divider()
            HStack(spacing: 14) {
                Text("↑ ↓ to select")
                Text("↩ to \(verb)")
                Spacer()
                Button("Close", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                Text("⎋")
            }
            .font(.system(size: 11))
            .foregroundStyle(look.secondary)
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: selectFirst)
        .onChange(of: query) { selectFirst() }
    }

    private var list: some View {
        let shown = shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { item in
                        button(item).id(item.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 350)
            .overlay {
                if shown.isEmpty {
                    Text(empty).foregroundStyle(Look.shared.secondary)
                }
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func button(_ item: Item) -> some View {
        let look = Look.shared
        let selected = item.id == selection
        let enabled = isEnabled(item)
        return Button {
            selection = item.id
            submit()
        } label: {
            row(item)
                .padding(.horizontal, 8)
                .frame(height: 44)
                .contentShape(Rectangle())
                .background(selected ? look.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label(item))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectFirst() {
        let shown = shown
        selection = start?(shown, query) ?? shown.first(where: isEnabled)?.id
    }

    private func move(_ delta: Int) {
        let ids = shown.filter(isEnabled).map(\.id)
        guard !ids.isEmpty else { return }
        let at = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[(at + delta + ids.count) % ids.count]
    }

    private func submit() {
        guard !done, let item = shown.first(where: { $0.id == selection && isEnabled($0) }) else { return }
        done = true
        choose(item)
    }

    private func cancel() {
        guard !done else { return }
        done = true
        choose(nil)
    }
}

private struct CommandRow: View {
    let command: PaletteCommand

    var body: some View {
        let look = Look.shared
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(look.accent)
                .opacity(command.isOn ? 1 : 0)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title).font(.system(size: 13)).foregroundStyle(look.text)
                Text(command.category).font(.system(size: 10)).foregroundStyle(look.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if !command.keys.isEmpty {
                Text(command.keys)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(look.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(look.fieldBackground, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .help(command.isEnabled ? command.category : "Unavailable in the current view")
    }
}

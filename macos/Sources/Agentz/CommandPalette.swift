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
    static func collect(from menu: NSMenu, excluding action: Selector) -> [PaletteCommand] {
        func visit(_ menu: NSMenu, path: [String]) -> [PaletteCommand] {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            // Put the application menu's About, Hide and Quit commands last.
            let items = path.isEmpty ? Array(menu.items.dropFirst()) + Array(menu.items.prefix(1)) : menu.items
            return items.flatMap { item -> [PaletteCommand] in
                guard !item.isSeparatorItem, !item.isHidden else { return [] }
                if let submenu = item.submenu {
                    return visit(submenu, path: path + [item.title])
                }
                guard let selector = item.action, selector != action else { return [] }
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
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return commands }
        return commands.enumerated().compactMap { index, command -> (Int, Int, PaletteCommand)? in
            let title = normalized(command.title)
            let category = normalized(command.category)
            var score = 0
            for word in words {
                if title.hasPrefix(word) {
                    continue
                } else if title.contains(word) {
                    score += 1
                } else if category.contains(word) {
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
            return (score, index, command)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map { $0.2 }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// Restore the original responder before dispatching, so Copy, Paste and
/// Find apply to the view the user opened the palette from. A sheet can
/// also belong to the quick terminal or another app window.
@MainActor
final class CommandPalette {
    private(set) var sheet: NSWindow?

    var isShown: Bool { sheet != nil }

    func show(in parent: NSWindow, menu: NSMenu, excluding action: Selector) {
        guard sheet == nil, parent.sheetParent == nil, parent.attachedSheet == nil else { return }
        let commands = PaletteCommand.collect(from: menu, excluding: action)
        let responder = parent.firstResponder
        var chosen: PaletteCommand?
        let host = NSHostingController(rootView: CommandPaletteView(commands: commands) { [weak self, weak parent] command in
            guard let sheet = self?.sheet else { return }
            chosen = command
            parent?.endSheet(sheet)
        }.lookWindowStyle())
        host.sizingOptions = .preferredContentSize
        let sheet = NSPanel(contentViewController: host)
        sheet.title = "All Actions"
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
                if let chosen, !chosen.perform() { NSSound.beep() }
            }
        }
    }
}

private struct CommandPaletteView: View {
    let commands: [PaletteCommand]
    let choose: (PaletteCommand?) -> Void
    @State private var query = ""
    @State private var selection: ObjectIdentifier?
    @State private var done = false

    private var shown: [PaletteCommand] { PaletteSearch.filter(commands, query: query) }

    var body: some View {
        let look = Look.shared
        VStack(spacing: 0) {
            HStack {
                Text("All Actions").font(.headline)
                Spacer()
                Text("⇧⌘P").font(.system(size: 12)).foregroundStyle(look.secondary)
            }
            .padding(.bottom, 12)
            PickerField(text: $query, prompt: "Search commands…", move: move, submit: submit, cancel: cancel)
                .lookField(isFocused: true, systemImage: "magnifyingglass")
                .padding(.bottom, 14)
            Divider()
            list.padding(.vertical, 6)
            Divider()
            HStack(spacing: 14) {
                Text("↑ ↓ to select")
                Text("↩ to run")
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
        .onAppear { selection = shown.first(where: \.isEnabled)?.id }
        .onChange(of: query) { selection = shown.first(where: \.isEnabled)?.id }
    }

    private var list: some View {
        let shown = shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { command in
                        row(command).id(command.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 350)
            .overlay {
                if shown.isEmpty {
                    Text("No matching commands").foregroundStyle(Look.shared.secondary)
                }
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ command: PaletteCommand) -> some View {
        let look = Look.shared
        let selected = command.id == selection
        return Button {
            selection = command.id
            submit()
        } label: {
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
            .padding(.horizontal, 8)
            .frame(height: 44)
            .contentShape(Rectangle())
            .background(selected ? look.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(command.isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!command.isEnabled)
        .accessibilityLabel("\(command.category), \(command.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(command.isEnabled ? command.category : "Unavailable in the current view")
    }

    private func move(_ delta: Int) {
        let ids = shown.filter(\.isEnabled).map(\.id)
        guard !ids.isEmpty else { return }
        let at = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[(at + delta + ids.count) % ids.count]
    }

    private func submit() {
        guard !done, let command = shown.first(where: { $0.id == selection && $0.isEnabled }) else { return }
        done = true
        choose(command)
    }

    private func cancel() {
        guard !done else { return }
        done = true
        choose(nil)
    }
}

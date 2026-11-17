// The menus' shortcuts, as the user set them in Settings › Shortcuts.
// Each menu item keeps the key it was built with as its default; a
// changed one is kept in UserDefaults by the item's action.

import AgentzCore
import AppKit
import Carbon.HIToolbox

/// A menu item's shortcut: its key and modifiers, e.g. ⇧⌘N.
struct KeyCombo: Codable, Hashable {
    /// The menu item's key equivalent, lowercased; empty for none.
    var key: String
    /// ⌘ ⇧ ⌥ ⌃, as `NSEvent.ModifierFlags` raw values.
    var modifiers: UInt

    static let empty = KeyCombo(key: "", modifiers: [])
    static let usedModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// An uppercase key means Shift, as in a menu item.
    init(key: String, modifiers: NSEvent.ModifierFlags) {
        var mods = modifiers.intersection(Self.usedModifiers)
        if key.lowercased() != key { mods.insert(.shift) }
        self.key = key.lowercased()
        self.modifiers = key.isEmpty ? 0 : mods.rawValue
    }

    @MainActor
    init(item: NSMenuItem) {
        self.init(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    /// The keys pressed in `event`, as a menu item takes them: a Shift that
    /// gives another symbol is in the key, like ⌘+ for ⇧⌘=, as in Ghostty.
    /// Nil for a key that types nothing, like a dead key.
    init?(event: NSEvent) {
        var flags = event.modifierFlags.intersection(Self.usedModifiers)
        let key: String
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: key = "\r"
        case kVK_Tab: key = "\t"
        case kVK_Space: key = " "
        case kVK_Delete: key = "\u{8}"
        case kVK_Escape: key = "\u{1b}"
        case kVK_ForwardDelete: key = functionKey(NSDeleteFunctionKey)
        default:
            guard let typed = event.charactersIgnoringModifiers, typed.count == 1 else { return nil }
            key = typed
            let isLetter = typed.lowercased() != typed.uppercased()
            if flags.contains(.shift), !isLetter, let plain = event.characters(byApplyingModifiers: []), plain != typed {
                flags.remove(.shift)
            }
        }
        self.init(key: key, modifiers: flags)
    }

    /// The key that toggles the quick terminal in Ghostty's terms. Nil for
    /// one with no key.
    @MainActor
    init?(trigger: KeyTrigger) {
        let key: String
        if let named = ghosttyKeys.first(where: { $0.names.contains(trigger.key) }) {
            key = named.key
        } else if trigger.key.hasPrefix("f"), let n = Int(trigger.key.dropFirst()), (1 ... 20).contains(n) {
            key = functionKey(NSF1FunctionKey + n - 1)
        } else if let typed = HotKey.menuKey(trigger) {
            key = typed
        } else {
            return nil
        }
        self.init(key: key, modifiers: menuModifiers(trigger.modifiers))
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isNone: Bool { key.isEmpty }

    /// F1 to F35.
    private var functionKeyNumber: Int? {
        guard key.unicodeScalars.count == 1, let v = key.unicodeScalars.first.map({ Int($0.value) }),
              (NSF1FunctionKey ... NSF35FunctionKey).contains(v)
        else { return nil }
        return v - NSF1FunctionKey + 1
    }

    /// A menu shortcut must not take a key the terminal needs for typing:
    /// it needs ⌘ or ⌃, unless it is a function key.
    var isUsable: Bool {
        !isNone && (flags.contains(.command) || flags.contains(.control) || functionKeyNumber != nil)
    }

    /// As macOS shows it, e.g. ⇧⌘N or ⌃F12; empty for none.
    var text: String {
        guard !isNone else { return "" }
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        if let name = keyNames[key] { return s + name }
        if let n = functionKeyNumber { return s + "F\(n)" }
        return s + key.uppercased()
    }

    /// The same keys as a global key, for Carbon. Nil for none, or a key
    /// it has no name for.
    var trigger: KeyTrigger? {
        guard !isNone else { return nil }
        let name: String
        if let named = ghosttyKeys.first(where: { $0.key == key }) {
            name = named.names[0]
        } else if let n = functionKeyNumber, n <= 20 {
            name = "f\(n)"
        } else if key.count == 1 {
            name = key
        } else {
            return nil
        }
        var mods: KeyTrigger.Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return KeyTrigger(modifiers: mods, key: name, global: true)
    }

    /// A shifted letter goes in as uppercase, like ⇧⌘P as `P` with ⌘:
    /// AppKit matches `p` with ⇧⌘ less reliably.
    @MainActor
    func apply(to item: NSMenuItem) {
        var mask = isNone ? [] : flags
        var key = key
        if mask.contains(.shift), key.lowercased() != key.uppercased() {
            key = key.uppercased()
            mask.remove(.shift)
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }
}

func menuModifiers(_ m: KeyTrigger.Modifiers) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if m.contains(.command) { flags.insert(.command) }
    if m.contains(.shift) { flags.insert(.shift) }
    if m.contains(.option) { flags.insert(.option) }
    if m.contains(.control) { flags.insert(.control) }
    return flags
}

private func functionKey(_ code: Int) -> String {
    String(Character(UnicodeScalar(UInt32(code))!))
}

private let keyNames: [String: String] = [
    "\r": "↩", "\u{3}": "⌤", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7f}": "⌫", "\u{1b}": "⎋",
    functionKey(NSDeleteFunctionKey): "⌦",
    functionKey(NSUpArrowFunctionKey): "↑", functionKey(NSDownArrowFunctionKey): "↓",
    functionKey(NSLeftArrowFunctionKey): "←", functionKey(NSRightArrowFunctionKey): "→",
    functionKey(NSHomeFunctionKey): "↖", functionKey(NSEndFunctionKey): "↘",
    functionKey(NSPageUpFunctionKey): "⇞", functionKey(NSPageDownFunctionKey): "⇟",
]

/// Ghostty's names for keys that type nothing, the one it writes first.
private let ghosttyKeys: [(names: [String], key: String)] = [
    (["space"], " "), (["enter"], "\r"), (["tab"], "\t"), (["escape"], "\u{1b}"),
    (["backspace"], "\u{8}"), (["delete"], functionKey(NSDeleteFunctionKey)),
    (["arrow_up", "up"], functionKey(NSUpArrowFunctionKey)), (["arrow_down", "down"], functionKey(NSDownArrowFunctionKey)),
    (["arrow_left", "left"], functionKey(NSLeftArrowFunctionKey)), (["arrow_right", "right"], functionKey(NSRightArrowFunctionKey)),
    (["home"], functionKey(NSHomeFunctionKey)), (["end"], functionKey(NSEndFunctionKey)),
    (["page_up"], functionKey(NSPageUpFunctionKey)), (["page_down"], functionKey(NSPageDownFunctionKey)),
]

/// Every menu command's shortcut: the one it was built with, or the one
/// the user picked.
@MainActor
@Observable
final class KeyBindings {
    struct Entry: Identifiable {
        /// The item's action, e.g. `newClaude:`, with its tag when several
        /// items share it.
        let id: String
        /// The menu it is in, e.g. "File".
        let menu: String
        let title: String
        let defaultCombo: KeyCombo
        /// The quick terminal's key, which works in every app.
        let isGlobal: Bool
    }

    static let defaultsKey = "keyBindings"
    static let quickTerminalID = "toggleQuickTerminal:"

    /// In menu order.
    let entries: [Entry]
    /// Agentz routes its commands to an explicit target. Standard macOS
    /// commands use the responder chain and stay out of the settings editor.
    /// Keep them in `entries` so their shortcuts still count as conflicts.
    var settingsEntries: [Entry] {
        entries.filter { items[$0.id]?.target != nil && $0.id != "showSettings:" }
    }
    private(set) var overrides: [String: KeyCombo]
    /// What went wrong setting a key up, e.g. macOS refused a global key.
    private(set) var problems: [String: String] = [:]
    /// Runs after a shortcut changes.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private let store: UserDefaults?
    @ObservationIgnored private var items: [String: NSMenuItem] = [:]
    /// Hidden items that give another key to a listed one, like ⌘= for
    /// Increase Font Size, by that one's id.
    @ObservationIgnored private var aliases: [(item: NSMenuItem, of: String, combo: KeyCombo)] = []

    /// Takes the shortcuts `menu` has now as the defaults, then puts the
    /// ones kept in `store` on its items. Menus that fill themselves, like
    /// View › Theme, are left out. Without `store`, nothing is kept.
    init(menu: NSMenu, store: UserDefaults?) {
        self.store = store
        var found: [(menu: String, item: NSMenuItem)] = []
        var hidden: [NSMenuItem] = []
        func visit(_ menu: NSMenu, top: String?) {
            for item in menu.items where !item.isSeparatorItem {
                if let submenu = item.submenu {
                    if submenu.delegate == nil { visit(submenu, top: top ?? item.title) }
                } else if let top, item.action != nil {
                    if item.isHidden { hidden.append(item) } else { found.append((top, item)) }
                }
            }
        }
        visit(menu, top: nil)

        var uses: [Selector: Int] = [:]
        for (_, item) in found { uses[item.action!, default: 0] += 1 }
        var entries: [Entry] = []
        var items: [String: NSMenuItem] = [:]
        for (menu, item) in found {
            let action = item.action!
            var id = NSStringFromSelector(action)
            if uses[action]! > 1 { id += "#\(item.tag)" }
            guard items[id] == nil else { continue }
            items[id] = item
            entries.append(Entry(id: id, menu: menu, title: item.title, defaultCombo: KeyCombo(item: item),
                                 isGlobal: id == Self.quickTerminalID))
        }
        self.entries = entries
        self.items = items
        aliases = hidden.compactMap { item in
            entries.first { items[$0.id]?.action == item.action }.map { (item, $0.id, KeyCombo(item: item)) }
        }

        let kept = store?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) } ?? [:]
        overrides = kept.filter { items[$0.key] != nil }
        apply()
    }

    func combo(_ id: String) -> KeyCombo {
        overrides[id] ?? entry(id)?.defaultCombo ?? .empty
    }

    func isChanged(_ id: String) -> Bool { overrides[id] != nil }

    /// Gives `id` the shortcut `combo`, or its default when nil.
    func set(_ id: String, _ combo: KeyCombo?) {
        guard let entry = entry(id) else { return }
        if let combo, combo != entry.defaultCombo {
            overrides[id] = combo
        } else {
            overrides[id] = nil
        }
        changed()
    }

    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        changed()
    }

    /// Another command with the same shortcut, e.g. "Same as View › Go to
    /// Terminal". The menus then take the first one.
    func conflict(_ id: String) -> String? {
        let mine = combo(id)
        guard !mine.isNone else { return nil }
        return entries.first { $0.id != id && combo($0.id) == mine }.map { "Same as \($0.menu) › \($0.title)" }
    }

    func setProblem(_ id: String, _ problem: String?) {
        if problems[id] != problem { problems[id] = problem }
    }

    private func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    private func changed() {
        save()
        apply()
        onChange()
    }

    private func save() {
        guard let store else { return }
        if overrides.isEmpty {
            store.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            store.set(data, forKey: Self.defaultsKey)
        }
    }

    /// An alias goes quiet once its command has another key, or its key
    /// was given to another command.
    private func apply() {
        for entry in entries { items[entry.id].map { combo(entry.id).apply(to: $0) } }
        let taken = Set(overrides.values)
        for alias in aliases {
            let quiet = overrides[alias.of] != nil || taken.contains(alias.combo)
            (quiet ? KeyCombo.empty : alias.combo).apply(to: alias.item)
        }
    }
}

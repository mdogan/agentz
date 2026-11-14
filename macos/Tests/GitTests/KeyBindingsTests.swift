import AgentzCore
import AppKit
import Testing
@testable import agentz

@MainActor
struct KeyBindingsTests {
    @Test
    func comboReadsMenuItemsLikeMacOS() {
        let shifted = NSMenuItem(title: "New Codex", action: nil, keyEquivalent: "N")
        #expect(KeyCombo(item: shifted) == KeyCombo(key: "n", modifiers: [.command, .shift]))
        #expect(KeyCombo(item: shifted).text == "⇧⌘N")
        let option = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "c")
        option.keyEquivalentModifierMask = [.command, .option]
        #expect(KeyCombo(item: option).text == "⌥⌘C")
        #expect(KeyCombo(item: NSMenuItem(title: "Pin", action: nil, keyEquivalent: "")).isNone)
        #expect(KeyCombo(key: "+", modifiers: .command).text == "⌘+")
        let f12 = String(Character(UnicodeScalar(UInt32(NSF12FunctionKey))!))
        #expect(KeyCombo(key: f12, modifiers: .control).text == "⌃F12")
        #expect(KeyCombo(key: "\r", modifiers: .command).text == "⌘↩")
    }

    @Test
    func onlyKeysTheTerminalDoesNotNeedAreUsable() {
        #expect(KeyCombo(key: "k", modifiers: .command).isUsable)
        #expect(KeyCombo(key: "k", modifiers: .control).isUsable)
        #expect(!KeyCombo(key: "k", modifiers: []).isUsable)
        #expect(!KeyCombo(key: "k", modifiers: .shift).isUsable)
        #expect(!KeyCombo(key: "k", modifiers: .option).isUsable)
        let f5 = String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!))
        #expect(KeyCombo(key: f5, modifiers: []).isUsable)
        #expect(!KeyCombo.empty.isUsable)
    }

    @Test
    func globalKeysGoBothWays() throws {
        let trigger = try #require(KeyTrigger("global:ctrl+f12"))
        let combo = try #require(KeyCombo(trigger: trigger))
        #expect(combo.text == "⌃F12")
        #expect(combo.trigger == trigger)
        let spaceTrigger = try #require(KeyTrigger("global:super+shift+space"))
        let space = try #require(KeyCombo(trigger: spaceTrigger))
        #expect(space.text == "⇧⌘Space")
        #expect(space.trigger?.description == "shift+super+space")
        #expect(KeyCombo(key: "t", modifiers: [.control, .option]).trigger?.description == "ctrl+alt+t")
        #expect(KeyCombo.empty.trigger == nil)
    }

    @Test
    func changesApplyToTheMenuAndAreKept() throws {
        let target = BindingsTestTarget()
        let (menu, items) = testMenu(target)
        let store = try #require(UserDefaults(suiteName: "agentz.tests.keyBindings.\(UUID())"))
        let bindings = KeyBindings(menu: menu, store: store)

        // The dynamic Theme menu and section headers stay out; the hidden
        // ⌘= alias is not listed.
        #expect(bindings.entries.map(\.title) == ["New Claude", "Pin", "Increase", "Today", "All"])
        #expect(bindings.entries.map(\.menu) == ["File", "File", "View", "View", "View"])
        #expect(bindings.entries.map(\.id).contains("range:#1"))

        bindings.set("newClaude:", KeyCombo(key: "k", modifiers: [.command, .shift]))
        #expect(items.claude.keyEquivalent == "K")
        #expect(items.claude.keyEquivalentModifierMask == [.command])
        bindings.set("pin:", KeyCombo(key: "p", modifiers: [.control]))
        #expect(shortcut(items.pin) == "⌃P")

        // Removing a key keeps the removal.
        bindings.set("bigger:", .empty)
        #expect(items.bigger.keyEquivalent.isEmpty)
        #expect(items.alias.keyEquivalent.isEmpty)

        let again = KeyBindings(menu: testMenu(target).menu, store: store)
        #expect(again.combo("newClaude:").text == "⇧⌘K")
        #expect(again.combo("pin:").text == "⌃P")
        #expect(again.combo("bigger:").isNone)

        bindings.set("newClaude:", nil)
        #expect(items.claude.keyEquivalent == "n")
        #expect(!bindings.isChanged("newClaude:"))
        bindings.resetAll()
        #expect(bindings.overrides.isEmpty)
        #expect(items.alias.keyEquivalent == "=")
        #expect(store.data(forKey: KeyBindings.defaultsKey) == nil)
    }

    @Test
    func sameKeysAreFlaggedAndTakeTheAliasesKey() {
        let target = BindingsTestTarget()
        let (menu, items) = testMenu(target)
        let bindings = KeyBindings(menu: menu, store: nil)
        #expect(bindings.conflict("pin:") == nil)
        bindings.set("pin:", KeyCombo(key: "n", modifiers: .command))
        #expect(bindings.conflict("pin:") == "Same as File › New Claude")
        #expect(bindings.conflict("newClaude:") == "Same as File › Pin")
        // A key the hidden alias had goes to the command it was given to.
        bindings.set("range:#1", KeyCombo(key: "=", modifiers: .command))
        #expect(items.alias.keyEquivalent.isEmpty)
        #expect(items.bigger.keyEquivalent == "+")
        withExtendedLifetime(target) {}
    }

    private func testMenu(_ target: BindingsTestTarget)
        -> (menu: NSMenu, (claude: NSMenuItem, pin: NSMenuItem, bigger: NSMenuItem, alias: NSMenuItem))
    {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        let file = submenu("File")
        let claude = add(file, "New Claude", #selector(BindingsTestTarget.newClaude(_:)), "n")
        file.addItem(.separator())
        let pin = add(file, "Pin", #selector(BindingsTestTarget.pin(_:)))
        let view = submenu("View")
        let bigger = add(view, "Increase", #selector(BindingsTestTarget.bigger(_:)), "+")
        let alias = add(view, "Increase", #selector(BindingsTestTarget.bigger(_:)), "=")
        alias.isHidden = true
        alias.allowsKeyEquivalentWhenHidden = true
        add(view, "Today", #selector(BindingsTestTarget.range(_:))).tag = 1
        add(view, "All", #selector(BindingsTestTarget.range(_:)), "I").tag = 2
        let theme = NSMenu(title: "Theme")
        theme.delegate = target
        view.addItem(withTitle: "Theme", action: nil, keyEquivalent: "").submenu = theme
        _ = add(theme, "Dracula", #selector(BindingsTestTarget.pin(_:)))
        return (main, (claude, pin, bigger, alias))
    }
}

@MainActor
private final class BindingsTestTarget: NSObject, NSMenuDelegate {
    @objc func newClaude(_: Any?) {}
    @objc func pin(_: Any?) {}
    @objc func bigger(_: Any?) {}
    @objc func range(_: Any?) {}
}

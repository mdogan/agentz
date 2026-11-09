import AppKit
import Testing
@testable import agentz

@MainActor
struct CommandPaletteTests {
    @Test
    func collectsNestedAndDynamicMenusWithShortcutsAndAvailability() {
        _ = NSApplication.shared
        let target = PaletteTestTarget()
        let menu = NSMenu()
        let view = NSMenu(title: "View")
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = view
        menu.addItem(viewItem)

        let split = item("Split Right", key: "d", target: target)
        view.addItem(split)
        let hidden = item("Hidden Alias", target: target)
        hidden.isHidden = true
        view.addItem(hidden)
        view.addItem(.separator())
        let palette = NSMenuItem(title: "All Actions…", action: #selector(PaletteTestTarget.palette(_:)), keyEquivalent: "P")
        palette.target = target
        view.addItem(palette)

        let themes = NSMenu(title: "Theme")
        let themesItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themesItem.submenu = themes
        view.addItem(themesItem)
        themes.delegate = target

        let disabled = item("Unavailable", target: target)
        disabled.tag = -1
        view.addItem(disabled)
        let commands = PaletteCommand.collect(from: menu, excluding: #selector(PaletteTestTarget.palette(_:)))

        #expect(commands.map(\.title) == ["Split Right", "Sample Theme", "Unavailable"])
        #expect(commands[0].category == "View")
        #expect(commands[0].keys == "⌘D")
        #expect(commands[1].category == "View › Theme")
        #expect(commands[1].keys.isEmpty)
        #expect(commands[1].isOn)
        #expect(!commands[2].isEnabled)
        #expect(commands[0].item === split)
    }

    @Test
    func searchesWordsAndMenuPathsAndRanksTitleBeforeFuzzyMatches() {
        let target = PaletteTestTarget()
        let commands = [
            PaletteCommand(item: item("Switch Branch…", target: target), category: "Git"),
            PaletteCommand(item: item("Split Right", target: target), category: "View"),
            PaletteCommand(item: item("Café", target: target), category: "View › Theme"),
            PaletteCommand(item: item("Git Command Log", target: target), category: "Git"),
        ]
        #expect(PaletteSearch.filter(commands, query: " \n ").map(\.id) == commands.map(\.id))
        #expect(PaletteSearch.filter(commands, query: "  GIT branch ").map(\.title) == ["Switch Branch…"])
        #expect(PaletteSearch.filter(commands, query: "splr").map(\.title) == ["Split Right"])
        #expect(PaletteSearch.filter(commands, query: "theme cafe").map(\.title) == ["Café"])
        #expect(PaletteSearch.filter(commands, query: "git").map(\.title) == ["Git Command Log", "Switch Branch…"])
        #expect(PaletteSearch.filter(commands, query: "nothing matches").isEmpty)
    }

    @Test
    func keepsShortcutModifiersAndMenuSenderAndRevalidatesBeforeRunning() {
        _ = NSApplication.shared
        let target = PaletteTestTarget()
        let menu = NSMenu()
        let commandItem = item("Choose Theme", key: "P", target: target)
        commandItem.keyEquivalentModifierMask = [.command, .option, .control]
        commandItem.tag = 4
        commandItem.representedObject = "Sample Theme"
        menu.addItem(commandItem)
        let command = PaletteCommand(item: commandItem, category: "View › Theme")
        #expect(command.keys == "⌃⌥⇧⌘P")
        #expect(command.perform())
        #expect(target.received === commandItem)
        #expect(target.received?.tag == 4)
        #expect(target.received?.representedObject as? String == "Sample Theme")

        target.received = nil
        target.enabled = false
        #expect(!command.perform())
        #expect(target.received == nil)
    }

    private func item(_ title: String, key: String = "", target: PaletteTestTarget) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(PaletteTestTarget.run(_:)), keyEquivalent: key)
        item.target = target
        return item
    }
}

@MainActor
private final class PaletteTestTarget: NSObject, NSMenuItemValidation, NSMenuDelegate {
    var enabled = true
    var received: NSMenuItem?

    @objc func run(_ sender: NSMenuItem) { received = sender }
    @objc func palette(_: NSMenuItem) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool { enabled && item.tag != -1 }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = NSMenuItem(title: "Sample Theme", action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.state = .on
        menu.addItem(item)
    }
}


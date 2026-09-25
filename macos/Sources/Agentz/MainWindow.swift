import AgentzCore
import AppKit
import SwiftUI

/// The window: sessions on the left, the shown terminal on the right.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let workspace: Workspace
    let look: Look
    let sidebarFocus = SidebarFocus()
    private let pane: PaneViewController
    private let split = NSSplitViewController()

    init(workspace: Workspace, look: Look, actions: SidebarActions) {
        self.workspace = workspace
        self.look = look
        pane = PaneViewController(workspace: workspace, look: look)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 700, height: 400)
        window.tabbingMode = .disallowed
        // The terminal's background shows through, like Ghostty's
        // transparent title bar.
        window.titlebarAppearsTransparent = true
        super.init(window: window)

        let sidebar = NSHostingController(rootView: SidebarView(workspace: workspace, look: look, focus: sidebarFocus, actions: actions))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 520
        sidebarItem.canCollapse = true
        let paneItem = NSSplitViewItem(viewController: pane)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(paneItem)
        split.splitView.autosaveName = "agentz.split"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.center()
        window.setFrameAutosaveName("agentz.main")
        window.delegate = self

        workspace.onLayout = { [weak self] in self?.layout() }
        workspace.onTick = { [weak self] in self?.updateTitle() }
        workspace.focusTerminal = { [weak self] in self?.focusTerminal() }
        workspace.isWindowFocused = { [weak window] in NSApp.isActive && window?.isKeyWindow == true }
        layout()
        restyle()
    }

    /// Follows the terminal colors, which change with the system appearance.
    private func restyle() {
        withObservationTracking { [weak self] in
            if let self, let window { look.style(window) }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.restyle() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func layout() {
        pane.sync()
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }
        let title: String, subtitle: String
        if let r = workspace.currentTab {
            // A shell running an agent shows that agent's session.
            let row = workspace.rows.first { r.shows($0.key) }
            title = row?.title ?? r.title
            subtitle = "\((row?.key ?? r.key).agent.name) · \(tilde(row?.cwd ?? r.cwd))"
        } else {
            title = "Agentz"
            subtitle = tilde(workspace.projectDir)
        }
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
        // Sessions that finished while the user was away.
        let waiting = workspace.waitingKeys.count
        let badge = waiting > 0 ? String(waiting) : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
    }

    func focusTerminal() {
        pane.sync()
        workspace.currentTab?.terminal.focus()
    }

    func focusSidebar(_ target: SidebarFocus.Target) {
        if split.splitViewItems.first?.isCollapsed == true {
            split.toggleSidebar(nil)
        }
        sidebarFocus.request(target)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        split.toggleSidebar(sender)
    }
}

/// Holds every terminal view, so hidden ones keep their size and keep
/// running. Only the current one is visible.
@MainActor
final class PaneViewController: NSViewController {
    private let workspace: Workspace
    private let container = NSView()
    private let placeholder: NSHostingView<EmptyPaneView>

    init(workspace: Workspace, look: Look) {
        self.workspace = workspace
        placeholder = NSHostingView(rootView: EmptyPaneView(workspace: workspace, look: look))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])
        placeholder.frame = container.bounds
        placeholder.autoresizingMask = [.width, .height]
        container.addSubview(placeholder)
        view = root
    }

    /// Makes the views match the workspace's tabs and shows the current one.
    func sync() {
        _ = view
        let tabs = workspace.tabs
        let current = workspace.currentTab
        let live = Set(tabs.map { ObjectIdentifier($0.terminal.view) })
        for sub in container.subviews where sub !== placeholder && !live.contains(ObjectIdentifier(sub)) {
            if view.window?.firstResponder === sub { view.window?.makeFirstResponder(nil) }
            sub.removeFromSuperview()
        }
        for tab in tabs where tab.terminal.view.superview !== container {
            tab.terminal.view.frame = container.bounds
            container.addSubview(tab.terminal.view)
        }
        for tab in tabs {
            tab.terminal.setVisible(tab === current)
        }
        placeholder.isHidden = current != nil
    }
}

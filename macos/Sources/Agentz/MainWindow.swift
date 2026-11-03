import AgentzCore
import AppKit
import SwiftUI

/// The window: sessions on the left, the shown terminal or git tab in the
/// middle, and the Changes panel on the right while it is shown.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let workspace: Workspace
    let look: Look
    let sidebarFocus: SidebarFocus
    private let pane: PaneViewController
    private let split = NSSplitViewController()
    private let sidebar: NSHostingController<SidebarView>
    private let sidebarItem: NSSplitViewItem
    /// The Changes panel's state: the shown session's repository.
    let git: GitPanelModel
    /// The Changes panel's place in the split; collapsed while hidden.
    private let gitItem: NSSplitViewItem
    private var gitObservation: NSKeyValueObservation?
    /// The list over the terminal, in auto-hide mode.
    let overlay = SidebarOverlay()
    /// The buttons at the right end of the title bar. Their width changes
    /// with the number of sessions that want the user, which they show.
    private var titleButtons: NSView?
    private var titleButtonsCount = 0
    /// The list is out of the split, and shows over the terminal when
    /// wanted.
    private(set) var autoHide = false

    init(workspace: Workspace, look: Look, actions: SidebarActions, autoHide: Bool) {
        self.workspace = workspace
        self.look = look
        let focus = SidebarFocus()
        sidebarFocus = focus
        pane = PaneViewController(workspace: workspace, look: look)
        sidebar = NSHostingController(rootView: SidebarView(workspace: workspace, look: look, focus: focus, actions: actions))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        let git = GitPanelModel()
        self.git = git
        // Opening a worktree in the panel starts a session there.
        git.store.startSession = { [weak workspace] agent, folder in
            workspace?.newSession(agent, cwd: folder.path)
        }
        git.store.agentsWorking = { [weak workspace] root in
            workspace?.agentsWorking(in: root.path) ?? []
        }
        let gitView = NSHostingController(rootView: GitPanel(model: git, look: look) { [weak workspace, weak git] change in
            if let root = git?.store.repositoryURL { workspace?.openGit(root.path, showing: change) }
        })
        // The width it has when first shown; later, the one it had.
        gitView.view.frame.size.width = Self.gitWidth
        gitItem = NSSplitViewItem(inspectorWithViewController: gitView)
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

        sidebarItem.minimumThickness = Self.listWidths.lowerBound
        sidebarItem.maximumThickness = Self.listWidths.upperBound
        sidebarItem.canCollapse = true
        if autoHide {
            self.autoHide = true
            moveListToOverlay()
        } else {
            split.addSplitViewItem(sidebarItem)
        }
        split.addSplitViewItem(NSSplitViewItem(viewController: pane))
        gitItem.minimumThickness = Self.gitWidths.lowerBound
        gitItem.maximumThickness = Self.gitWidths.upperBound
        gitItem.canCollapse = true
        split.addSplitViewItem(gitItem)
        if !autoHide { split.splitView.autosaveName = Self.splitName }
        // After the split's saved layout, which may say otherwise.
        gitWanted = SmokeTest.logPath == nil && UserDefaults.standard.bool(forKey: Self.gitShownKey)
        gitItem.isCollapsed = !gitWanted
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.center()
        window.setFrameAutosaveName("agentz.main")
        window.delegate = self

        // The split buttons, at the right end of the title bar.
        let buttons = NSHostingView(rootView: SplitButtons(workspace: workspace, look: look, git: git) { [weak self] in
            self?.toggleGit()
        })
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        buttons.frame.size = NSSize(width: buttons.fittingSize.width, height: titlebarHeight)
        titleButtons = buttons
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = buttons
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

        workspace.onLayout = { [weak self] in self?.layout() }
        workspace.onTick = { [weak self] in
            self?.updateTitle()
            self?.followGit()
        }
        workspace.focusTerminal = { [weak self] in self?.focusTerminal() }
        workspace.isUserPresent = { [weak window] in
            NSApp.isActive && window?.isKeyWindow == true && userIdleTime() < Workspace.awayAfter
        }
        overlay.onHide = { [weak self] hadFocus in
            if hadFocus { self?.leaveList() }
        }
        // Dragging a session out of the list, to drop it on a pane.
        pane.onSessionDrag = { [weak self] in self?.overlay.hide() }
        // Hidden by dragging its edge, too.
        gitObservation = gitItem.observe(\.isCollapsed) { [weak self] item, _ in
            MainActor.assumeIsolated { self?.gitCollapsed(item.isCollapsed) }
        }
        updateGitPanel()
        // Nothing is read for the panel while the window can't be seen.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let visible = window.occlusionState.contains(.visible)
                git.setWindowVisible(visible)
                for tab in workspace.tabs { tab.git?.setWindowVisible(visible) }
            }
        }
        layout()
        restyle()
    }

    /// Follows the terminal colors, which change with the system appearance.
    private func restyle() {
        withObservationTracking { [weak self] in
            if let self, let window {
                look.style(window)
                overlay.panel.lineColor = NSColor(look.divider)
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.restyle() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func layout() {
        pane.sync()
        updateTitle()
        updateGitPanel()
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
        // Sessions that finished, ask something or quit while the user was
        // away, also those the list's filters hide.
        let waiting = workspace.attentionKeys.count
        let badge = waiting > 0 ? String(waiting) : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        if let buttons = titleButtons, waiting != titleButtonsCount {
            titleButtonsCount = waiting
            // SwiftUI redraws the buttons on the next pass; measure after it.
            DispatchQueue.main.async { buttons.frame.size.width = buttons.fittingSize.width }
        }
    }

    func focusTerminal() {
        pane.sync()
        if let tab = workspace.currentTab {
            // A list shown from the keyboard is done with.
            if overlay.held { overlay.hide() }
            tab.content.focus()
        } else {
            // An empty pane: the list picks what it shows.
            focusSidebar(.list)
        }
    }

    /// The shown session's find bar, with the keyboard.
    func showFind() {
        guard let tab = workspace.currentTab else { return }
        // A list shown from the keyboard is done with.
        if overlay.held { overlay.hide() }
        tab.terminal?.showFind()
    }

    /// Shows `content` in a sheet over the window, in the theme's colors. It
    /// gets a function that closes the sheet.
    func showSheet<Content: View>(_ content: (_ close: @escaping () -> Void) -> Content) {
        guard let parent = window?.contentViewController else { return }
        weak var sheet: NSViewController?
        let host = NSHostingController(rootView: content { sheet?.dismiss(nil) }.lookWindowStyle())
        host.sizingOptions = .preferredContentSize
        sheet = host
        parent.presentAsSheet(host)
    }

    func focusSidebar(_ target: SidebarFocus.Target) {
        if autoHide {
            overlay.show(held: true)
        } else if sidebarItem.isCollapsed {
            split.toggleSidebar(nil)
        }
        sidebarFocus.request(target)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        if !autoHide {
            split.toggleSidebar(sender)
        } else if overlay.isShown {
            overlay.hide()
        } else {
            overlay.show(held: true)
        }
    }

    // MARK: - Git

    private static let gitWidth: CGFloat = 460
    private static let gitWidths: ClosedRange<CGFloat> = 340 ... 1000
    private static let gitShownKey = "gitPanelShown"

    /// The user wants the Changes panel, as kept across launches. It still
    /// hides while a git tab is on screen, which has the changes itself.
    private var gitWanted = false

    var isGitShown: Bool { !gitItem.isCollapsed }

    /// A git tab is on screen, on its own as always: the Changes panel
    /// stays hidden then, and can't be shown.
    var isGitTabShown: Bool { workspace.panes.keys.contains { $0?.agent == .git } }

    /// How wide the Changes panel is on screen: 0 while hidden.
    var gitPanelWidth: CGFloat {
        let view = gitItem.viewController.view
        return view.isHiddenOrHasHiddenAncestor || view.window == nil ? 0 : view.frame.width
    }

    func toggleGit() {
        guard !isGitTabShown else { return }
        setGitShown(!gitWanted)
    }

    /// Shows or hides the Changes panel from now on, and on the next launch.
    func setGitShown(_ shown: Bool) {
        gitWanted = shown
        if SmokeTest.logPath == nil { UserDefaults.standard.set(shown, forKey: Self.gitShownKey) }
        updateGitPanel()
    }

    /// The panel shows when it is wanted and no git tab is on screen. It
    /// shows and hides at once, without an animation: a collapse that a
    /// quick switch to another session cut short ended with the panel
    /// collapsed anyway, which `gitCollapsed` took for the user hiding it.
    private func updateGitPanel() {
        let shown = gitWanted && !isGitTabShown
        if isGitShown != shown { gitItem.isCollapsed = !shown }
        if shown { git.follow(workspace.gitFolder) }
        git.isShown = shown
    }

    /// The panel was collapsed or expanded. Not by `updateGitPanel`, which
    /// expects that: the user dragged its edge.
    private func gitCollapsed(_ collapsed: Bool) {
        guard collapsed != !(gitWanted && !isGitTabShown) else { return }
        if isGitTabShown {
            updateGitPanel()
        } else {
            setGitShown(!collapsed)
        }
    }

    /// The panel shows the changes in the repository of the session on
    /// screen, or of the one picked in the list.
    private func followGit() {
        if git.isShown { git.follow(workspace.gitFolder) }
    }

    // MARK: - Auto-hide

    private static let listWidths: ClosedRange<CGFloat> = 220 ... 520
    /// Where the split keeps the list's width.
    private static let splitName = "agentz.split"
    private static let listWidthKey = "sessionListWidth"

    /// The list's width over the terminal: the width it had in the split.
    private var listWidth: CGFloat {
        get {
            let width = UserDefaults.standard.double(forKey: Self.listWidthKey)
            return width > 0 ? min(max(width, Self.listWidths.lowerBound), Self.listWidths.upperBound) : 260
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.listWidthKey) }
    }

    /// With `on`, the list leaves the split, the terminal takes the whole
    /// window, and the list slides in over it when wanted. Off, the list
    /// is back in the split, shown.
    func setAutoHide(_ on: Bool) {
        guard on != autoHide else { return }
        autoHide = on
        if on {
            let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: sidebar.view) == true
            if !sidebarItem.isCollapsed, sidebar.view.frame.width > 0 { listWidth = sidebar.view.frame.width }
            // The split saves its layout as it changes. Without the list,
            // that would lose the list's width.
            split.splitView.autosaveName = nil
            split.removeSplitViewItem(sidebarItem)
            moveListToOverlay()
            if hadFocus { leaveList() }
        } else {
            let hadFocus = overlay.hasFocus
            overlay.detach()
            sidebar.removeFromParent()
            split.insertSplitViewItem(sidebarItem, at: 0)
            sidebarItem.isCollapsed = false
            split.splitView.layoutSubtreeIfNeeded()
            split.splitView.setPosition(listWidth, ofDividerAt: 0)
            split.splitView.autosaveName = Self.splitName
            if hadFocus { sidebarFocus.request(.list) }
        }
    }

    private func moveListToOverlay() {
        sidebar.removeFromParent()
        pane.addChild(sidebar)
        overlay.attach(sidebar.view, width: listWidth, to: pane.view)
    }

    /// The list hid with the keyboard focus in it: the focus goes to the
    /// terminal, or nowhere on an empty pane, whose Resume button then
    /// takes Return.
    private func leaveList() {
        if let tab = workspace.currentTab {
            tab.content.focus()
        } else {
            window?.makeFirstResponder(nil)
        }
    }
}

/// How long ago the keyboard, mouse or trackpad was last used, in any app.
private func userIdleTime() -> TimeInterval {
    // kCGAnyInputEventType.
    guard let any = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
}

/// The title bar's buttons. The split buttons each do what their View
/// menu item does: split the pane that way, turn the split, or unsplit it.
/// The one for the current split is filled in. The last one shows or hides
/// the Changes panel.
private struct SplitButtons: View {
    let workspace: Workspace
    let look: Look
    let git: GitPanelModel
    let toggleGit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if !workspace.attentionKeys.isEmpty {
                AttentionButton(workspace: workspace, look: look)
                    .padding(.trailing, 6)
            }
            SplitButton(workspace: workspace, look: look, direction: .right)
            SplitButton(workspace: workspace, look: look, direction: .down)
            GitButton(git: git, look: look, blocked: workspace.panes.keys.contains { $0?.agent == .git }, toggle: toggleGit)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }
}

/// How many sessions want the user. A click goes to the next one. In the
/// title bar, so it shows while the list is hidden too.
private struct AttentionButton: View {
    let workspace: Workspace
    let look: Look
    @State private var hovered = false

    var body: some View {
        let count = workspace.attentionKeys.count
        let help = count == 1 ? "A session needs you. Go to it (⇧⌘A)" : "\(count) sessions need you. Go to the next one (⇧⌘A)"
        Button { workspace.showNextAttention() } label: {
            HStack(spacing: 4) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(count == 1 ? "1 needs you" : "\(count) need you")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(look.background)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(look.accent.opacity(hovered ? 0.85 : 1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct GitButton: View {
    let git: GitPanelModel
    let look: Look
    /// A git tab is on screen.
    let blocked: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        let on = git.isShown
        Button(action: toggle) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? look.accent : look.secondary)
                .frame(width: 26, height: 22)
                .background(hovered ? look.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .opacity(blocked ? 0.4 : 1)
        .onHover { hovered = $0 }
        .help(blocked ? "The git tab shows the changes itself" : on ? "Hide Changes (⇧⌘C)" : "Show Changes (⇧⌘C)")
        .accessibilityLabel(on ? "Hide Changes" : "Show Changes")
    }
}

private struct SplitButton: View {
    let workspace: Workspace
    let look: Look
    let direction: SplitDirection
    @State private var hovered = false

    private var on: Bool { workspace.panes.split == direction }
    private var title: String { direction == .right ? "Split Right" : "Split Down" }
    private var keys: String { direction == .right ? "⌘D" : "⇧⌘D" }
    private var icon: String { direction == .right ? "rectangle.split.2x1" : "rectangle.split.1x2" }

    var body: some View {
        Button { workspace.toggleSplit(direction) } label: {
            Image(systemName: on ? icon + ".fill" : icon)
                .font(.system(size: 13))
                .foregroundStyle(on ? look.accent : look.secondary)
                .frame(width: 26, height: 22)
                .background(hovered ? look.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!workspace.canSplit)
        .opacity(workspace.canSplit ? 1 : 0.4)
        .onHover { hovered = $0 }
        .help(!workspace.canSplit ? "A git tab shows on its own" : on ? "Unsplit (\(keys))" : "\(title) (\(keys))")
        .accessibilityLabel(on ? "Unsplit" : title)
    }
}

/// Holds every terminal view, so hidden ones keep their size and keep
/// running. Only the ones in the panes are visible: one, or two after a
/// split, with a line between them.
///
/// The terminal views never move to another parent view; a split only
/// changes their frames.
@MainActor
final class PaneViewController: NSViewController {
    private let workspace: Workspace
    private let look: Look
    private let container = PaneContainer()
    /// The terminal views, under everything else.
    private let terminals = NSView()
    /// One per pane, shown while the pane has no terminal.
    private let placeholders: [PaneHostingView<EmptyPaneView>]
    /// Fades the pane the user does not work in, as Ghostty does.
    private let fade = FadeView()
    private let divider = PaneDivider()
    /// Where the divider is while it is dragged. The split takes it when
    /// the drag ends.
    private var draggedRatio: CGFloat?
    /// A session from the list is dragged over the pane area.
    var onSessionDrag: (() -> Void)?

    init(workspace: Workspace, look: Look) {
        self.workspace = workspace
        self.look = look
        placeholders = [0, 1].map { PaneHostingView(rootView: EmptyPaneView(workspace: workspace, look: look, pane: $0)) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])
        terminals.frame = container.bounds
        terminals.autoresizingMask = [.width, .height]
        container.addSubview(terminals)
        for placeholder in placeholders {
            container.addSubview(placeholder)
        }
        container.addSubview(fade)
        container.addSubview(divider)
        container.addSubview(container.highlight)
        divider.onDrag = { [weak self] point in self?.moveDivider(to: point) }
        divider.onDragEnd = { [weak self] in
            guard let self, let ratio = draggedRatio else { return }
            draggedRatio = nil
            workspace.setRatio(ratio)
        }
        divider.onReset = { [weak self] in self?.workspace.setRatio(0.5) }
        container.target = { [weak self] key, point in self?.dropTarget(key, at: point)?.frame }
        container.drop = { [weak self] key, point in self?.drop(key, at: point) }
        container.entered = { [weak self] in self?.onSessionDrag?() }
        view = root
        restyle()
    }

    /// Where a session dragged from the list to `point` would go. With one
    /// pane, to the edge it is nearest, splitting the pane that way; on an
    /// empty pane, there. In a split, to the pane under it. Nil where it
    /// would not change anything.
    private func dropTarget(_ key: SessionKey, at point: NSPoint) -> (frame: NSRect, pane: Int, direction: SplitDirection?)? {
        let layout = workspace.panes
        let b = container.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        if let split = layout.split {
            // A git tab never goes into a split.
            guard workspace.canOpenInSplit(key) else { return nil }
            let rects = paneRects(split, ratio: layout.ratio)
            guard let i = rects.firstIndex(where: { $0.contains(point) }) else { return nil }
            if workspace.tabs.first(where: { $0.key == layout.keys[i] })?.shows(key) == true { return nil }
            return (rects[i], i, split)
        }
        guard workspace.current != nil else { return (b, 0, nil) }
        // Not the shown session itself, a git tab, or any next to one.
        guard workspace.canOpenInSplit(key) else { return nil }
        let fromLeft = point.x / b.width, fromTop = (b.height - point.y) / b.height
        let edges: [(distance: CGFloat, direction: SplitDirection, pane: Int)] = [
            (fromLeft, .right, 0), (1 - fromLeft, .right, 1), (fromTop, .down, 0), (1 - fromTop, .down, 1),
        ]
        let edge = edges.min { $0.distance < $1.distance }!
        // A new split starts even.
        return (paneRects(edge.direction, ratio: 0.5)[edge.pane], edge.pane, edge.direction)
    }

    private func drop(_ key: SessionKey, at point: NSPoint) {
        guard let target = dropTarget(key, at: point) else { return }
        if let direction = target.direction {
            workspace.openInSplit(key, direction, pane: target.pane)
        } else {
            workspace.selection = key
            workspace.open(key)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutPanes()
    }

    /// Makes the views match the workspace's tabs and shows the ones in the
    /// panes.
    func sync() {
        _ = view
        let tabs = workspace.tabs
        let layout = workspace.panes
        let live = Set(tabs.map { ObjectIdentifier($0.content.paneView) })
        for sub in terminals.subviews where !live.contains(ObjectIdentifier(sub)) {
            if (view.window?.firstResponder as? NSView)?.isDescendant(of: sub) == true { view.window?.makeFirstResponder(nil) }
            sub.removeFromSuperview()
        }
        let rects = paneRects(layout.split, ratio: layout.ratio)
        for tab in tabs {
            let v = tab.content.paneView
            let pane = layout.keys.firstIndex(of: tab.key)
            if v.superview !== terminals {
                // At its pane's size from the start, so the program does
                // not start at one size and get resized right away.
                v.frame = pane.map { rects[$0] } ?? terminals.bounds
                terminals.addSubview(v)
            }
            // A hidden first responder hands the keyboard to the next view
            // on screen, which may be the other pane's terminal. Its find
            // bar's field too.
            if pane == nil, tab.content.isFocused { view.window?.makeFirstResponder(nil) }
            tab.content.setVisible(pane != nil)
        }
        layoutPanes()
    }

    /// Puts the shown terminals, the placeholders, the divider and the fade
    /// where the panes are.
    private func layoutPanes() {
        let layout = workspace.panes
        let rects = paneRects(layout.split, ratio: draggedRatio ?? layout.ratio)
        var empty = Set(layout.keys.indices)
        for (i, key) in layout.keys.enumerated() {
            guard let v = workspace.tabs.first(where: { $0.key == key })?.content.paneView else { continue }
            empty.remove(i)
            if v.frame != rects[i] { v.frame = rects[i] }
        }
        for (i, placeholder) in placeholders.enumerated() {
            placeholder.isHidden = !empty.contains(i)
            if !placeholder.isHidden, placeholder.frame != rects[i] { placeholder.frame = rects[i] }
        }
        guard let split = layout.split else {
            divider.isHidden = true
            fade.isHidden = true
            return
        }
        divider.isHidden = false
        divider.vertical = split == .right
        // The line is in the middle of the divider, which is wider so it is
        // easy to grab.
        let grab: CGFloat = 3, line = PaneDivider.thickness(split)
        divider.frame = switch split {
        case .right: NSRect(x: rects[0].maxX - grab, y: 0, width: line + 2 * grab, height: container.bounds.height)
        case .down: NSRect(x: 0, y: rects[1].maxY - grab, width: container.bounds.width, height: line + 2 * grab)
        }
        fade.isHidden = false
        fade.frame = rects[1 - layout.focused]
    }

    /// Each pane's frame, left or top first, with the divider's line
    /// between two. `ratio` is the first pane's share.
    private func paneRects(_ split: SplitDirection?, ratio: CGFloat) -> [NSRect] {
        let b = container.bounds
        let line = split.map(PaneDivider.thickness) ?? 0
        switch split {
        case nil:
            return [b]
        case .right:
            let first = ((b.width - line) * ratio).rounded()
            return [
                NSRect(x: 0, y: 0, width: first, height: b.height),
                NSRect(x: first + line, y: 0, width: max(b.width - first - line, 0), height: b.height),
            ]
        case .down:
            let first = ((b.height - line) * ratio).rounded()
            return [
                NSRect(x: 0, y: b.height - first, width: b.width, height: first),
                NSRect(x: 0, y: 0, width: b.width, height: max(b.height - first - line, 0)),
            ]
        }
    }

    /// `point` is where the divider was dragged to, in the container.
    private func moveDivider(to point: NSPoint) {
        let b = container.bounds
        guard b.width > 0, b.height > 0 else { return }
        let ratio: CGFloat
        switch workspace.panes.split {
        case .right: ratio = point.x / b.width
        case .down: ratio = (b.height - point.y) / b.height
        case nil: return
        }
        draggedRatio = min(max(ratio, 0.15), 0.85)
        layoutPanes()
    }

    /// The divider and the fade follow the theme and the Ghostty config.
    private func restyle() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            let colors = look.colors
            let splitLook = GhosttyApp.splitLook
            divider.color = NSColor(splitLook.divider ?? colors.background.mixed(with: colors.foreground, 0.15))
            divider.thickColor = NSColor(splitLook.divider ?? colors.background.mixed(with: colors.foreground, 0.35))
            fade.color = NSColor(splitLook.unfocusedFill ?? colors.background).withAlphaComponent(1 - splitLook.unfocusedOpacity)
            container.highlight.color = NSColor(look.accent)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.restyle() }
        }
    }
}

/// A session dragged from the list to the pane area. Its own type, so a
/// terminal does not take it as text to type.
enum SessionDrag {
    static let type = NSPasteboard.PasteboardType("io.dogan.agentz.session")

    /// What a row of the list hands to the drag.
    static func provider(_ key: SessionKey) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(key.description.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    /// The session a drag carries, if it comes from this app's list.
    static func key(of drag: NSDraggingInfo) -> SessionKey? {
        // Another app, or another agentz window, has its own sessions.
        guard drag.draggingSource != nil, let data = drag.draggingPasteboard.data(forType: type) else { return nil }
        return String(data: data, encoding: .utf8).flatMap { SessionKey(parsing: $0) }
    }
}

/// The pane area. Sessions dragged from the list can be dropped on it; a
/// highlight shows where one would go.
final class PaneContainer: NSView {
    /// The frame to highlight for a session dragged to a point, or nil if it
    /// can't be dropped there.
    var target: ((SessionKey, NSPoint) -> NSRect?)?
    var drop: ((SessionKey, NSPoint) -> Void)?
    /// A session came over the pane area.
    var entered: (() -> Void)?
    let highlight = DropHighlight()
    /// The session being dragged over the pane area.
    private var dragged: SessionKey?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([SessionDrag.type])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragged = SessionDrag.key(of: sender)
        if dragged != nil { entered?() }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let key = dragged, let frame = target?(key, point) else {
            highlight.isHidden = true
            return []
        }
        highlight.frame = frame.insetBy(dx: 6, dy: 6)
        highlight.isHidden = false
        let allowed = sender.draggingSourceOperationMask
        return allowed.contains(.move) ? .move : allowed.contains(.copy) ? .copy : .generic
    }

    override func draggingExited(_: NSDraggingInfo?) {
        endDrag()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        guard let key = dragged, target?(key, point) != nil else { return false }
        drop?(key, point)
        return true
    }

    override func draggingEnded(_: NSDraggingInfo) {
        endDrag()
    }

    private func endDrag() {
        dragged = nil
        highlight.isHidden = true
    }
}

/// Where a dragged session would go. Clicks go through.
final class DropHighlight: NSView {
    var color = NSColor.controlAccentColor {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        layer?.borderColor = color.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 8
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// SwiftUI in a pane: a git tab, or what an empty pane shows. SwiftUI's
/// hosting view takes clicks while hidden, and wherever its content
/// reaches, also past its frame when the content is wider than the pane.
/// Lying over the terminals, a hidden git tab took the clicks on the
/// terminal on screen. Sometimes the terminal still got the press of such
/// a click, but never its release, and went on selecting text as the mouse
/// moved. This one takes only clicks in its frame while shown, and draws
/// nothing past its frame.
final class PaneHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // `point` is in the superview's coordinates, like `frame`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : super.hitTest(point)
    }
}

/// A see-through color over a pane. Clicks go through to the terminal.
private final class FadeView: NSView {
    var color = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // The layer may not exist yet when the color is set.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The line between two panes. Dragging it resizes them; a double-click
/// makes them even.
private final class PaneDivider: NSView {
    /// How thick the line is. The one between panes above each other is
    /// thicker, so it stands out from the terminal's own lines.
    static func thickness(_ split: SplitDirection) -> CGFloat {
        split == .down ? 2 : 1
    }

    /// True with the panes side by side, so the line runs up and down.
    var vertical = true {
        didSet {
            guard vertical != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var color = NSColor.separatorColor {
        didSet { needsDisplay = true }
    }

    /// The color of the thicker line, between panes above each other.
    var thickColor = NSColor.separatorColor {
        didSet { needsDisplay = true }
    }

    /// Gets where the mouse is, in the divider's superview.
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private var cursor: NSCursor { vertical ? .resizeLeftRight : .resizeUpDown }

    override func draw(_: NSRect) {
        (vertical ? color : thickColor).setFill()
        let t = Self.thickness(vertical ? .right : .down)
        let line = vertical
            ? NSRect(x: ((bounds.width - t) / 2).rounded(.down), y: 0, width: t, height: bounds.height)
            : NSRect(x: 0, y: ((bounds.height - t) / 2).rounded(.down), width: bounds.width, height: t)
        line.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // The terminals under the divider's edges set their own cursor too.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with _: NSEvent) {
        cursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with _: NSEvent) {
        onDragEnd?()
    }
}

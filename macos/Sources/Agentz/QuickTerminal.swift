import AgentzCore
import AppKit

/// Ghostty's quick terminal: a shell of its own that slides in from an edge
/// of the screen, over any app, and away again. The Ghostty config's
/// `quick-terminal-*` settings say where and how. It is not a session: the
/// list does not show it, and it does not come back after quitting.
@MainActor
final class QuickTerminal: NSObject, NSWindowDelegate {
    let settings: QuickTerminalSettings
    private let look: Look
    private let panel: QuickTerminalPanel
    /// Its shell, started when it first shows, and again after one ended.
    private(set) var terminal: Terminal?
    /// Shown, or on its way in.
    private(set) var isShown = false
    /// The app the user was in when it showed, which gets the keyboard back
    /// when it hides.
    private var previousApp: NSRunningApplication?
    /// Counts the slides, so one that another replaced does not finish.
    private var slides = 0
    /// An alert of its own is up; the panel stays meanwhile.
    private var asking = false

    init(settings: QuickTerminalSettings, look: Look) {
        self.settings = settings
        self.look = look
        // Like Ghostty's: it gets the keyboard without bringing the app's
        // other windows to the front.
        panel = QuickTerminalPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.hasShadow = true
        panel.collectionBehavior = [
            .ignoresCycle, .fullScreenAuxiliary,
            settings.spaceBehavior == .move ? .canJoinAllSpaces : .moveToActiveSpace,
        ]
        // For window managers, as Ghostty does.
        panel.identifier = NSUserInterfaceItemIdentifier("io.dogan.agentz.quickTerminal")
        panel.setAccessibilitySubrole(.floatingWindow)
        restyle()
    }

    /// The user works in it.
    var isKey: Bool {
        isShown && panel.isKeyWindow
    }

    /// On screen, also while it slides.
    var isOnScreen: Bool {
        panel.isVisible
    }

    var frame: NSRect {
        panel.frame
    }

    var screen: NSScreen? {
        panel.screen
    }

    /// Its shell's pid, while it runs.
    var shellPid: Int32? {
        terminal?.pid
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    /// Finds the shell's pid and notices when it exits. Called on every tick.
    func poll() {
        terminal?.poll()
    }

    func show() {
        guard !isShown, let screen = targetScreen() else { return }
        isShown = true
        if !NSApp.isActive, let app = NSWorkspace.shared.frontmostApplication, app != .current {
            previousApp = app
        }
        // Off screen and see-through, then in. Above the menu bar while it
        // slides past it.
        panel.setFrame(settings.hiddenFrame(visible: screen.visibleFrame, frame: screen.frame), display: false)
        panel.alphaValue = 0
        panel.level = .popUpMenu
        if terminal == nil { start() }
        terminal?.setVisible(true)
        panel.makeKeyAndOrderFront(nil)
        terminal?.focus()
        slide(to: settings.shownFrame(visible: screen.visibleFrame), alpha: 1) { [weak self] in
            guard let self else { return }
            // Low enough for input method windows to show over it.
            panel.level = .floating
            terminal?.focus()
            // Only now: activating the app earlier brings another of its
            // windows to the front.
            if !NSApp.isActive { NSApp.activate() }
        }
    }

    /// Slides it away. The app the user was in before gets the keyboard
    /// back; the shell goes on running.
    func hide() {
        guard isShown else { return }
        isShown = false
        if let app = previousApp {
            previousApp = nil
            if !app.isTerminated { app.activate(options: []) }
        }
        let gone = { [weak self] in
            guard let self else { return }
            panel.orderOut(nil)
            terminal?.setVisible(false)
        }
        guard panel.isOnActiveSpace, let screen = panel.screen ?? NSScreen.main else {
            slides += 1
            return gone()
        }
        panel.level = .popUpMenu
        slide(to: settings.hiddenFrame(visible: screen.visibleFrame, frame: screen.frame), alpha: 0, then: gone)
    }

    /// ⌘W: ends the shell, asking first while it runs a command.
    func closeShell() {
        guard let terminal else { return hide() }
        if terminal.hasForegroundJob {
            let alert = NSAlert()
            alert.messageText = "The shell is running a command."
            alert.informativeText = "Closing stops it."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            asking = true
            let answer = alert.runModal()
            asking = false
            guard answer == .alertFirstButtonReturn else { return }
        }
        end()
    }

    /// The shell ended or was closed: it goes, and the next show starts a
    /// new one.
    private func end() {
        guard let terminal else { return }
        self.terminal = nil
        terminal.close()
        terminal.view.removeFromSuperview()
        hide()
    }

    private func start() {
        let launch = Launch.shell()
        let terminal = Terminal(command: launch.command, cwd: NSHomeDirectory(), env: launch.env)
        // At the panel's size from the start, so the shell does not start
        // at one size and get resized right away.
        terminal.view.frame = panel.contentView?.bounds ?? .zero
        terminal.onExit = { [weak self, weak terminal] in
            guard let self, let terminal, self.terminal === terminal else { return }
            end()
        }
        panel.contentView?.addSubview(terminal.view)
        self.terminal = terminal
    }

    /// Moves and fades the panel, then calls `done` unless another slide
    /// started meanwhile.
    private func slide(to frame: NSRect, alpha: CGFloat, then done: @escaping () -> Void) {
        slides += 1
        let slide = slides
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : settings.animationDuration
        guard duration > 0 else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = alpha
            return done()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.slides == slide else { return }
                done()
            }
        }
    }

    private func targetScreen() -> NSScreen? {
        switch settings.screen {
        case .main:
            NSScreen.main
        case .mouse:
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        case .menuBar:
            NSScreen.screens.first
        }
    }

    /// Follows the terminal colors, which change with the system appearance.
    private func restyle() {
        withObservationTracking { [weak self] in
            if let self { look.style(panel) }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.restyle() }
        }
    }

    // MARK: - NSWindowDelegate

    /// The user went to another window, of this app or another, and stays
    /// there. With `quick-terminal-autohide`, the panel slides away.
    func windowDidResignKey(_: Notification) {
        // An alert or a sheet of its own, like asking before a paste,
        // keeps it.
        guard isShown, !asking, panel.attachedSheet == nil else { return }
        previousApp = nil
        if settings.autohide { hide() }
    }
}

/// A borderless window has to say it can take the keyboard.
private final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

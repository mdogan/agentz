import AgentzCore
import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var workspace: Workspace?
    private var windowController: MainWindowController?
    private var scanner: Scanner?
    /// A folder the app was asked to open before it finished launching.
    private var pendingProject: String?
    private var tickTimer: Timer?
    private var keyMonitor: Any?
    private var shortcutsWindow: ShortcutsWindowController?

    // MARK: - Launch

    func application(_: NSApplication, open urls: [URL]) {
        guard let dir = urls.first(where: { isDirectory($0.path) })?.path else { return }
        if workspace != nil {
            open(dir, recent: true)
            windowController?.showWindow(nil)
        } else {
            pendingProject = dir
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Before any terminal starts: they inherit this environment.
        ShellEnvironment.load()
        _ = GhosttyApp.controller
        NSApp.mainMenu = buildMenu()

        var saved: SavedState?
        var problem: String?
        do {
            if SmokeTest.logPath == nil { saved = try takeTabs() }
        } catch {
            saved = nil
            problem = "Could not restore tabs: \(error)"
        }
        let dir = pendingProject
            ?? argumentProject()
            ?? saved?.project
            ?? UserDefaults.standard.string(forKey: "project")
            ?? NSHomeDirectory()
        UserDefaults.standard.set(dir, forKey: "project")

        let workspace = Workspace(projectDir: isDirectory(dir) ? dir : NSHomeDirectory())
        self.workspace = workspace
        if SmokeTest.logPath == nil { remember(workspace.projectDir) }
        let controller = MainWindowController(
            workspace: workspace,
            look: Look(),
            actions: SidebarActions(
                close: { [weak self] key in self?.closeSession(key) },
                start: { [weak self] agent, dir, repo in self?.start(agent, in: dir, repo: repo) },
                chooseFolder: { [weak self] agent in
                    self?.chooseFolder("Start a new \(agent.displayName) session in this folder.", prompt: "Start")
                },
                recentFolders: { UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [] },
                clearRecentFolders: { UserDefaults.standard.removeObject(forKey: Self.recentsKey) },
                notificationSettings: { [weak self] in self?.notificationSettings(nil) }
            )
        )
        windowController = controller
        controller.showWindow(nil)

        workspace.notify = { [weak self] agent, title, message, key in
            self?.notify(agent: agent, title: title, message: message, key: key)
        }
        let scanner = Scanner(workspace)
        self.scanner = scanner
        scanner.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak workspace] _ in
            MainActor.assumeIsolated { workspace?.tick() }
        }
        // Typing into a terminal starts a new turn, so the agent may tell
        // us again when it is done.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak workspace] event in
            let command = event.modifierFlags.contains(.command)
            if !command || event.charactersIgnoringModifiers == "v",
               let view = event.window?.firstResponder as? NSView
            {
                workspace?.userTyped(in: view)
            }
            return event
        }

        if let log = SmokeTest.logPath {
            Task { await SmokeTest(workspace: workspace, logPath: log).run() }
        } else if let saved {
            let failed = workspace.restore(saved)
            do { try saveTabs(failed) } catch { problem = "Could not keep unopened tabs: \(error)" }
        }
        if let issue = GhosttyApp.configIssue {
            problem = "Your Ghostty config was not used: \(issue)"
            NSLog("agentz: %@", problem!)
        }
        if let problem { workspace.setStatus(problem) }
        if workspace.currentTab == nil {
            controller.focusSidebar(.list)
        } else {
            controller.focusTerminal()
        }

        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in self.checkNotifications() }
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkNotifications() }
            }
        }
        NSApp.activate()
    }

    private static let recentsKey = "recentFolders"

    /// Shows the project of `dir`, and opens it there on the next launch.
    /// With `recent`, it goes to the top of the recent folders.
    private func open(_ dir: String, recent: Bool) {
        guard let workspace else { return }
        workspace.openProject(dir)
        UserDefaults.standard.set(workspace.projectDir, forKey: "project")
        if recent { remember(workspace.projectDir) }
    }

    /// Starts a session in `dir`, and makes `repo`, the folder picked from
    /// the recent folders, the most recent one.
    private func start(_ agent: Agent, in dir: String, repo: String) {
        guard let workspace else { return }
        open(dir, recent: false)
        remember(repo)
        workspace.newSession(agent, cwd: dir)
    }

    private func remember(_ dir: String) {
        let recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        UserDefaults.standard.set(addingRecent(dir, to: recents), forKey: Self.recentsKey)
    }

    /// `--project <dir>` or a folder argument, for when the binary runs
    /// itself instead of handing the folder to the app, e.g. `agentz /repo`
    /// with stdin redirected, or outside the app bundle.
    private func argumentProject() -> String? {
        let args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--project"), i + 1 < args.count { return args[i + 1] }
        return args.first { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .flatMap { isDirectory($0) ? $0 : nil }
    }

    /// Notices when the user turned notifications off (or never allowed
    /// them), so the sidebar can say so. Checked again when the app comes
    /// back to the front, e.g. from System Settings.
    private func checkNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let off = settings.authorizationStatus == .denied
            Task { @MainActor in
                if self.workspace?.notificationsOff != off { self.workspace?.notificationsOff = off }
            }
        }
    }

    @objc func notificationSettings(_: Any?) {
        let id = Bundle.main.bundleIdentifier ?? "io.dogan.agentz"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Quit

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace, SmokeTest.logPath == nil else { return .terminateNow }
        let (working, idle, commands) = workspace.quitCounts()
        if working > 0 {
            guard confirm(
                "\(plural(working, "agent is", "agents are")) working.",
                "Quitting stops \(working == 1 ? "it" : "them"). Agents resume from their transcripts next time.",
                button: "Quit Anyway"
            ) else { return .terminateCancel }
        } else if idle + commands > 0 {
            var what: [String] = []
            if idle > 0 { what.append(plural(idle, "idle agent", "idle agents")) }
            if commands > 0 { what.append(plural(commands, "shell running a command", "shells running a command")) }
            guard confirm(
                "Quit and close \(what.joined(separator: " and "))?",
                "Open tabs come back when you start agentz again.",
                button: "Quit"
            ) else { return .terminateCancel }
        }
        do {
            try saveTabs(workspace.savedState())
        } catch {
            guard confirm(
                "Could not save open tabs.",
                "\(error)\n\nIf you quit, they will not come back next time.",
                button: "Quit Anyway"
            ) else { return .terminateCancel }
        }
        return .terminateNow
    }

    private func confirm(_ message: String, _ info: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Actions

    @objc func newClaude(_: Any?) { workspace?.newSession(.claude) }
    @objc func newCodex(_: Any?) { workspace?.newSession(.codex) }
    @objc func newShell(_: Any?) { workspace?.newSession(.shell) }

    @objc func openFolder(_: Any?) {
        guard let dir = chooseFolder("New sessions start in this folder.", prompt: "Open") else { return }
        application(NSApp, open: [URL(fileURLWithPath: dir)])
    }

    private func chooseFolder(_ message: String, prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = prompt
        panel.message = message
        if let dir = workspace?.projectDir { panel.directoryURL = URL(fileURLWithPath: dir) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    @objc func closeCurrent(_: Any?) {
        guard let key = workspace?.currentTab?.key else { return }
        closeSession(key)
    }

    private func closeSession(_ key: SessionKey) {
        guard let workspace, let tab = workspace.tabs.first(where: { $0.shows(key) }) else { return }
        let agent = tab.linked?.agent ?? tab.key.agent
        if tab.isBusy {
            guard confirm("\(agent.displayName) is working.", "Closing stops it.", button: "Close") else { return }
        } else if tab.key.agent == .shell, tab.linked == nil, tab.terminal.hasForegroundJob {
            guard confirm("The shell is running a command.", "Closing stops it.", button: "Close") else { return }
        }
        workspace.close(key)
    }

    @objc func toggleInactive(_: Any?) {
        guard let workspace else { return }
        workspace.hideInactive.toggle()
        workspace.setStatus(workspace.hideInactive ? "Hiding inactive sessions" : "Showing inactive sessions")
    }

    @objc func focusList(_: Any?) { windowController?.focusSidebar(.list) }
    @objc func focusFilter(_: Any?) { windowController?.focusSidebar(.filter) }
    @objc func focusTerminal(_: Any?) { windowController?.focusTerminal() }
    @objc func nextSession(_: Any?) { workspace?.cycle(1) }
    @objc func previousSession(_: Any?) { workspace?.cycle(-1) }
    @objc func toggleSessionList(_ sender: Any?) { windowController?.toggleSidebar(sender) }

    @objc func showShortcuts(_: Any?) {
        guard let menu = NSApp.mainMenu else { return }
        if shortcutsWindow == nil { shortcutsWindow = ShortcutsWindowController(menu: menu) }
        shortcutsWindow?.showWindow(nil)
    }

    @objc func installStatusLine(_: Any?) { configureStatusLine("install") }
    @objc func uninstallStatusLine(_: Any?) { configureStatusLine("uninstall") }

    private func configureStatusLine(_ action: String) {
        let alert = NSAlert()
        do {
            alert.messageText = try AgentzCore.configureStatusLine(action, Bundle.main.executablePath ?? "agentz")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "\(error)"
        }
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let workspace else { return false }
        switch item.action {
        case #selector(toggleInactive(_:)):
            item.state = workspace.hideInactive ? .off : .on
        case #selector(closeCurrent(_:)), #selector(focusTerminal(_:)):
            return workspace.currentTab != nil
        default:
            break
        }
        return true
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Agentz")
        app.addItem(withTitle: "About Agentz", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(app, "Notification Settings…", #selector(notificationSettings(_:)))
        add(app, "Install Claude Status Line", #selector(installStatusLine(_:)))
        add(app, "Uninstall Claude Status Line", #selector(uninstallStatusLine(_:)))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Agentz", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Agentz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        add(file, "New Claude Session", #selector(newClaude(_:)), "n")
        add(file, "New Codex Session", #selector(newCodex(_:)), "N")
        add(file, "New Shell", #selector(newShell(_:)), "t")
        file.addItem(.separator())
        add(file, "Open Folder…", #selector(openFolder(_:)), "o")
        file.addItem(.separator())
        add(file, "Close Session", #selector(closeCurrent(_:)), "w")

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(main, "View")
        add(view, "Inactive Sessions", #selector(toggleInactive(_:)), "I")
        view.addItem(.separator())
        add(view, "Go to Session List", #selector(focusList(_:)), "l")
        add(view, "Go to Terminal", #selector(focusTerminal(_:)), "j")
        add(view, "Filter Sessions", #selector(focusFilter(_:)), "f")
        add(view, "Next Session", #selector(nextSession(_:)), "]")
        add(view, "Previous Session", #selector(previousSession(_:)), "[")
        view.addItem(.separator())
        let sidebar = add(view, "Toggle Session List", #selector(toggleSessionList(_:)), "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        add(help, "Keyboard Shortcuts", #selector(showShortcuts(_:)), "/")
        NSApp.helpMenu = help
        return main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

// MARK: - Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Tells the user that an agent is waiting. `message` is what the agent
    /// itself said, e.g. Codex's last reply.
    private func notify(agent: Agent, title: String, message: String?, key: SessionKey) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agent.displayName) is waiting"
        content.body = message.map { "\(title): \(short($0, 200))" } ?? title
        content.sound = .default
        content.userInfo = ["agent": key.agent.name, "id": key.id]
        // A newer notice about the same session replaces the older one.
        let request = UNNotificationRequest(identifier: key.description, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // We only notify about tabs the user is not looking at.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["agent"] as? String, let agent = Agent(name: raw), let id = info["id"] as? String else {
            return
        }
        await MainActor.run {
            NSApp.activate()
            self.windowController?.showWindow(nil)
            self.workspace?.selection = SessionKey(agent, id)
            self.workspace?.open(SessionKey(agent, id))
        }
    }
}

/// `s` on one line, cut to at most `max` characters with `…`.
private func short(_ s: String, _ max: Int) -> String {
    let s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return s.count > max ? s.prefix(max) + "…" : s
}

private func plural(_ n: Int, _ one: String, _ many: String) -> String {
    "\(n) \(n == 1 ? one : many)"
}

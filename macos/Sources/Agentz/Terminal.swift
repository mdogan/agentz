// One program running in its own Ghostty terminal. This is the only file
// that uses the libghostty wrapper, so replacing it touches nothing else.
//
// Programs run in the agentz server (core/src/server), which owns their
// PTYs, so they can keep running when the app quits. Ghostty runs nothing:
// the surface shows what the server sends, and what the user types goes
// back to the server (Ghostty's host-managed backend, see `ServerLink`).
// The server tells the program's pid and when it ends.

import AgentzCore
import AppKit
import GhosttyKit
import GhosttyTerminal
import GhosttyTheme

@MainActor
final class Terminal: NSObject {
    let view = SurfaceView(frame: .zero)
    private(set) var title = ""
    private(set) var isRunning = true
    /// Called for each signal the program sends.
    var onSignal: ((TerminalSignal) -> Void)?
    /// Called once when the program exits.
    var onExit: (() -> Void)?
    /// Called when a command the shell ran ends, with its exit code (nil
    /// if not reported) and how long it ran. Needs the shell to mark its
    /// commands (OSC 133): Ghostty's shell integration or fish 4 does.
    var onCommandFinished: ((_ exitCode: Int?, _ seconds: TimeInterval) -> Void)?
    /// For a program that was already running: called once its screen is
    /// drawn again, before its live output.
    var onReplayed: (() -> Void)?
    /// The program's process id, once it started.
    private(set) var pid: Int32?
    private let link: ServerLink

    /// Starts a program in the agentz server, or shows one that runs there
    /// already.
    init(_ start: ServerLink.Start) {
        link = ServerLink(start)
        super.init()
        view.delegate = self
        view.controller = GhosttyApp.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(link.session))
        view.autoresizingMask = [.width, .height]
        if case let .attach(session) = start { pid = session.pid }
        link.onStart = { [weak self] session in self?.pid = session.pid }
        link.onReplayed = { [weak self] in self?.onReplayed?() }
        link.onEnd = { [weak self] in self?.exited() }
    }

    /// The server's id for the program, once it runs there.
    var serverId: String? { link.serverId }

    /// Why the program could not be started or shown, if it could not.
    var failure: String? { link.failure }

    /// The visible text.
    var screenText: String? { link.session.readViewportText() }

    /// Tells the server what the app now knows about the session.
    func update(_ meta: SessionMeta) {
        link.update(meta)
    }

    /// Lets go of the program without stopping it, as quitting the app
    /// does.
    func detach() {
        link.detach()
    }

    /// Hangs up on the program, as closing its tab does, but keeps the tab.
    func stop() {
        link.kill()
    }

    /// The process group that owns the terminal right now.
    var foregroundGroup: Int32? {
        guard isRunning, let pid else { return nil }
        return terminalForegroundGroup(of: pid)
    }

    /// True if the program started another one in the foreground, like a
    /// shell running a command: then the terminal belongs to another group.
    var hasForegroundJob: Bool {
        guard let pid, let group = foregroundGroup else { return false }
        return group != pid
    }

    /// True if anything but the program runs on its terminal, in the
    /// foreground or not: a shell's jobs, or an agent the user started in
    /// it.
    var hasJobs: Bool {
        guard isRunning, let pid else { return false }
        return terminalHasOthers(pid)
    }

    /// Hidden terminals keep running; they only stop drawing.
    func setVisible(_ visible: Bool) {
        view.isHidden = !visible
        view.setSurfaceVisible(visible)
    }

    func focus() {
        view.acquireProgrammaticFocus()
    }

    var isFocused: Bool {
        view.window?.firstResponder === view
    }

    /// Types a command line and presses Enter.
    func run(_ line: String) {
        view.paste(text: line)
        view.sendKey(.enter)
    }

    /// Hangs up on the program and frees Ghostty's surface. Call it when
    /// the tab goes away; waiting for the view to be freed is not enough.
    func close() {
        if isRunning { link.kill() }
        link.detach()
        isRunning = false
        onExit = nil
        onCommandFinished = nil
        onReplayed = nil
        view.controller = nil
        // Ghostty finds a surface's queued messages by its address, and a new
        // surface often gets the freed one's. A "child exited" still queued
        // for this surface would then reach the next one, which from then on
        // drops every key. Handle the queue now, before any new surface.
        GhosttyApp.controller.tick()
    }

    private func exited() {
        guard isRunning else { return }
        isRunning = false
        onExit?()
    }
}

extension Terminal:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceMouseShapeDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        self.title = title
        onSignal?(.title(title))
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent _: Int?) {
        switch state {
        case .set, .indeterminate: onSignal?(.progress(true))
        case .remove, .error, .pause: onSignal?(.progress(false))
        }
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        onCommandFinished?(exitCode, TimeInterval(durationNanos) / 1e9)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        onSignal?(.notify(title: title, body: body))
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        onSignal?(.pwd(path))
    }

    func terminalDidChangeMouseShape(_ shape: TerminalMouseShape) {
        view.cursor = switch shape {
        case .text: .iBeam
        case .pointer: .pointingHand
        case .notAllowed: .operationNotAllowed
        case .default, .other: .arrow
        }
    }

    /// Ghostty asks before a paste that could run commands, and before a
    /// program reads the clipboard (`clipboard-read = ask`) or, if the user
    /// set it so, writes it. Without an answer the wrapper denies it.
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .paste:
            alert.messageText = "Paste text that may run commands?"
            alert.informativeText = "It has lines that the program may run as soon as they are pasted."
            alert.addButton(withTitle: "Paste")
        case .osc52Read:
            alert.messageText = "Let the program read the clipboard?"
            alert.informativeText = "This is what it would get:"
            alert.addButton(withTitle: "Allow")
        case .osc52Write:
            alert.messageText = "Let the program copy to the clipboard?"
            alert.informativeText = "This is what it would copy:"
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: request.kind == .paste ? "Cancel" : "Deny")
        alert.accessoryView = clipboardPreview(request.contents)
        let answer = { (response: NSApplication.ModalResponse) in
            request.respond(allow: response == .alertFirstButtonReturn)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    private func clipboardPreview(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        scroll.borderType = .bezelBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.string = text
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        return scroll
    }
}

/// Connects a Ghostty surface to a program in the agentz server. Ghostty
/// runs nothing for the surface: the program's output comes from the
/// server, and what the surface sends (typed keys, replies to the
/// program's queries) and its size go back to the server.
///
/// It connects once the surface first reports its size, so a new program
/// starts at the right size, and a replayed screen lands in a surface that
/// exists. Ghostty calls `send` and `resize` on its own thread, and the
/// server's output arrives on one of the core's, hence the lock. The
/// `on...` callbacks run on the main thread.
final class ServerLink: TerminalSink, @unchecked Sendable {
    enum Start {
        /// Starts a program. Its size is set once the surface knows it.
        case spawn(Spawn)
        /// Shows a program that runs already.
        case attach(ServerSession)
    }

    /// What Ghostty shows.
    private(set) var session: InMemoryTerminalSession!
    var onStart: ((ServerSession) -> Void)?
    var onReplayed: (() -> Void)?
    var onEnd: (() -> Void)?

    private let start: Start
    private let lock = NSLock()
    private var connection: ServerTerminal?
    private var connecting = false
    private var size: TermSize?
    /// Typed before the connection was made.
    private var pending = Data()
    /// The surface answers the queries in a replayed screen again. Those
    /// answers are old news to the program, so they are dropped until the
    /// replay is parsed.
    private var replaying = false
    private var closing = Closing.no
    private var id: String?
    private var failureMessage: String?

    private enum Closing { case no, detach, kill }

    init(_ start: Start) {
        self.start = start
        if case let .attach(session) = start { id = session.id }
        session = InMemoryTerminalSession(
            write: { [weak self] data in self?.send(data) },
            resize: { [weak self] viewport in self?.resize(viewport) }
        )
    }

    var serverId: String? { locked { id } }
    var failure: String? { locked { failureMessage } }

    func update(_ meta: SessionMeta) {
        locked { connection }?.update(meta)
    }

    func detach() {
        let connection = locked {
            if closing == .no { closing = .detach }
            return self.connection
        }
        connection?.detach()
    }

    func kill() {
        let connection = locked {
            // After a detach, the program is no longer ours to stop.
            guard closing != .detach else { return nil as ServerTerminal? }
            closing = .kill
            return self.connection
        }
        connection?.kill()
        connection?.detach()
    }

    private func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !replaying, closing == .no else { return }
        // Written under the lock, so typing stays in order with what was
        // typed while connecting.
        if let connection {
            connection.write(data)
        } else {
            pending.append(data)
        }
    }

    private func resize(_ viewport: InMemoryTerminalViewport) {
        let size = TermSize(cols: viewport.columns, rows: viewport.rows, widthPx: viewport.widthPixels, heightPx: viewport.heightPixels)
        guard size.cols > 0, size.rows > 0 else { return }
        let (connection, first) = locked {
            self.size = size
            let first = self.connection == nil && !connecting && closing == .no
            if first {
                connecting = true
                if case .attach = start { replaying = true }
            }
            return (self.connection, first)
        }
        if let connection {
            connection.resize(size)
        } else if first {
            DispatchQueue.global(qos: .userInitiated).async { self.connect(size) }
        }
    }

    private func connect(_ size: TermSize) {
        let connection: ServerTerminal
        do {
            switch start {
            case var .spawn(spawn):
                spawn.size = size
                connection = try ServerTerminal.spawn(Bundle.main.executablePath ?? CommandLine.arguments[0], spawn, self)
            case let .attach(session):
                connection = try ServerTerminal.attach(session.id, size, self)
            }
        } catch {
            locked {
                failureMessage = errorMessage(error)
                replaying = false
            }
            DispatchQueue.main.async { self.onEnd?() }
            return
        }
        let info = connection.session()
        let closing = locked {
            id = info.id
            if self.closing == .no {
                self.connection = connection
                if !pending.isEmpty { connection.write(pending) }
                pending = Data()
                // The surface changed size while connecting.
                if let latest = self.size, latest != size { connection.resize(latest) }
            }
            return self.closing
        }
        // The tab went away while connecting.
        if closing == .kill { connection.kill() }
        if closing != .no { connection.detach() }
        DispatchQueue.main.async { self.onStart?(info) }
    }

    // MARK: TerminalSink, on the core's thread

    func output(_ data: Data) {
        session.receive(data)
    }

    func replayed() {
        // Waits until the surface parsed the replay, and replied to it.
        session.waitForPendingOutput()
        locked { replaying = false }
        DispatchQueue.main.async { self.onReplayed?() }
    }

    func exited(_: Int32?) {
        DispatchQueue.main.async { self.onEnd?() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Ghostty's view, plus what Ghostty.app adds around it: the mouse cursor
/// the terminal asks for, and dropping files to type their paths.
final class SurfaceView: TerminalView {
    /// Ghostty starts with the text cursor and says when that changes,
    /// e.g. to a pointing hand over a link.
    var cursor: NSCursor = .iBeam {
        didSet {
            guard cursor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            // Cursor rects only apply on the next mouse move.
            if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                cursor.set()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedText(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = droppedText(sender.draggingPasteboard) else { return false }
        return paste(text: text)
    }

    /// Like Ghostty.app: files become their paths, quoted for the shell,
    /// so an agent can attach a dropped screenshot. Links and text go in
    /// as they are.
    private func droppedText(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty
        {
            return urls.map { shellEscape($0.path) }.joined(separator: " ")
        }
        if let url = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let first = url.first {
            return first.absoluteString
        }
        return pasteboard.string(forType: .string)
    }
}

/// The one Ghostty app all terminals share, and its config. A theme picked
/// in the Theme menu replaces the config's colors, across launches, until
/// "Follow Ghostty" is picked again.
@MainActor
enum GhosttyApp {
    /// The `UserDefaults` key of the picked theme's name; absent to follow
    /// the Ghostty config.
    static let selectedThemeKey = "selectedGhosttyTheme"
    /// Why the user's Ghostty config could not be used, if it could not.
    private(set) static var configIssue: String?
    /// The config the terminals use, for reading their colors.
    private static var configText = ""
    /// True when the wrapper's own theme gives the colors.
    private static var usesDefaultTheme = true
    /// The user's Ghostty config, read once at launch.
    private static var userText: String?

    /// What to do when a command in a shell ends, from the config the
    /// terminals use.
    static var commandFinish: CommandFinishSettings {
        CommandFinishSettings(config: configText)
    }

    /// The environment Ghostty gives the programs it starts: `base`, with
    /// what Ghostty adds. The programs the agentz server starts get it, so
    /// they can't tell the difference: Claude, for one, only reports
    /// progress to Ghostty.
    static func programEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-ghostty"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM_PROGRAM_VERSION"] = version
        env["GHOSTTY_SHELL_FEATURES"] = shellFeatures
        if let exe = Bundle.main.executableURL { env["GHOSTTY_BIN_DIR"] = exe.deletingLastPathComponent().path }
        if let dir = GhosttyRuntimeResources.terminfoDirectoryURL?.path { env["TERMINFO"] = dir }
        if let dir = GhosttyRuntimeResources.directoryURL?.path {
            env["GHOSTTY_RESOURCES_DIR"] = dir
            // Ghostty's data folder goes last, as Ghostty does it.
            let data = dir + "/.."
            let current = env["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
            var dirs = current.split(separator: ":").map(String.init)
            if !dirs.contains(data) { dirs.append(data) }
            env["XDG_DATA_DIRS"] = dirs.joined(separator: ":")
        }
        return env
    }

    /// How Ghostty starts `shell`, given its environment `env`: the command
    /// line, and what to add to the environment for Ghostty's shell
    /// integration, which marks prompts and commands (OSC 133) and reports
    /// the folder (OSC 7). It comes for zsh and bash; fish 4 does both by
    /// itself. Like Ghostty, it leaves `/bin/bash` alone: Apple's bash 3.2
    /// can't load it.
    static func shellLaunch(_ shell: String, env: [String: String]) -> (argv: [String], env: [String: String]) {
        let setting = configValues("shell-integration").last ?? "detect"
        let kind = setting == "detect" ? baseName(shell) : setting
        guard let dir = GhosttyRuntimeResources.directoryURL?.appendingPathComponent("shell-integration").path else {
            return ([shell], [:])
        }
        var added: [String: String] = [:]
        switch kind {
        case "zsh":
            // zsh reads Ghostty's .zshenv, which puts the user's ZDOTDIR back.
            if let user = env["ZDOTDIR"] { added["GHOSTTY_ZSH_ZDOTDIR"] = user }
            added["ZDOTDIR"] = dir + "/zsh"
            return ([shell], added)
        case "bash" where shell != "/bin/bash":
            // In POSIX mode, bash reads only $ENV: Ghostty's script, which
            // then reads the user's startup files.
            added["GHOSTTY_BASH_INJECT"] = "1"
            added["ENV"] = dir + "/bash/ghostty.bash"
            if let user = env["ENV"] { added["GHOSTTY_BASH_ENV"] = user }
            if env["HISTFILE"] == nil {
                // POSIX mode would keep history in ~/.sh_history.
                added["HISTFILE"] = (env["HOME"] ?? NSHomeDirectory()) + "/.bash_history"
                added["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
            return ([shell, "--posix"], added)
        default:
            return ([shell], [:])
        }
    }

    /// `shell-integration-features` as Ghostty passes it on: the features
    /// that are on, sorted, e.g. `path,ssh-env,title`.
    private static var shellFeatures: String {
        // Ghostty's defaults.
        var on = ["cursor": true, "sudo": false, "title": true, "ssh-env": false, "ssh-terminfo": false, "path": true]
        for value in configValues("shell-integration-features") {
            for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                switch item {
                case "true", "false":
                    for key in on.keys { on[key] = item == "true" }
                default:
                    let off = item.hasPrefix("no-")
                    let key = off ? String(item.dropFirst(3)) : item
                    if on[key] != nil { on[key] = !off }
                }
            }
        }
        var names = on.filter(\.value).map(\.key)
        if let i = names.firstIndex(of: "cursor") {
            switch configValues("cursor-style-blink").last {
            case "true": names[i] = "cursor:blink"
            case "false": names[i] = "cursor:steady"
            default: break
            }
        }
        return names.sorted().joined(separator: ",")
    }

    /// The values of `key` in the config the terminals use, in order.
    private static func configValues(_ key: String) -> [String] {
        configText.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { return nil }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// The library's Ghostty version, e.g. `1.3.2-HEAD-+3c47ca159`.
    private static let version: String = {
        _ = controller
        let info = ghostty_info()
        guard let text = info.version else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(info.version_len)), as: UTF8.self)
    }()

    /// The terminals' colors in the light or dark appearance.
    static func colors(dark: Bool) -> TerminalColors {
        _ = controller
        var text = configText
        if usesDefaultTheme {
            text = (dark ? TerminalTheme.default.dark : TerminalTheme.default.light).rendered + "\n" + text
        }
        return TerminalColors.from(config: text, dark: dark) { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    /// Where themes are found by name: Ghostty's own places, and without
    /// Ghostty.app, the themes that come with the library, written out
    /// once per launch.
    static let themeDirectories: [String] = {
        var dirs = GhosttyThemes.directories()
        guard !dirs.contains(where: { $0.hasSuffix("/Ghostty.app/Contents/Resources/ghostty/themes") && isDirectory($0) })
        else { return dirs }
        let bundled = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "agentz")
            .appendingPathComponent("ghostty-themes")
        // Written fresh, so themes dropped from the library go away too.
        try? FileManager.default.removeItem(at: bundled)
        guard (try? FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)) != nil
        else { return dirs }
        for theme in GhosttyThemeCatalog.allThemes where !theme.name.contains("/") {
            let text = theme.toTerminalConfiguration().rendered
            try? text.write(to: bundled.appendingPathComponent(theme.name), atomically: false, encoding: .utf8)
        }
        dirs.append(bundled.path)
        return dirs
    }()

    /// The user's config with the picked theme, if any, in place of its
    /// colors. Nil without either. A picked theme that is no longer on
    /// disk is left out, so the config's colors show.
    private static var themedUserText: String? {
        let picked = UserDefaults.standard.string(forKey: selectedThemeKey)
            .flatMap { GhosttyThemes.path(of: $0, in: themeDirectories) }
        guard let picked else { return userText }
        return GhosttyThemes.config(userText ?? "", using: picked)
    }

    /// Uses `name`'s colors in every terminal from now on, or the Ghostty
    /// config's when `nil`.
    static func selectTheme(_ name: String?) {
        UserDefaults.standard.set(name, forKey: selectedThemeKey)
        configIssue = nil
        if let user = themedUserText {
            let text = defaults + "\n" + user
            _ = controller.setTheme(TerminalTheme())
            if controller.updateConfigSource(.generated(text)) {
                configText = text
                usesDefaultTheme = false
                return
            }
            configIssue = controller.lastConfigurationIssue
        }
        controller.updateConfigSource(.generated(defaults))
        _ = controller.setTheme(.default)
        configText = defaults
        usesDefaultTheme = true
    }

    /// Created on first use, after the login shell's environment is loaded,
    /// since Ghostty reads it then.
    static let controller: TerminalController = {
        // AGENTZ_TERMINAL_DEBUG=<file> logs what the wrapper sees.
        if let path = ProcessInfo.processInfo.environment["AGENTZ_TERMINAL_DEBUG"], !path.isEmpty {
            FileManager.default.createFile(atPath: path, contents: nil)
            let log = FileHandle(forWritingAtPath: path)
            TerminalDebugLog.sink = { line in log?.write(Data((line + "\n").utf8)) }
            TerminalDebugLog.enable([.lifecycle, .actions])
        }
        // The wrapper writes a config file per load and leaves them behind.
        try? FileManager.default.removeItem(at: TerminalController.managedConfigDirectory)
        configText = defaults
        userText = userConfig()
        guard let user = themedUserText else {
            return TerminalController(configSource: .generated(defaults), theme: .default)
        }
        // Ours first, so their own settings and keybinds win.
        let controller = TerminalController(configSource: .generated(defaults + "\n" + user), theme: TerminalTheme())
        if let issue = controller.lastConfigurationIssue {
            configIssue = issue
            controller.updateConfigSource(.generated(defaults))
            _ = controller.setTheme(.default)
        } else {
            configText = defaults + "\n" + user
            usesDefaultTheme = false
        }
        return controller
    }()

    /// Ghostty.app's macOS bindings (as of 1.3), except for windows, tabs,
    /// splits, search and the like. Those belong to the app's menu here, or
    /// the embedded terminal can't do them, and a key bound here never
    /// reaches the menu. Paste and select all go through the Edit menu.
    private static let defaults = """
    keybind = clear
    keybind = copy=copy_to_clipboard:mixed
    keybind = paste=paste_from_clipboard
    # Copies the terminal's selection. Without one, the program gets the
    # key: Claude selects text by itself and copies it on cmd+c.
    keybind = performable:super+c=copy_to_clipboard:mixed
    keybind = super+equal=increase_font_size:1
    keybind = super+plus=increase_font_size:1
    keybind = super+minus=decrease_font_size:1
    keybind = super+zero=reset_font_size
    keybind = super+k=clear_screen
    keybind = super+home=scroll_to_top
    keybind = super+end=scroll_to_bottom
    keybind = super+page_up=scroll_page_up
    keybind = super+page_down=scroll_page_down
    keybind = super+arrow_up=jump_to_prompt:-1
    keybind = super+arrow_down=jump_to_prompt:1
    keybind = super+shift+arrow_up=jump_to_prompt:-1
    keybind = super+shift+arrow_down=jump_to_prompt:1
    # Line and word editing, like Terminal.app.
    keybind = super+arrow_left=text:\\x01
    keybind = super+arrow_right=text:\\x05
    keybind = super+backspace=text:\\x15
    keybind = alt+arrow_left=esc:b
    keybind = alt+arrow_right=esc:f
    # Moves an end of the selection. Without one, the program gets the key.
    keybind = performable:shift+arrow_left=adjust_selection:left
    keybind = performable:shift+arrow_right=adjust_selection:right
    keybind = performable:shift+arrow_up=adjust_selection:up
    keybind = performable:shift+arrow_down=adjust_selection:down
    keybind = performable:shift+page_up=adjust_selection:page_up
    keybind = performable:shift+page_down=adjust_selection:page_down
    keybind = performable:shift+home=adjust_selection:home
    keybind = performable:shift+end=adjust_selection:end
    # The screen and scrollback as a file: its path pasted, copied, or opened.
    keybind = super+shift+j=write_screen_file:paste,plain
    keybind = super+ctrl+shift+j=write_screen_file:copy,plain
    keybind = super+alt+shift+j=write_screen_file:open,plain
    # Claude and Codex both read ESC + CR as "insert a newline".
    keybind = shift+enter=text:\\x1b\\r
    # Option+key as Alt, like the Rust version.
    macos-option-as-alt = true
    confirm-close-surface = false
    """

    /// The user's Ghostty config, so terminals get their fonts and colors.
    /// `AGENTZ_GHOSTTY_CONFIG` names another file; empty means none.
    private static func userConfig() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let xdg = env["XDG_CONFIG_HOME"] ?? home + "/.config"
        let candidates = env["AGENTZ_GHOSTTY_CONFIG"].map { [$0] } ?? [
            xdg + "/ghostty/config",
            home + "/Library/Application Support/com.mitchellh.ghostty/config",
        ]
        guard let path = candidates.first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let themeDirs = themeDirectories
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return String(line) }
            switch parts[0] {
            case "theme":
                // Themes ship with Ghostty.app, not with the library.
                return "theme = " + resolveThemes(parts[1], in: themeDirs)
            case "keybind" where parts[1].hasPrefix("global:"):
                // Global shortcuts belong to Ghostty.app.
                return nil
            default:
                return String(line)
            }
        }.joined(separator: "\n")
    }

    /// `Name` or `light:Name,dark:Name`, with each name replaced by its file.
    private static func resolveThemes(_ value: String, in dirs: [String]) -> String {
        value.split(separator: ",").map { part in
            let pieces = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = pieces.last ?? ""
            let path = GhosttyThemes.path(of: name, in: dirs) ?? name
            return pieces.count == 2 ? "\(pieces[0]):\(path)" : path
        }.joined(separator: ",")
    }
}

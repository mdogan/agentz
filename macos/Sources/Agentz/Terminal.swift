// One program running in its own Ghostty terminal. This is the only file
// that uses the libghostty wrapper, so replacing it touches nothing else.
//
// Ghostty owns the PTY. It starts the command as
// `login -flp $USER bash --noprofile --norc -c "exec -l <command>"`, and
// `exec` keeps the pid, so the program we asked for is the child of a
// `login` that is our child (see `mainProcess(onTTY:)`).
//
// Ghostty does not close a surface when its program exits: the embedding
// API turns on `wait-after-command` for every surface given a command. So
// we watch the program's pid ourselves.

import AgentzCore
import AppKit
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
    /// Called when the terminal or its find bar gets the keyboard, e.g.
    /// from a click.
    var onFocus: (() -> Void)?
    /// Where the viewport is in the scrollback, as Ghostty last said.
    private(set) var scrollbar: TerminalScrollbar?
    /// Made when first shown.
    private var findBar: FindBar?
    private var knownPid: Int32?
    private var exitWatch: DispatchSourceProcess?
    private let startedAt = Date()

    /// `command` is run by `bash -c`, so quote its arguments. `env` is added
    /// to this app's environment.
    init(command: String, cwd: String, env: [String: String]) {
        super.init()
        view.delegate = self
        view.onFocus = { [weak self] in self?.onFocus?() }
        view.controller = GhosttyApp.controller
        view.configuration = TerminalSurfaceOptions(
            workingDirectory: cwd,
            envVars: env,
            command: command
        )
        view.autoresizingMask = [.width, .height]
    }

    /// The program's process id, once Ghostty has started it.
    var pid: Int32? {
        poll()
        return knownPid
    }

    /// Finds the program's pid and notices when it is gone. Called on every
    /// tick; the pid watch reports exits right away after that.
    func poll() {
        guard isRunning, knownPid == nil, let tty = view.ttyName else { return }
        if let pid = mainProcess(onTTY: tty) {
            watch(pid)
        } else if Date().timeIntervalSince(startedAt) > 3, !ttyHasProcesses(tty) {
            // It quit before we saw it, e.g. a command that was not found.
            exited()
        }
    }

    private func watch(_ pid: Int32) {
        knownPid = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.exited() }
        }
        source.resume()
        exitWatch = source
        // It may have exited before the watch started.
        if kill(pid, 0) != 0, errno == ESRCH { exited() }
    }

    /// The process group that owns the terminal right now.
    var foregroundGroup: Int32? {
        isRunning ? view.foregroundPid : nil
    }

    /// True if the program started another one in the foreground, like a
    /// shell running a command: then the terminal belongs to another group.
    var hasForegroundJob: Bool {
        guard let pid, let group = foregroundGroup else { return false }
        return group != pid
    }

    /// Hidden terminals keep running; they only stop drawing.
    func setVisible(_ visible: Bool) {
        view.isHidden = !visible
        view.setSurfaceVisible(visible)
    }

    func focus() {
        view.acquireProgrammaticFocus()
    }

    /// The terminal or its find bar has the keyboard.
    var isFocused: Bool {
        (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
    }

    // MARK: - Find

    /// The find bar shows.
    var isFinding: Bool {
        findBar.map { !$0.isHidden } ?? false
    }

    /// Shows the find bar at the top right and gives it the keyboard. The
    /// text from last time is still there, selected, and searched for
    /// again.
    func showFind() {
        let bar = findBar ?? makeFindBar()
        if bar.isHidden {
            let size = bar.fittingSize
            bar.frame = NSRect(
                x: view.bounds.maxX - size.width - 8, y: view.bounds.maxY - size.height - 8,
                width: size.width, height: size.height
            )
            bar.isHidden = false
            // Closing the bar ended the search.
            if !bar.text.isEmpty { search(bar.text) }
        }
        bar.focus()
    }

    /// Hides the find bar and ends the search. The terminal gets the
    /// keyboard if the bar had it.
    func hideFind() {
        guard let findBar, !findBar.isHidden else { return }
        let hadKeyboard = findBar.hasKeyboard
        findBar.isHidden = true
        view.performBindingAction("end_search")
        if hadKeyboard { focus() }
    }

    /// Up to the next match: the newest first, then older ones. Ghostty
    /// scrolls to it.
    func findNext() {
        findBar?.searchNow()
        view.performBindingAction("navigate_search:next")
    }

    /// Down to the previous match.
    func findPrevious() {
        findBar?.searchNow()
        view.performBindingAction("navigate_search:previous")
    }

    /// Ghostty takes the text as it is, without escapes. Empty stops the
    /// search.
    private func search(_ text: String) {
        view.performBindingAction("search:" + text)
    }

    private func makeFindBar() -> FindBar {
        let bar = FindBar()
        // Stays at the top right while the terminal changes size.
        bar.autoresizingMask = [.minXMargin, .minYMargin]
        bar.onSearch = { [weak self] text in self?.search(text) }
        bar.onNext = { [weak self] in self?.findNext() }
        bar.onPrevious = { [weak self] in self?.findPrevious() }
        bar.onClose = { [weak self] in self?.hideFind() }
        bar.onFocus = { [weak self] in self?.onFocus?() }
        view.addSubview(bar)
        findBar = bar
        return bar
    }

    /// Types a command line and presses Enter.
    func run(_ line: String) {
        view.paste(text: line)
        view.sendKey(.enter)
    }

    /// Frees Ghostty's surface, which hangs up on the program. Call it when
    /// the tab goes away; waiting for the view to be freed is not enough.
    func close() {
        exitWatch?.cancel()
        exitWatch = nil
        isRunning = false
        onExit = nil
        onCommandFinished = nil
        onFocus = nil
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
        exitWatch?.cancel()
        exitWatch = nil
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
    TerminalSurfaceScrollbarDelegate,
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

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        self.scrollbar = scrollbar
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

/// Ghostty's view, plus what Ghostty.app adds around it: the mouse cursor
/// the terminal asks for, and dropping files to type their paths.
final class SurfaceView: TerminalView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// Ghostty starts with the text cursor and says when that changes,
    /// e.g. to a pointing hand over a link.
    var cursor: NSCursor = .iBeam {
        didSet {
            guard cursor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            // Cursor rects only apply on the next mouse move. The find bar
            // has its own.
            if let window, let superview,
               hitTest(superview.convert(window.mouseLocationOutsideOfEventStream, from: nil)) === self
            {
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

    // MARK: - A mouse-up lost to another window

    /// The left button went down here, and where the mouse was last while
    /// it stayed down. Nil once it came up.
    private var leftDown: NSEvent?
    private var resignKeyObserver: NSObjectProtocol?

    /// True while the left button that went down here has not come up.
    var isLeftButtonDown: Bool { leftDown != nil }

    override func mouseDown(with event: NSEvent) {
        // Its mouse-up never came: end that click first.
        releaseLeftButton()
        leftDown = event
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if leftDown != nil { leftDown = event }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        leftDown = nil
        super.mouseUp(with: event)
    }

    /// When another window takes the keyboard while the button is down
    /// here, e.g. another app comes to the front in the middle of a drag,
    /// the mouse-up goes there. The program here, like Claude Code
    /// selecting text with the mouse, would think the button is still held
    /// and go on selecting as the mouse moves. It gets a mouse-up instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseLeftButton() }
        }
    }

    /// Tells the terminal the left button came up, where the mouse was
    /// last, if it went down here and did not.
    func releaseLeftButton() {
        guard let down = leftDown, let window else { return }
        leftDown = nil
        guard let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: down.locationInWindow, modifierFlags: down.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ) else { return }
        super.mouseUp(with: up)
    }

    /// A program that took the mouse, like Claude Code, gets the wheel at
    /// the last place Ghostty heard the mouse was, and nothing while that
    /// is off the terminal. Ghostty hears it from moves and clicks only: a
    /// new terminal starts off it, at (-1, -1), and one the mouse left
    /// stays there. So a terminal shown under a still mouse, e.g. picked
    /// in the list with the arrow keys, got no wheel until a click.
    override func scrollWheel(with event: NSEvent) {
        mouseMoved(with: event)
        super.scrollWheel(with: event)
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
    /// The user's Ghostty config file as it is, with its global keybinds.
    private static var userFile = ""

    /// What to do when a command in a shell ends, from the config the
    /// terminals use.
    static var commandFinish: CommandFinishSettings {
        CommandFinishSettings(config: configText)
    }

    /// How split panes look, from the config the terminals use.
    static var splitLook: SplitLook {
        SplitLook(config: configText)
    }

    /// Where the quick terminal shows and the key that toggles it, from
    /// the user's config.
    static var quickTerminal: QuickTerminalSettings {
        _ = controller
        return QuickTerminalSettings(config: userFile)
    }

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
        let file = userConfigFile()
        userFile = file ?? ""
        userText = file.map(forTerminals)
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
    private static func userConfigFile() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let xdg = env["XDG_CONFIG_HOME"] ?? home + "/.config"
        let candidates = env["AGENTZ_GHOSTTY_CONFIG"].map { [$0] } ?? [
            xdg + "/ghostty/config",
            home + "/Library/Application Support/com.mitchellh.ghostty/config",
        ]
        guard let path = candidates.first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// The user's config as the terminal library takes it.
    private static func forTerminals(_ text: String) -> String {
        let themeDirs = themeDirectories
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return String(line) }
            switch parts[0] {
            case "theme":
                // Themes ship with Ghostty.app, not with the library.
                return "theme = " + resolveThemes(parts[1], in: themeDirs)
            case "keybind" where parts[1].hasPrefix("global:"):
                // The library has no global keys. The quick terminal's
                // is read from `userFile`.
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

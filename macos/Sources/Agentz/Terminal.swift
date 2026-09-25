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

@MainActor
final class Terminal: NSObject {
    let view = SurfaceView(frame: .zero)
    private(set) var title = ""
    private(set) var isRunning = true
    /// Called for each signal the program sends.
    var onSignal: ((TerminalSignal) -> Void)?
    /// Called once when the program exits.
    var onExit: (() -> Void)?
    private var knownPid: Int32?
    private var exitWatch: DispatchSourceProcess?
    private let startedAt = Date()

    /// `command` is run by `bash -c`, so quote its arguments. `env` is added
    /// to this app's environment.
    init(command: String, cwd: String, env: [String: String]) {
        super.init()
        view.delegate = self
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

    var isFocused: Bool {
        view.window?.firstResponder === view
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

/// The one Ghostty app all terminals share, and its config.
@MainActor
enum GhosttyApp {
    /// Why the user's Ghostty config could not be used, if it could not.
    private(set) static var configIssue: String?
    /// The config the terminals use, for reading their colors.
    private static var configText = ""
    /// True when the wrapper's own theme gives the colors.
    private static var usesDefaultTheme = true

    /// The terminals' colors in the light or dark appearance.
    static func colors(dark: Bool) -> TerminalColors {
        _ = controller
        var text = configText
        if usesDefaultTheme {
            text = (dark ? TerminalTheme.default.dark : TerminalTheme.default.light).rendered + "\n" + text
        }
        return TerminalColors.from(config: text, dark: dark) { try? String(contentsOfFile: $0, encoding: .utf8) }
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
        guard let user = userConfig() else {
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
        let themeDirs = [
            xdg + "/ghostty/themes",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
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
            let path = name.hasPrefix("/") ? name : dirs.map { $0 + "/" + name }.first {
                FileManager.default.fileExists(atPath: $0)
            } ?? name
            return pieces.count == 2 ? "\(pieces[0]):\(path)" : path
        }.joined(separator: ",")
    }
}

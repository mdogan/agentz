import AgentzCore
import AppKit

/// A scripted check of the real app with real Ghostty terminals, started by
/// `make smoke`. It opens shells and a stand-in `codex`, types commands and
/// checks what agentz sees, then writes PASS or FAIL lines to
/// `AGENTZ_SMOKE_LOG` and quits. It neither restores nor saves tabs.
@MainActor
final class SmokeTest {
    private let workspace: Workspace
    private let logPath: String
    private var lines: [String] = []
    private var failed = false
    private var notices: [(key: SessionKey, message: String?)] = []

    static var logPath: String? {
        ProcessInfo.processInfo.environment["AGENTZ_SMOKE_LOG"]
    }

    init(workspace: Workspace, logPath: String) {
        self.workspace = workspace
        self.logPath = logPath
    }

    /// Stands in for Codex: a title spinner while "working", a notification
    /// after the next Enter, and an exit after the one after that.
    private static let fakeCodex = #"""
    #!/bin/sh
    printf '\033]2;\342\240\213 Working\007'
    sleep 1
    printf '\033]2;Codex\007'
    read line
    printf '\033]777;notify;Codex;Done: OK\033\\'
    read line
    exit 0
    """#

    func run() async {
        let ws = workspace
        let notify = ws.notify
        ws.notify = { [weak self] agent, title, message, key in
            self?.notices.append((key, message))
            notify?(agent, title, message, key)
        }
        let tmp = (realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/agentz-smoke-\(getpid())"
        let bin = tmp + "/bin"
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        FileManager.default.createFile(atPath: bin + "/codex", contents: Data(Self.fakeCodex.utf8), attributes: [.posixPermissions: 0o755])
        setenv("PATH", bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        let envFile = tmp + "/env"

        lines.append("info ghostty config: \(GhosttyApp.configIssue.map { "not used: \($0)" } ?? "used")")

        // A shell: its pid, environment, folder and foreground job.
        ws.newSession(.shell)
        guard let shell = ws.currentTab else { return finish("no tab after newSession") }
        let shellKey = shell.key
        let t = shell.terminal
        check("shell pid found", await wait(10) { t.pid != nil })
        let name = t.pid.flatMap(processName)
        check("pid is the login shell", name.map { $0.hasSuffix(Launch.shellName) } ?? false, "name=\(name ?? "nil") shell=\(Launch.shellName)")
        check("idle shell has no foreground job", await wait(5) { !t.hasForegroundJob && t.foregroundGroup != nil })

        t.run("printf '%s %s %s' \"$TERM_PROGRAM\" \"$TERM\" \"$CLAUDECODE\" > \(shellQuote(envFile))")
        check("environment", await wait(5) {
            (try? String(contentsOfFile: envFile, encoding: .utf8)) == "ghostty xterm-ghostty "
        }, (try? String(contentsOfFile: envFile, encoding: .utf8)) ?? "no file")

        t.run("cd \(shellQuote(tmp))")
        check("folder follows cd (OSC 7)", await wait(5) { shell.cwd == tmp || realPath(shell.cwd) == tmp }, shell.cwd)

        t.run("sleep 3")
        check("sees the foreground job", await wait(5) { t.hasForegroundJob })
        check("quit counts a shell running a command", ws.quitCounts().commands == 1)
        ws.requestScan?()
        check("shell named after its job", await wait(5) { shell.title == "sleep" }, shell.title)
        check("job ends", await wait(8) { !t.hasForegroundJob })
        check("shell name back", await wait(8) { shell.title == Launch.shellName }, shell.title)

        // An agent started from the idle shell takes its place and folder.
        ws.newSession(.codex)
        guard let codex = ws.currentTab, codex.key.agent == .codex else { return finish("no codex tab") }
        let codexKey = codex.key
        codex.turns.userInput()
        check("agent replaces the idle shell", !ws.tabs.contains { $0.key == shellKey })
        check("agent starts in the shell's folder", codex.cwd == tmp || realPath(codex.cwd) == tmp, codex.cwd)
        check("agent busy from its title", await wait(5) { codex.isBusy })
        check("quit counts a working agent", ws.quitCounts().working == 1)

        // Another tab, so the agent is not looked at and may notify.
        ws.newSession(.shell)
        guard let other = ws.currentTab, other.key.agent == .shell else { return finish("no second shell") }
        check("notice when the agent is done", await wait(8) { self.notices.contains { $0.key == codexKey && $0.message == nil } })
        check("one notice per turn", notices.filter { $0.key == codexKey }.count == 1)
        codex.turns.userInput()
        codex.terminal.run("")
        check("agent's own notification text", await wait(5) { self.notices.contains { $0.key == codexKey && $0.message == "Done: OK" } })

        snapshot()

        let state = ws.savedState()
        check("saved state has both tabs", state.tabs.count == 2, "\(state.tabs.count)")
        check("saved active tab", state.active == 1)

        // The shown agent quits: a shell takes its place.
        ws.open(codexKey)
        check("switch to the agent", ws.current == codexKey)
        codex.terminal.run("")
        check("quit agent is replaced by a shell", await wait(5) {
            ws.currentTab?.key.agent == .shell && ws.currentTab?.placeholder == true && !ws.tabs.contains { $0.key == codexKey }
        })

        // Exiting a shell closes its tab.
        other.terminal.run("exit")
        check("exited shell tab is removed", await wait(5) { !ws.tabs.contains { $0 === other } })

        // Closing a tab hangs up on its program.
        let placeholderPid = ws.currentTab?.terminal.pid
        weak let closedView = ws.currentTab?.terminal.view
        weak let closedTerminal = ws.currentTab?.terminal
        if let key = ws.currentTab?.key { ws.close(key) }
        check("closed tab is removed", ws.tabs.isEmpty, "\(ws.tabs.count) left")
        check("closed terminal is freed", await wait(3) { closedTerminal == nil })
        check("closed terminal view is freed", await wait(3) { closedView == nil })
        check("closed shell's process ends", await wait(5) {
            placeholderPid.map { kill($0, 0) != 0 } ?? false
        }, "pid \(placeholderPid.map(String.init) ?? "nil")")

        // Restoring starts saved tabs and hands back the ones it could not.
        let missing = tmp + "/missing"
        let failed = ws.restore(SavedState(tabs: [
            SavedTab(agent: .shell, id: nil, cwd: tmp, title: "restored"),
            SavedTab(agent: .shell, id: nil, cwd: missing, title: "missing"),
        ], active: 0))
        check("restore starts saved tabs", ws.tabs.count == 1 && ws.currentTab?.cwd == tmp)
        check("restore returns tabs it could not open", failed.tabs.map(\.cwd) == [missing])
        if let key = ws.currentTab?.key { ws.close(key) }

        finish(nil)
    }

    /// `AGENTZ_SMOKE_SNAPSHOT=<file.png>` saves how the window looks. The
    /// app draws it itself, so no screen recording permission is needed;
    /// Metal terminals come out blank.
    private func snapshot() {
        guard let path = ProcessInfo.processInfo.environment["AGENTZ_SMOKE_SNAPSHOT"],
              let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed = true }
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : " (\(detail))")")
    }

    private func wait(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date() + seconds
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
            workspace.tick()
        }
        return condition()
    }

    private func finish(_ error: String?) {
        if let error {
            failed = true
            lines.append("FAIL \(error)")
        }
        lines.append(failed ? "FAIL" : "PASS")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        exit(failed ? 1 : 0)
    }
}

private func processName(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

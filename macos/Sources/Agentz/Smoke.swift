import AgentzCore
import AppKit

/// A scripted check of the real app with real Ghostty terminals, started by
/// `make smoke`. It opens shells and a stand-in `codex`, types commands and
/// checks what agentz sees, then writes PASS or FAIL lines to
/// `AGENTZ_SMOKE_LOG` and quits. It neither restores nor saves the user's
/// tabs, and runs its shells and agents in an agentz server of its own.
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

    /// Stands in for Codex: a line of text, a title spinner while
    /// "working", a notification after the next Enter, and an exit after the
    /// one after that.
    private static let fakeCodex = #"""
    #!/bin/sh
    [ -n "$AGENTZ_SMOKE_AGENT_ENV" ] && printf '%s %s' "$TERM_PROGRAM" "$TERM" > "$AGENTZ_SMOKE_AGENT_ENV"
    echo 'codex ready'
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
        ws.notify = { [weak self] heading, title, message, key in
            self?.notices.append((key, message))
            notify?(heading, title, message, key)
        }
        let tmp = (realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/agentz-smoke-\(getpid())"
        let bin = tmp + "/bin"
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        FileManager.default.createFile(atPath: bin + "/codex", contents: Data(Self.fakeCodex.utf8), attributes: [.posixPermissions: 0o755])
        setenv("PATH", bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        let envFile = tmp + "/env"
        let agentEnvFile = tmp + "/agent-env"
        setenv("AGENTZ_SMOKE_AGENT_ENV", agentEnvFile, 1)
        // Not the user's server, which runs their agents.
        setenv("AGENTZ_SERVER_DIR", tmp, 1)

        lines.append("info ghostty config: \(GhosttyApp.configIssue.map { "not used: \($0)" } ?? "used")")

        // `make smoke` opens this repo.
        check("worktrees of the repo are listed", await wait(10) { ws.currentWorktree != nil }, "\(ws.worktrees.count) worktrees")

        // A shell: its pid, environment, folder and foreground job.
        ws.newSession(.shell)
        guard let shell = ws.currentTab else { return finish("no tab after newSession") }
        let shellKey = shell.key
        let t = shell.terminal
        check("shell pid found", await wait(10) { t.pid != nil })
        check("shell runs in the server", t.serverId != nil)
        let name = t.pid.flatMap(processName)
        check("pid is the login shell", name.map { $0.hasSuffix(Launch.shellName) } ?? false, "name=\(name ?? "nil") shell=\(Launch.shellName)")
        check("idle shell has no foreground job", await wait(5) { !t.hasForegroundJob && t.foregroundGroup != nil })

        t.run("printf '%s %s %s' \"$TERM_PROGRAM\" \"$TERM\" \"$CLAUDECODE\" > \(shellQuote(envFile))")
        check("environment", await wait(5) {
            (try? String(contentsOfFile: envFile, encoding: .utf8)) == "ghostty xterm-ghostty "
        }, (try? String(contentsOfFile: envFile, encoding: .utf8)) ?? "no file")

        t.run("cd \(shellQuote(tmp))")
        check("folder follows cd (OSC 7)", await wait(5) { shell.cwd == tmp || realPath(shell.cwd) == tmp }, shell.cwd)

        // Only shells that mark their commands (OSC 133) report their end.
        var finished: (exitCode: Int?, seconds: TimeInterval)?
        let onCommandFinished = t.onCommandFinished
        t.onCommandFinished = { exitCode, seconds in
            finished = (exitCode, seconds)
            onCommandFinished?(exitCode, seconds)
        }
        t.run("sleep 3")
        check("sees the foreground job", await wait(5) { t.hasForegroundJob })
        check("stopping all counts a shell running a command", ws.stopCounts().commands == 1)
        ws.requestScan?()
        check("shell named after its job", await wait(5) { shell.title == "sleep" }, shell.title)
        check("job ends", await wait(8) { !t.hasForegroundJob })
        _ = await wait(2) { finished != nil }
        lines.append("info command finished: " + (finished.map { "exit \($0.exitCode.map(String.init) ?? "?") after \(elapsed($0.seconds))" } ?? "not reported by \(Launch.shellName)"))
        check("shell name back", await wait(8) { shell.title == Launch.shellName }, shell.title)

        // An agent started from the idle shell takes its place and folder.
        ws.newSession(.codex)
        guard let codex = ws.currentTab, codex.key.agent == .codex else { return finish("no codex tab") }
        let codexKey = codex.key
        codex.turns.userInput()
        check("agent replaces the idle shell", !ws.tabs.contains { $0.key == shellKey })
        check("agent starts in the shell's folder", codex.cwd == tmp || realPath(codex.cwd) == tmp, codex.cwd)
        check("agent runs in the server", await wait(5) { codex.terminal.serverId != nil && codex.terminal.pid != nil })
        check("agent environment", await wait(5) {
            (try? String(contentsOfFile: agentEnvFile, encoding: .utf8)) == "ghostty xterm-ghostty"
        }, (try? String(contentsOfFile: agentEnvFile, encoding: .utf8)) ?? "no file")
        check("agent busy from its title", await wait(5) { codex.isBusy })
        check("stopping all counts a working agent", ws.stopCounts().working == 1)

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

        // An agent that quits while the user looks at another tab: the user
        // is told, and its row stays until closed.
        ws.newSession(.shell, cwd: tmp)
        guard let shown = ws.currentTab else { return finish("no shell to look at") }
        ws.newSession(.codex, cwd: tmp)
        guard let quitter = ws.currentTab, quitter.key.agent == .codex else { return finish("no codex tab to quit") }
        let quitKey = quitter.key
        // As a click in the list does; the list follows its selection.
        ws.selection = shown.key
        ws.open(shown.key)
        check("back on the shell", ws.current == shown.key)
        // Past the first seconds, where a quit means it failed to start.
        _ = await wait(3.5) { false }
        quitter.terminal.run("")
        _ = await wait(0.3) { false }
        quitter.terminal.run("")
        check("notice when an agent quits while away", await wait(5) {
            self.notices.contains { $0.key == quitKey && $0.message?.hasPrefix("It quit") == true }
        })
        check("quit agent's row stays, marked", ws.quitKeys.contains(quitKey) && ws.tabs.contains { $0 === quitter })
        ws.cycle(1)
        check("moving around keeps the quit agent's row", ws.quitKeys.contains(quitKey))
        ws.close(quitKey)
        check("closing the quit agent's row removes it", !ws.quitKeys.contains(quitKey) && ws.tabs.count == 1)
        ws.close(shown.key)

        // An agent in the server keeps running when the app lets go of it,
        // as when the app quits, and comes back with its screen.
        ws.newSession(.codex, cwd: tmp)
        guard let kept = ws.currentTab, kept.key.agent == .codex else { return finish("no codex tab to keep") }
        check("agent's screen", await wait(5) { kept.terminal.screenText?.contains("codex ready") == true }, kept.terminal.screenText ?? "nil")
        let keptPid = kept.terminal.pid ?? 0
        let keptTab = ws.savedState().tabs.first { $0.server != nil && $0.server == kept.terminal.serverId }
        check("saved state names the agent in the server", keptTab != nil)
        kept.terminal.detach()
        ws.close(kept.key)
        _ = await wait(1) { false }
        check("agent keeps running without the app", keptPid > 0 && kill(keptPid, 0) == 0)
        let running = (try? serverSessions()) ?? []
        check("server lists the agent", running.contains { $0.pid == keptPid }, "\(running.count) running")
        _ = ws.restore(SavedState(tabs: keptTab.map { [$0] } ?? [], active: 0), running: running)
        guard let back = ws.currentTab, back.key.agent == .codex else { return finish("agent not shown again") }
        check("restore attaches to the running agent", back.terminal.pid == keptPid)
        check("its screen comes back", await wait(5) { back.terminal.screenText?.contains("codex ready") == true }, back.terminal.screenText ?? "nil")
        back.terminal.run("")
        _ = await wait(0.3) { false }
        back.terminal.run("")
        check("typing reaches it, and its exit is seen", await wait(5) { !back.isRunning })
        if ws.currentTab?.placeholder == true, let key = ws.currentTab?.key { ws.close(key) }

        // Quitting stops only shells that run nothing. One with a job, even
        // in the background, keeps running, like the agents.
        ws.newSession(.shell, cwd: tmp)
        guard let idleShell = ws.currentTab else { return finish("no idle shell") }
        ws.newSession(.shell, cwd: tmp)
        guard let jobShell = ws.currentTab, jobShell !== idleShell else { return finish("no shell for a job") }
        check("shells start", await wait(10) { idleShell.terminal.pid != nil && jobShell.terminal.pid != nil })
        jobShell.terminal.run("sleep 30 &")
        check("a background job counts as running something", await wait(5) {
            jobShell.terminal.hasJobs && !jobShell.terminal.hasForegroundJob && !idleShell.terminal.hasJobs
        })
        let idlePid = idleShell.terminal.pid ?? 0
        let jobPid = jobShell.terminal.pid ?? 0
        ws.stopIdleShells()
        check("quitting stops a shell that runs nothing", await wait(5) { idlePid > 0 && kill(idlePid, 0) != 0 })
        check("quitting keeps a shell with a job", jobPid > 0 && kill(jobPid, 0) == 0 && jobShell.isRunning)
        ws.close(jobShell.key)
        check("closing it ends the shell", await wait(5) { kill(jobPid, 0) != 0 })
        check("no tabs left", await wait(5) { ws.tabs.isEmpty }, "\(ws.tabs.count) left")

        // A pinned tab can't be closed, goes first in the list, and stays
        // when its program ends, until the user opens it again.
        ws.newSession(.shell, cwd: tmp)
        guard let pinned = ws.currentTab else { return finish("no shell to pin") }
        ws.newSession(.shell, cwd: tmp)
        guard let unpinned = ws.currentTab else { return finish("no second shell") }
        ws.setPinned(pinned.key, true)
        check("pinned row goes first", ws.rows.first?.key == pinned.key && ws.rows.first?.pinned == true)
        ws.close(pinned.key)
        check("pinned tab is not closed", ws.tabs.contains { $0 === pinned })
        check("saved state keeps the pin", ws.savedState().tabs.first?.pinned == true)
        pinned.terminal.run("exit")
        check("pinned tab stays when its shell exits", await wait(5) { !pinned.isRunning && ws.tabs.contains { $0 === pinned } })
        ws.open(unpinned.key)
        check("moving around keeps the ended pinned tab", ws.tabs.contains { $0 === pinned })
        ws.open(pinned.key)
        check("opening the ended pinned tab starts it again", ws.currentTab.map { $0.pinned && $0.isRunning && $0 !== pinned } ?? false)
        if let key = ws.currentTab?.key {
            ws.setPinned(key, false)
            ws.close(key)
        }
        ws.close(unpinned.key)
        check("unpinned tab closes", ws.tabs.isEmpty, "\(ws.tabs.count) left")

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
        // Ends the server's agents; then it exits by itself.
        _ = try? stopServerSessions()
        try? (lines.joined(separator: "\n") + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        exit(failed ? 1 : 0)
    }
}

private func processName(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

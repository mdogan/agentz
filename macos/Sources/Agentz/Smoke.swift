import AgentzCore
import AppKit

/// A scripted check of the real app with real Ghostty terminals, started by
/// `make smoke`. It opens shells and a stand-in `codex`, types commands and
/// checks what agentz sees, then writes PASS or FAIL lines to
/// `AGENTZ_SMOKE_LOG` and quits. It neither restores nor saves tabs.
@MainActor
final class SmokeTest {
    private let workspace: Workspace
    private let window: MainWindowController
    private let quick: QuickTerminal
    private let logPath: String
    private var lines: [String] = []
    private var failed = false
    private var notices: [(key: SessionKey, heading: String, message: String?)] = []

    static var logPath: String? {
        ProcessInfo.processInfo.environment["AGENTZ_SMOKE_LOG"]
    }

    init(workspace: Workspace, window: MainWindowController, quick: QuickTerminal, logPath: String) {
        self.workspace = workspace
        self.window = window
        self.quick = quick
        self.logPath = logPath
    }

    /// Stands in for Claude: writes its arguments to `claude-args` next to
    /// its folder, one per line, waits for a line and writes it to
    /// `claude-input`. Terminals keep the environment the first one got, so
    /// a variable set later would not reach it.
    private static let fakeClaude = #"""
    #!/bin/sh
    printf '%s\n' "$@" > "$(dirname "$0")/../claude-args"
    read line
    printf '%s\n' "$line" > "$(dirname "$0")/../claude-input"
    """#

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
        ws.notify = { [weak self] heading, title, message, key in
            self?.notices.append((key, heading, message))
            notify?(heading, title, message, key)
        }
        let tmp = (realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/agentz-smoke-\(getpid())"
        let bin = tmp + "/bin"
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        FileManager.default.createFile(atPath: bin + "/codex", contents: Data(Self.fakeCodex.utf8), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: bin + "/claude", contents: Data(Self.fakeClaude.utf8), attributes: [.posixPermissions: 0o755])
        setenv("PATH", bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        let envFile = tmp + "/env"

        lines.append("info ghostty config: \(GhosttyApp.configIssue.map { "not used: \($0)" } ?? "used")")

        // `make smoke` opens this repo.
        check("worktrees of the repo are listed", await wait(10) { ws.currentWorktree != nil }, "\(ws.worktrees.count) worktrees")

        // A shell: its pid, environment, folder and foreground job.
        ws.newSession(.shell, cwd: ws.shownFolder)
        guard let shell = ws.currentTab else { return finish("no tab after newSession") }
        let shellKey = shell.key
        let t = shell.terminal!
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

        // Only shells that mark their commands (OSC 133) report their end.
        var finished: (exitCode: Int?, seconds: TimeInterval)?
        let onCommandFinished = t.onCommandFinished
        t.onCommandFinished = { exitCode, seconds in
            finished = (exitCode, seconds)
            onCommandFinished?(exitCode, seconds)
        }
        t.run("sleep 3")
        check("sees the foreground job", await wait(5) { t.hasForegroundJob })
        check("quit counts a shell running a command", ws.quitCounts().commands == 1)
        ws.requestScan?()
        check("shell named after its job", await wait(5) { shell.title == "sleep" }, shell.title)
        check("job ends", await wait(8) { !t.hasForegroundJob })
        _ = await wait(2) { finished != nil }
        lines.append("info command finished: " + (finished.map { "exit \($0.exitCode.map(String.init) ?? "?") after \(elapsed($0.seconds))" } ?? "not reported by \(Launch.shellName)"))
        check("shell name back", await wait(8) { shell.title == Launch.shellName }, shell.title)

        // ⌘T asks where to start; ⎋ starts nothing.
        let app = NSApp.delegate as! AppDelegate
        let tabCount = ws.tabs.count
        app.newShell(nil)
        check("⌘T asks where to start", await pickerField() != nil)
        if let sheet = window.window?.attachedSheet { press(.escape, in: sheet) }
        check("⎋ closes it", await wait(3) { self.window.window?.attachedSheet == nil })
        check("and starts nothing", ws.tabs.count == tabCount && ws.currentTab === shell)

        // ⇧⌘N picks the idle shell's folder at first, and ↩ starts the agent
        // there, in place of the shell. The temporary folder does not go to
        // the user's recent folders.
        let recents = UserDefaults.standard.stringArray(forKey: "recentFolders")
        app.newCodex(nil)
        check("⇧⌘N asks where to start", await pickerField() != nil)
        if let sheet = window.window?.attachedSheet { press(.return, in: sheet) }
        check("↩ closes it", await wait(3) { self.window.window?.attachedSheet == nil })
        _ = await wait(3) { ws.currentTab?.key.agent == .codex }
        guard let codex = ws.currentTab, codex.key.agent == .codex else { return finish("no codex tab") }
        let codexKey = codex.key
        codex.turns.userInput()
        check("agent replaces the idle shell", !ws.tabs.contains { $0.key == shellKey })
        check("agent starts in the shell's folder", codex.cwd == tmp || realPath(codex.cwd) == tmp, codex.cwd)
        check("the recent folders stay as they were", UserDefaults.standard.stringArray(forKey: "recentFolders") == recents)
        check("agent busy from its title", await wait(5) { codex.isBusy })
        check("quit counts a working agent", ws.quitCounts().working == 1)

        // Another tab, so the agent is not looked at and may notify.
        ws.newSession(.shell, cwd: tmp)
        guard let other = ws.currentTab, other.key.agent == .shell else { return finish("no second shell") }
        check("notice when the agent is done", await wait(8) { self.notices.contains { $0.key == codexKey && $0.message == nil } })
        check("one notice per turn", notices.filter { $0.key == codexKey }.count == 1)
        codex.turns.userInput()
        codex.terminal!.run("")
        check("agent's own notification text", await wait(5) { self.notices.contains { $0.key == codexKey && $0.message == "Done: OK" } })
        check("the agent wants the user, with what it said", await wait(2) {
            ws.attentionKeys == [codexKey] && ws.waitingMessages[codexKey] == "Done: OK"
        }, "\(ws.attentionKeys) \(ws.waitingMessages)")

        snapshot()

        let state = ws.savedState()
        check("saved state has both tabs", state.tabs.count == 2, "\(state.tabs.count)")
        check("saved active tab", state.active == 1)

        // Going to the session that needs the user shows it, and then it
        // no longer does. The shown agent quits: a shell takes its place.
        ws.showNextAttention()
        check("switch to the agent", ws.current == codexKey)
        check("looking at it ends the attention", await wait(2) { ws.attentionKeys.isEmpty && ws.waitingMessages.isEmpty })
        codex.terminal!.run("")
        check("quit agent is replaced by a shell", await wait(5) {
            ws.currentTab?.key.agent == .shell && ws.currentTab?.placeholder == true && !ws.tabs.contains { $0.key == codexKey }
        })

        // Exiting a shell closes its tab.
        other.terminal!.run("exit")
        check("exited shell tab is removed", await wait(5) { !ws.tabs.contains { $0 === other } })

        // Closing a tab hangs up on its program.
        let placeholderPid = ws.currentTab?.terminal!.pid
        weak let closedView = ws.currentTab?.terminal!.view
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
        quitter.terminal!.run("")
        _ = await wait(0.3) { false }
        quitter.terminal!.run("")
        check("notice when an agent quits while away", await wait(5) {
            self.notices.contains { $0.key == quitKey && $0.message?.hasPrefix("It quit") == true }
        })
        check("quit agent's row stays, marked", ws.quitKeys.contains(quitKey) && ws.attentionKeys == [quitKey]
            && ws.tabs.contains { $0 === quitter })
        ws.cycle(1)
        check("moving around keeps the quit agent's row", ws.quitKeys.contains(quitKey))
        ws.close(quitKey)
        check("closing the quit agent's row removes it", !ws.quitKeys.contains(quitKey) && ws.tabs.count == 1)
        ws.close(shown.key)

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
        pinned.terminal!.run("exit")
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

        // A split shows two tabs. The new pane gets the focus and a shell in
        // the shown tab's folder.
        ws.newSession(.shell, cwd: tmp)
        guard let left = ws.currentTab else { return finish("no shell to split") }
        ws.split(.right)
        guard let right = ws.currentTab, right !== left else { return finish("no shell in the new pane") }
        let leftView = left.terminal!.view, rightView = right.terminal!.view
        check("split shows both tabs", ws.panes.keys == [left.key, right.key] && ws.panes.focused == 1)
        check("both terminals are visible", !leftView.isHidden && !rightView.isHidden)
        check("panes side by side", leftView.frame.maxX < rightView.frame.minX && leftView.frame.height == rightView.frame.height
            && abs(leftView.frame.width - rightView.frame.width) <= 1, "\(leftView.frame) \(rightView.frame)")
        check("new pane starts in the shown tab's folder", right.cwd == tmp || realPath(right.cwd) == tmp, right.cwd)

        // A click into a terminal works in its pane.
        left.terminal!.focus()
        check("focus follows the terminal", ws.panes.focused == 0 && ws.selection == left.key)

        // The list puts the split's two sessions together and marks them.
        let at = ws.rows.firstIndex { $0.key == left.key }
        check("the list shows the split", at.map { ws.rows.indices.contains($0 + 1) && ws.rows[$0 + 1].key == right.key } ?? false
            && ws.rows[at!].pane == SplitPane(direction: .right, index: 0, partner: right.key, shown: true)
            && ws.rows[at!].box == .top && ws.rows[at! + 1].box == .bottom, "\(ws.rows.map(\.key))")

        // A new session opens on its own. The split waits off screen, as it
        // was, divider and all.
        ws.setRatio(0.3)
        ws.newSession(.shell, cwd: tmp)
        guard let third = ws.currentTab, third !== left, third !== right else { return finish("no shell to show on its own") }
        let thirdView = third.terminal!.view
        check("a new session opens on its own", ws.panes == PaneLayout(keys: [third.key])
            && ws.hiddenSplits == [PaneLayout(keys: [left.key, right.key], split: .right, focused: 0, ratio: 0.3)],
            "\(ws.panes) \(ws.hiddenSplits)")
        check("the split's tabs run on, hidden", left.isRunning && right.isRunning && leftView.isHidden && rightView.isHidden
            && thirdView.frame == thirdView.superview?.bounds)
        check("the list marks the hidden split", ws.rows.first { $0.key == right.key }?.pane
            == SplitPane(direction: .right, index: 1, partner: left.key, shown: false))

        // Picking one of its sessions brings it back. Picking another hides
        // it again; its panes never change.
        pick(right.key)
        check("picking a split's session brings the split back",
            ws.panes == PaneLayout(keys: [left.key, right.key], split: .right, focused: 1, ratio: 0.3) && ws.hiddenSplits.isEmpty,
            "\(ws.panes)")
        check("as it was", !leftView.isHidden && !rightView.isHidden && thirdView.isHidden
            && leftView.frame.width < rightView.frame.width, "\(leftView.frame) \(rightView.frame)")
        pick(third.key)
        check("picking another session hides it again", ws.panes == PaneLayout(keys: [third.key])
            && ws.hiddenSplits.map(\.keys) == [[left.key, right.key]])
        var intact = true
        for _ in 0 ..< 6 {
            ws.cycle(1)
            let splits = (ws.panes.split != nil ? [ws.panes] : []) + ws.hiddenSplits
            intact = intact && splits.map(\.keys) == [[left.key, right.key]]
        }
        check("cycling leaves the split as it is", intact)

        // Opening the session in the other pane moves there.
        pick(left.key)
        ws.open(right.key)
        check("opening a shown session focuses its pane", ws.panes.focused == 1 && ws.panes.keys == [left.key, right.key])

        ws.split(.down)
        check("split turns down", ws.panes.split == .down && leftView.frame.minY > rightView.frame.maxY
            && leftView.frame.width == rightView.frame.width, "\(leftView.frame) \(rightView.frame)")

        // A second split, while the first waits off screen.
        pick(third.key)
        ws.split(.right)
        guard let fourth = ws.currentTab, fourth !== third else { return finish("no shell in the second split") }
        check("a second split", ws.panes.keys == [third.key, fourth.key] && ws.hiddenSplits.map(\.keys) == [[left.key, right.key]])
        // Saved with the tabs: the shown split with `fourth` focused, and the
        // hidden one with `right` focused.
        let splitState = ws.savedState()
        let savedKeys = { (split: SavedSplit?) in
            split?.panes.map { $0.flatMap { i in ws.tabs.indices.contains(Int(i)) ? ws.tabs[Int(i)].key : nil } }
        }
        check("saved state keeps both splits", splitState.split?.direction == .right && splitState.split?.focused == 1
            && savedKeys(splitState.split) == [third.key, fourth.key] && splitState.active == splitState.split?.panes[1]
            && splitState.hiddenSplits.map(\.direction) == [.down] && splitState.hiddenSplits.first?.focused == 1
            && savedKeys(splitState.hiddenSplits.first) == [left.key, right.key],
            "\(String(describing: splitState.split)) \(splitState.hiddenSplits) active=\(String(describing: splitState.active))")

        // Unsplitting keeps the focused pane's tab; the other one runs on.
        ws.unsplit()
        check("unsplit keeps the focused tab", ws.panes == PaneLayout(keys: [fourth.key]))
        check("it fills the pane again", fourth.terminal!.view.frame == fourth.terminal!.view.superview?.bounds, "\(fourth.terminal!.view.frame)")
        check("the other tab runs on, hidden", third.isRunning && thirdView.isHidden)
        check("the hidden split stays", ws.hiddenSplits.map(\.keys) == [[left.key, right.key]])

        // A shell a split opened, that nobody typed in, goes once it is in
        // no split and the user moves on.
        pick(left.key)
        check("the untouched shell goes when the user moves on", !ws.tabs.contains { $0 === fourth })
        ws.unsplit()
        check("unsplitting drops the split's untouched shell", ws.panes == PaneLayout(keys: [left.key]) && !ws.tabs.contains { $0 === right })

        // Closing a pane's tab, or exiting its shell, ends the split.
        ws.split(.right)
        guard let fifth = ws.currentTab, fifth !== left else { return finish("no shell in the third split") }
        ws.close(fifth.key)
        check("closing a pane's tab ends the split", ws.panes == PaneLayout(keys: [left.key]) && !ws.tabs.contains { $0 === fifth })
        ws.split(.down)
        guard let sixth = ws.currentTab, sixth !== left else { return finish("no shell in the fourth split") }
        _ = await wait(5) { sixth.terminal!.pid != nil }
        sixth.terminal!.run("exit")
        check("an exited shell ends the split", await wait(5) { ws.panes == PaneLayout(keys: [left.key]) }, "\(ws.panes.keys)")
        // The same off screen.
        ws.split(.right)
        guard let seventh = ws.currentTab, seventh !== left else { return finish("no shell in the fifth split") }
        pick(third.key)
        ws.close(left.key)
        check("closing a session of a hidden split ends it", ws.hiddenSplits.isEmpty && !ws.tabs.contains { $0 === seventh })
        for tab in ws.tabs {
            ws.close(tab.key)
        }
        check("split tabs close", ws.tabs.isEmpty, "\(ws.tabs.count) left")

        // Restoring brings both splits back, each tab in its pane.
        _ = ws.restore(splitState)
        let restoredKeys = { (split: SavedSplit?) in
            split?.panes.map { $0.flatMap { i in ws.tabs.indices.contains(Int(i)) ? ws.tabs[Int(i)].key : nil } }
        }
        let restoredOK = ws.tabs.count == 4 && ws.panes.split == .right && ws.panes.focused == 1
            && restoredKeys(splitState.split) == ws.panes.keys
            && ws.hiddenSplits.map(\.split) == [.down] && ws.hiddenSplits.first?.focused == 1
            && restoredKeys(splitState.hiddenSplits.first) == ws.hiddenSplits.first?.keys
        check("restore brings both splits back", restoredOK, "\(ws.panes) \(ws.hiddenSplits) of \(ws.tabs.map(\.key))")
        if let first = ws.panes.keys[0].flatMap({ key in ws.tabs.first { $0.key == key } }),
           let second = ws.panes.keys.last?.flatMap({ key in ws.tabs.first { $0.key == key } })
        {
            check("restored panes are laid out", !first.terminal!.view.isHidden && !second.terminal!.view.isHidden
                && first.terminal!.view.frame.maxX < second.terminal!.view.frame.minX,
                "\(first.terminal!.view.frame) \(second.terminal!.view.frame)")
        }
        for tab in ws.tabs {
            ws.close(tab.key)
        }
        // A split whose tabs can't open is not restored.
        _ = ws.restore(SavedState(
            tabs: [SavedTab(agent: .shell, id: nil, cwd: missing, title: "missing")],
            split: SavedSplit(direction: .right, panes: [0, nil], focused: 0)
        ))
        check("no split without its tabs", ws.panes.split == nil && ws.tabs.isEmpty, "\(ws.panes)")

        // A session from the list opens next to the shown one.
        ws.newSession(.shell, cwd: tmp)
        guard let offScreen = ws.currentTab else { return finish("no shell to open in a split") }
        ws.newSession(.shell, cwd: tmp)
        guard let onScreen = ws.currentTab, onScreen !== offScreen else { return finish("no shell to split from") }
        check("the shown session can't split off from itself", !ws.canOpenInSplit(onScreen.key) && ws.canOpenInSplit(offScreen.key))
        ws.openInSplit(offScreen.key, .right)
        check("a session opens in the right pane", ws.panes == PaneLayout(keys: [onScreen.key, offScreen.key], split: .right, focused: 1)
            && ws.selection == offScreen.key, "\(ws.panes)")
        ws.openInSplit(onScreen.key, .down)
        check("the other pane's session trades places", ws.panes == PaneLayout(keys: [offScreen.key, onScreen.key], split: .down, focused: 1),
            "\(ws.panes)")
        ws.toggleSplit(.down)
        check("the same split again unsplits", ws.panes == PaneLayout(keys: [onScreen.key]), "\(ws.panes)")
        // Out of a hidden split, which ends.
        ws.split(.right)
        guard let untouched = ws.currentTab, untouched !== onScreen else { return finish("no shell in the split to hide") }
        pick(offScreen.key)
        ws.openInSplit(onScreen.key, .down)
        check("a session moves out of a hidden split, which ends",
            ws.panes == PaneLayout(keys: [offScreen.key, onScreen.key], split: .down, focused: 1) && ws.hiddenSplits.isEmpty
                && !ws.tabs.contains { $0 === untouched }, "\(ws.panes) \(ws.hiddenSplits)")
        for tab in ws.tabs {
            ws.close(tab.key)
        }
        let accessories = NSApp.windows.first { $0.isVisible }?.titlebarAccessoryViewControllers ?? []
        check("split buttons in the title bar", accessories.contains { $0.layoutAttribute == .trailing && !$0.view.isHidden })

        // Dragging a session from the list onto the pane area.
        guard let pane = NSApp.windows.first(where: { $0.isVisible })?.contentView.flatMap(paneContainer)
        else { return finish("no pane area to drag to") }
        ws.newSession(.shell, cwd: tmp)
        guard let dragged = ws.currentTab else { return finish("no shell to drag") }
        ws.newSession(.shell, cwd: tmp)
        guard let target = ws.currentTab, target !== dragged else { return finish("no shell to drag onto") }
        // `x` and `y` are shares of the pane area, from its top left.
        func drag(_ key: SessionKey, _ x: CGFloat, _ y: CGFloat) -> FakeDrag {
            let b = pane.bounds
            return FakeDrag(key, at: pane.convert(NSPoint(x: b.width * x, y: b.height * (1 - y)), to: nil))
        }
        check("the shown session can't be dropped on itself", pane.draggingEntered(drag(target.key, 0.9, 0.5)) == [])
        pane.draggingExited(nil)
        let toLeft = drag(dragged.key, 0.1, 0.5)
        check("near the left edge, the left half lights up", pane.draggingEntered(toLeft) != [] && !pane.highlight.isHidden
            && pane.highlight.frame.maxX < pane.bounds.midX, "\(pane.highlight.frame)")
        check("dropping it there", pane.performDragOperation(toLeft))
        pane.draggingEnded(toLeft)
        check("the session lands on the left", ws.panes == PaneLayout(keys: [dragged.key, target.key], split: .right, focused: 0), "\(ws.panes)")
        check("the highlight goes away", pane.highlight.isHidden)
        ws.unsplit()
        let toBottom = drag(target.key, 0.5, 0.95)
        check("near the bottom edge, the bottom half lights up", pane.draggingEntered(toBottom) != []
            && pane.highlight.frame.maxY < pane.bounds.midY, "\(pane.highlight.frame)")
        _ = pane.performDragOperation(toBottom)
        pane.draggingEnded(toBottom)
        check("the session lands below", ws.panes == PaneLayout(keys: [dragged.key, target.key], split: .down, focused: 1), "\(ws.panes)")
        let onto = drag(dragged.key, 0.5, 0.75)
        check("in a split, the pane under it lights up", pane.draggingEntered(onto) != [] && pane.highlight.frame.maxY < pane.bounds.midY)
        _ = pane.performDragOperation(onto)
        pane.draggingEnded(onto)
        check("dropped on the other pane, they trade places", ws.panes == PaneLayout(keys: [target.key, dragged.key], split: .down, focused: 1),
            "\(ws.panes)")
        let fromElsewhere = FakeDrag(dragged.key, at: .zero, source: nil)
        check("drags from other apps are refused", pane.draggingEntered(fromElsewhere) == [])
        pane.draggingExited(nil)
        ws.unsplit()
        for tab in ws.tabs {
            ws.close(tab.key)
        }

        // A click into the other pane works in it, and ends: moving the
        // mouse afterwards does not select text.
        ws.newSession(.shell, cwd: tmp)
        guard let first = ws.currentTab else { return finish("no shell to click") }
        first.terminal!.view.window?.makeFirstResponder(nil)
        click(first.terminal!.view, at: NSPoint(x: 40, y: 40))
        check("a click reaches the only terminal", first.terminal!.isFocused)
        ws.split(.right)
        guard let second = ws.currentTab, second !== first else { return finish("no second pane to click from") }
        _ = await wait(5) { first.terminal!.pid != nil && second.terminal!.pid != nil }
        first.terminal!.run("echo one two three four five six seven eight nine ten")
        second.terminal!.run("echo one two three four five six seven eight nine ten")
        _ = await wait(1) { false }
        let firstView = first.terminal!.view
        click(firstView, at: NSPoint(x: 40, y: firstView.bounds.height - 10))
        _ = await wait(0.5) { false }
        check("a click focuses the other pane", ws.panes.focused == 0 && firstView.window?.firstResponder === firstView,
            "focused=\(ws.panes.focused) responder=\(String(describing: firstView.window?.firstResponder))")
        move(firstView, to: NSPoint(x: 300, y: firstView.bounds.height - 10))
        _ = await wait(0.3) { false }
        check("the click ends with the mouse up", firstView.selectionMenuPoint(at: .zero) == nil)
        move(second.terminal!.view, to: NSPoint(x: 300, y: firstView.bounds.height - 10))
        _ = await wait(0.3) { false }
        check("the pane left behind has no click stuck either", second.terminal!.view.selectionMenuPoint(at: .zero) == nil)
        // A mouse-up that another window got, e.g. another app's that came
        // to the front in the middle of a drag, ends the click here too.
        press(firstView, at: NSPoint(x: 40, y: firstView.bounds.height - 10))
        let held = firstView.isLeftButtonDown
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: firstView.window)
        move(firstView, to: NSPoint(x: 300, y: firstView.bounds.height - 10))
        _ = await wait(0.3) { false }
        check("a mouse-up lost to another window ends the click too",
              held && !firstView.isLeftButtonDown && firstView.selectionMenuPoint(at: .zero) == nil)
        click(second.terminal!.view, at: NSPoint(x: 40, y: firstView.bounds.height - 10))
        _ = await wait(0.5) { false }
        check("a click focuses the first pane again", ws.panes.focused == 1 && firstView.window?.firstResponder === second.terminal!.view)
        // ⌘N starts an agent in place of the split's idle shell. ⌘T opens a
        // shell on its own.
        ws.newSession(.codex, cwd: ws.shownFolder, inPlaceOfShell: true)
        check("an agent takes the idle shell's pane", ws.panes.split == .right && ws.panes.keys[0] == first.key
            && ws.currentTab?.key.agent == .codex && !ws.tabs.contains { $0 === second }, "\(ws.panes)")
        ws.newSession(.shell, cwd: tmp, inPlaceOfShell: true)
        check("a new shell leaves the split as it is", ws.panes.split == nil && ws.hiddenSplits.first?.keys.first == first.key)
        for tab in ws.tabs {
            ws.close(tab.key)
        }

        // Auto-hide: the list leaves the split and slides in over the
        // terminal, which keeps its size. A point stands in for the mouse.
        ws.newSession(.shell, cwd: tmp)
        guard let under = ws.currentTab else { return finish("no shell for auto-hide") }
        let underView = under.terminal!.view
        let overlay = window.overlay
        let narrow = underView.frame.width
        window.setAutoHide(true)
        check("auto-hide gives the terminal the whole window", await wait(2) { underView.frame.width > narrow } && overlay.panel.isHidden,
            "\(narrow) -> \(underView.frame.width)")
        let wide = underView.frame.width
        lines.append("info list width: \(overlay.panel.frame.width), terminal \(narrow) -> \(wide)")
        window.focusSidebar(.list)
        check("⌘L shows the list over the terminal", overlay.isShown && overlay.held && !overlay.panel.isHidden && underView.frame.width == wide)
        check("the list gets the keyboard", await wait(2) { overlay.hasFocus })
        window.focusTerminal()
        check("going to the terminal hides it", !overlay.isShown && under.terminal!.isFocused)
        check("it slides away", await wait(1) { overlay.panel.isHidden })
        let mouse = overlay.mouseLocation
        var pointer = NSPoint(x: 2, y: 200)
        overlay.mouseLocation = { pointer }
        overlay.edgeEntered()
        check("resting the mouse at the left edge shows it", await wait(1) { overlay.isShown } && !overlay.held)
        pointer = NSPoint(x: overlay.panel.frame.width + 100, y: 200)
        check("moving the mouse off it hides it", await wait(2) { !overlay.isShown })
        pointer = NSPoint(x: 2, y: 200)
        overlay.edgeEntered()
        _ = await wait(1) { overlay.isShown }
        window.sidebarFocus.request(.filter)
        check("its filter can be typed in", await wait(2) { overlay.editingFilter })
        pointer = NSPoint(x: overlay.panel.frame.width + 100, y: 200)
        check("typing in the filter holds it", await wait(1.5) { overlay.held } && overlay.isShown)
        click(underView, at: NSPoint(x: underView.bounds.width - 40, y: 40))
        check("a click outside hides it", !overlay.isShown && under.terminal!.isFocused)
        overlay.mouseLocation = mouse
        window.setAutoHide(false)
        check("off again, the list is back in the split", await wait(2) { abs(underView.frame.width - narrow) <= 1 }
            && overlay.panel.superview == nil, "\(narrow) -> \(underView.frame.width)")

        for tab in ws.tabs {
            ws.close(tab.key)
        }

        await awayAndLater(tmp)
        await leftRunning(tmp)
        await continueAtReset(tmp)
        await sleepWhileWorking(tmp)
        await runningElsewhere(tmp)
        await wheelWithoutClick(tmp)
        await find(tmp)
        await quickTerminal(tmp)
        await gitPanel(tmp)
        await gitTab(tmp)
        finish(nil)
    }

    /// Drives busy/idle signals through real terminals and the workspace:
    /// hidden and filtered agents still count, ordinary shells do not.
    private func sleepWhileWorking(_ tmp: String) async {
        let ws = workspace
        let oldElsewhere = ws.elsewhere
        // Ignore real agents outside this smoke run for these checks.
        func applyElsewhere(_ elsewhere: [RunningElsewhere]) {
            ws.apply(Scan(sessions: nil, complete: true, shells: [], codexThreads: [:], limits: ws.limits,
                          worktrees: ws.worktrees, elsewhere: elsewhere, leftovers: []), dir: tmp)
        }
        applyElsewhere([])
        defer {
            applyElsewhere(Array(oldElsewhere.values))
            ws.filter = ""
            for tab in ws.tabs { ws.close(tab.key) }
        }
        ws.newSession(.shell, cwd: tmp)
        guard let shell = ws.currentTab else { return check("shell for sleep checks", false) }
        shell.turns.receive(.progress(true))
        ws.tick()
        check("shell progress does not block sleep", !ws.sleepBlocker.isBlocking)
        shell.linked = SessionKey(.claude, "sleep-linked")
        ws.tick()
        check("an agent linked to a shell blocks sleep", ws.sleepBlocker.isBlocking)
        shell.linked = nil
        ws.tick()

        ws.start(.claude, resume: nil, cwd: tmp, title: "Sleep check 1")
        guard let first = ws.currentTab else { return check("first agent for sleep checks", false) }
        first.turns.receive(.progress(true))
        ws.tick()
        check("a working agent blocks sleep", ws.sleepBlocker.isBlocking)
        ws.start(.claude, resume: nil, cwd: tmp, title: "Sleep check 2")
        guard let second = ws.currentTab else { return check("second agent for sleep checks", false) }
        second.turns.receive(.progress(true))
        ws.tick()
        first.turns.receive(.progress(false))
        ws.tick()
        check("one idle agent does not release another's sleep blocker", ws.sleepBlocker.isBlocking)
        ws.open(shell.key)
        ws.filter = "no session matches this sleep check"
        ws.tick()
        check("an agent off screen and filtered out still blocks sleep", ws.rows.isEmpty && ws.sleepBlocker.isBlocking)
        second.turns.receive(.progress(false))
        ws.tick()
        check("all agents idle releases the sleep blocker", !ws.sleepBlocker.isBlocking)
        second.turns.receive(.progress(true))
        ws.tick()
        ws.close(second.key)
        check("closing the last working agent releases the sleep blocker", !ws.sleepBlocker.isBlocking)

        first.turns.receive(.progress(true))
        ws.tick()
        check("another turn blocks sleep again", ws.sleepBlocker.isBlocking)
        first.terminal!.run("")
        check("an agent exiting releases the sleep blocker", await wait(5) {
            applyElsewhere([])
            return !first.isRunning && !ws.sleepBlocker.isBlocking
        })
        applyElsewhere([RunningElsewhere(id: "sleep-elsewhere", busy: true, app: nil)])
        check("a working agent in another app blocks sleep", ws.sleepBlocker.isBlocking)
        applyElsewhere([RunningElsewhere(id: "sleep-elsewhere", busy: false, app: nil)])
        check("an idle agent in another app releases the sleep blocker", !ws.sleepBlocker.isBlocking)
        applyElsewhere([RunningElsewhere(id: "sleep-elsewhere", busy: true, app: nil)])
        applyElsewhere([])
        check("an outside agent exiting releases the sleep blocker", !ws.sleepBlocker.isBlocking)
    }

    /// Away from the Mac, an agent in front of the user still tells them
    /// it is done; looking at it ends that. A session put off for later
    /// does not count until then, and then comes back with a reminder.
    private func awayAndLater(_ tmp: String) async {
        let ws = workspace
        var seen: [SessionKey] = []
        let onSeen = ws.onSeen
        ws.onSeen = { key in
            seen.append(key)
            onSeen?(key)
        }
        // Not the window's real state: the user may use another app while
        // this runs.
        let present = ws.isUserPresent
        var away = true
        ws.isUserPresent = { !away }
        defer {
            ws.isUserPresent = present
            ws.onSeen = onSeen
        }

        ws.newSession(.codex, cwd: tmp)
        guard let codex = ws.currentTab, codex.key.agent == .codex else { return check("start an agent to be away from", false) }
        let key = codex.key
        codex.turns.userInput()
        check("away, the agent in front still says it is done", await wait(8) {
            self.notices.contains { $0.key == key } && ws.attentionKeys == [key]
        }, "\(ws.attentionKeys)")
        check("away, it is not seen", !seen.contains(key))
        away = false
        check("back, looking at it ends that", await wait(2) { ws.attentionKeys.isEmpty && seen.contains(key) })

        away = true
        codex.turns.userInput()
        codex.terminal!.run("")
        check("it wants the user again", await wait(5) { ws.attentionKeys == [key] && ws.waitingMessages[key] == "Done: OK" })
        let before = notices.count
        ws.snooze(key, until: Date().addingTimeInterval(1.5))
        check("put off, it does not count", ws.attentionKeys.isEmpty && ws.snoozed[key] != nil && ws.wantsUser(key))
        check("then it is back, with a reminder", await wait(4) {
            ws.attentionKeys == [key] && ws.snoozed.isEmpty
                && self.notices.dropFirst(before).contains { $0.key == key && $0.heading.hasPrefix("Reminder") && $0.message == "Done: OK" }
        }, "\(ws.attentionKeys) \(notices.dropFirst(before).map(\.heading))")
        ws.snooze(key, until: Date().addingTimeInterval(60))
        away = false
        check("looking at it ends the snooze too", await wait(2) { ws.snoozed.isEmpty && ws.attentionKeys.isEmpty })
        // Not in its first seconds, where quitting means it failed to start.
        _ = await wait(max(3.5 - Date().timeIntervalSince(codex.spawnedAt), 0)) { false }
        codex.terminal!.run("")
        _ = await wait(5) { !codex.isRunning }
        for tab in ws.tabs {
            ws.close(tab.key)
        }
    }

    /// A program started in the background in a session's folder, that
    /// runs on after the shell that started it ended, is found and can be
    /// stopped.
    private func leftRunning(_ tmp: String) async {
        let ws = workspace
        let dir = tmp + "/left"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        ws.newSession(.shell, cwd: dir)
        guard let shell = ws.currentTab else { return check("start a shell to leave something running", false) }
        _ = await wait(5) { shell.terminal!.pid != nil }
        shell.terminal!.run("sh -c 'sleep 301 >/dev/null 2>&1 &'")
        check("what was left running is found, for the session in its folder", await wait(12) {
            ws.leftovers[shell.key]?.contains { $0.command == "sleep 301" && $0.processes == 1 } == true
        }, "\(ws.leftovers)")
        let found = ws.leftovers[shell.key] ?? []
        check("stopping it stops it", !found.isEmpty && stopLeftovers(found) == 0)
        ws.requestScan?()
        check("then it is gone", await wait(8) { ws.leftovers[shell.key] == nil }, "\(ws.leftovers)")
        ws.close(shell.key)
    }

    /// A Claude session that stopped at the rate limit gets `continue`
    /// typed in once the limit resets, if the user asked for it.
    private func continueAtReset(_ tmp: String) async {
        let ws = workspace
        let id = UUID().uuidString.lowercased()
        let key = SessionKey(.claude, id)
        let config = tmp + "/claude-limit"
        let input = tmp + "/claude-input"
        let files = FileManager.default
        try? files.createDirectory(atPath: config + "/projects/smoke", withIntermediateDirectories: true)
        // It stopped ten minutes ago, and the limit reset three minutes ago.
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "h:mma"
        let reset = clock.string(from: Date().addingTimeInterval(-180)).lowercased()
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let transcript = #"{"type":"user","cwd":"\#(tmp)","message":{"content":"smoke limit"}}"# + "\n"
            + #"{"type":"assistant","timestamp":"\#(at)","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets \#(reset)"}]}}"#
            + "\n"
        files.createFile(atPath: config + "/projects/smoke/\(id).jsonl", contents: Data(transcript.utf8))
        let oldConfig = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", config, 1)
        defer {
            if let oldConfig { setenv("CLAUDE_CONFIG_DIR", oldConfig, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
        }

        ws.requestScan?()
        check("a stop at the rate limit is found, with when it resets", await wait(10) {
            ws.limitStops[key].map { $0.reset != nil && $0.reset! < Date() } == true
        }, "\(String(describing: ws.limitStops[key]))")
        ws.open(key)
        guard let tab = ws.currentTab, tab.key == key else { return check("resume the session that stopped", false) }
        ws.setContinueAtReset(key, true)
        _ = await wait(Workspace.settleTime - 1) { false }
        check("not before it settled in", (try? String(contentsOfFile: input, encoding: .utf8)) == nil)
        check("it is told to continue", await wait(8) {
            (try? String(contentsOfFile: input, encoding: .utf8)) == "continue\n"
        }, (try? String(contentsOfFile: input, encoding: .utf8)) ?? "no input")
        check("once", ws.continueAtReset.contains(key) && ws.status?.contains("continue") == true)
        ws.setContinueAtReset(key, false)
        for tab in ws.tabs {
            ws.close(tab.key)
        }
    }

    /// A Claude session open in another app is listed and marked. Opening it
    /// here forks it, if the user agrees, and restoring leaves it alone.
    private func runningElsewhere(_ tmp: String) async {
        let ws = workspace
        let id = UUID().uuidString.lowercased()
        let key = SessionKey(.claude, id)
        let config = tmp + "/claude-config"
        let argsFile = tmp + "/claude-args"
        let files = FileManager.default
        try? files.createDirectory(atPath: config + "/projects/smoke", withIntermediateDirectories: true)
        try? files.createDirectory(atPath: config + "/sessions", withIntermediateDirectories: true)
        let transcript = #"{"type":"user","cwd":"\#(tmp)","gitBranch":"fix/smoke","message":{"content":"smoke elsewhere"}}"#
            + "\n" + #"{"type":"pr-link","prNumber":7,"prUrl":"https://github.com/o/r/pull/7"}"# + "\n"
        files.createFile(atPath: config + "/projects/smoke/\(id).jsonl", contents: Data(transcript.utf8))
        // Its shell exits at once, so launchd adopts it: not under agentz.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"]
        let out = Pipe()
        sh.standardOutput = out
        guard (try? sh.run()) != nil else { return check("start a process outside agentz", false) }
        sh.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return check("start a process outside agentz", false, text)
        }
        defer { kill(pid, SIGTERM) }
        let startedAt = Int(Date().timeIntervalSince1970 * 1000)
        files.createFile(
            atPath: config + "/sessions/\(pid).json",
            contents: Data(#"{"pid":\#(pid),"sessionId":"\#(id)","startedAt":\#(startedAt),"status":"busy"}"#.utf8)
        )
        let oldConfig = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", config, 1)
        defer {
            if let oldConfig { setenv("CLAUDE_CONFIG_DIR", oldConfig, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
        }

        ws.requestScan?()
        check("a session running elsewhere is listed and marked", await wait(10) {
            ws.elsewhere[key]?.busy == true && ws.rows.contains { $0.key == key }
        }, "\(ws.elsewhere)")
        let row = ws.rows.first { $0.key == key }
        check("its row has the branch and the pull request", row?.branch == "fix/smoke" && row?.pr?.number == 7,
            "\(String(describing: row?.branch)) \(String(describing: row?.pr))")

        ws.confirmFork = { _, _ in false }
        ws.open(key)
        check("opening it asks first; no means nothing starts", ws.tabs.isEmpty, "\(ws.tabs.map(\.key))")
        var asked: RunningElsewhere?
        ws.confirmFork = { _, other in
            asked = other
            return true
        }
        ws.open(key)
        let fork = ws.currentTab
        check("yes forks it into a new session", asked?.id == id && fork.map { $0.key.agent == .claude && $0.key != key } == true,
            "\(String(describing: fork?.key))")
        if let fork {
            let wanted = "--resume\n\(id)\n--fork-session\n--session-id\n\(fork.key.id)\n"
            check("with Claude's fork flags", await wait(5) {
                (try? String(contentsOfFile: argsFile, encoding: .utf8))?.contains(wanted) == true
            }, (try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? "no file")
            ws.close(fork.key)
        }

        let left = ws.restore(SavedState(tabs: [SavedTab(agent: .claude, id: id, cwd: tmp, title: "elsewhere")]))
        check("restore leaves a session running elsewhere alone", ws.tabs.isEmpty && left.tabs.map(\.id) == [id]
            && ws.status?.contains("another app") == true, "\(String(describing: ws.status))")
    }

    /// The wheel over a terminal reaches its program without a click, also
    /// when the mouse never moved over it: here it is picked in the list
    /// from the keyboard, as with the arrow keys.
    private func wheelWithoutClick(_ tmp: String) async {
        let ws = workspace
        ws.newSession(.shell, cwd: tmp)
        guard let other = ws.currentTab else { return check("start a shell to pick first", false) }
        ws.newSession(.shell, cwd: tmp)
        guard let shell = ws.currentTab, shell !== other else { return check("start a shell to scroll in", false) }
        _ = await wait(5) { shell.terminal!.pid != nil }
        // Takes the mouse, as Claude Code does, and writes down what it gets.
        let file = tmp + "/mouse"
        shell.terminal!.run("printf '\\033[?1000h\\033[?1006h'; stty raw -echo; cat > \(shellQuote(file))")
        let view = shell.terminal!.view
        check("the program takes the mouse", await wait(5) { view.isMouseCaptured })
        pick(other.key)
        window.focusSidebar(.list)
        pick(shell.key)
        check("the list keeps the keyboard", await wait(2) { !view.isHidden && !shell.terminal!.isFocused && !other.terminal!.isFocused })
        scroll(view)
        let got = { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
        // An SGR report of button 64: the wheel turned up.
        check("the wheel reaches it without a click", await wait(3) { got().contains("\u{1B}[<64;") }, got().debugDescription)
        ws.close(shell.key)
        ws.close(other.key)
    }

    /// ⌘F: the find bar takes the keyboard, ↩ scrolls up to a match in the
    /// scrollback, clicks go to the terminal or the bar, and ⎋ closes it.
    private func find(_ tmp: String) async {
        let ws = workspace
        ws.newSession(.shell, cwd: tmp)
        guard let shell = ws.currentTab else { return check("start a shell to find in", false) }
        let t = shell.terminal!
        _ = await wait(5) { t.pid != nil }
        // A line to find, with more than a screen of lines under it.
        t.run("echo find-me; seq 300")
        check("the output scrolls", await wait(5) { (t.scrollbar?.total ?? 0) > 300 }, "\(String(describing: t.scrollbar))")
        let app = NSApp.delegate as! AppDelegate
        let findNext = NSMenuItem(title: "", action: #selector(AppDelegate.findNext(_:)), keyEquivalent: "")
        check("Find Next waits for the find bar", !app.validateMenuItem(findNext))
        app.find(nil)
        let editor = t.view.window?.firstResponder as? NSTextView
        check("⌘F shows the find bar, with the keyboard", t.isFinding && t.isFocused && editor != nil)
        check("Find Next works while it shows", app.validateMenuItem(findNext))
        editor?.insertText("find-me", replacementRange: NSRange(location: NSNotFound, length: 0))
        let atBottom = { t.scrollbar.map { $0.offset + $0.len >= $0.total } ?? true }
        editor?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check("↩ scrolls up to the match", await wait(3) { !atBottom() }, "\(String(describing: t.scrollbar))")
        // Clicks reach the terminal under the bar, and the bar's field.
        click(t.view, at: NSPoint(x: 40, y: 40))
        check("a click in the terminal takes the keyboard, and the bar stays", t.view.window?.firstResponder === t.view && t.isFinding)
        let bar = t.view.subviews.first { $0 is FindBar }
        click(t.view, at: NSPoint(x: (bar?.frame.minX ?? 0) + 40, y: bar?.frame.midY ?? 0))
        check("a click in the bar's field takes the keyboard back",
              bar.map { (t.view.window?.firstResponder as? NSView)?.isDescendant(of: $0) == true } ?? false,
              String(describing: t.view.window?.firstResponder))
        (t.view.window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check("⎋ closes it, and the terminal has the keyboard again",
              !t.isFinding && t.view.window?.firstResponder === t.view && !app.validateMenuItem(findNext))
        ws.close(shell.key)
    }

    /// The quick terminal: a shell of its own, in no tab, that slides in
    /// and away and runs on meanwhile.
    private func quickTerminal(_ tmp: String) async {
        let ws = workspace
        let quick = quick
        quick.show()
        check("quick terminal shows", quick.isShown && quick.isOnScreen)
        check("quick terminal's shell starts", await wait(10) { quick.shellPid != nil })
        guard let pid = quick.shellPid, let shell = quick.terminal else { return }
        check("it is in no tab, and scans know it", !ws.tabs.contains { $0.terminal === shell } && ws.quickShellPid() == pid)
        check("it gets the keyboard", await wait(2) { quick.isKey && shell.isFocused })
        let newClaude = NSApp.mainMenu?.items.lazy.compactMap { menu in
            menu.submenu?.items.first { $0.action == #selector(AppDelegate.newClaude(_:)) }
        }.first
        check("menu items for sessions wait", newClaude.map { !(NSApp.delegate as! AppDelegate).validateMenuItem($0) } ?? false)
        if let screen = quick.screen {
            let shown = quick.settings.shownFrame(visible: screen.visibleFrame)
            check("it slides to its place", await wait(2) { quick.frame == shown }, "\(quick.frame) not \(shown)")
        }
        let out = tmp + "/quick-pwd"
        shell.run("pwd > \(shellQuote(out))")
        check("it starts in the home folder", await wait(5) {
            (try? String(contentsOfFile: out, encoding: .utf8)) == NSHomeDirectory() + "\n"
        }, (try? String(contentsOfFile: out, encoding: .utf8)) ?? "no file")

        quick.toggle()
        check("it slides away", await wait(2) { !quick.isShown && !quick.isOnScreen })
        check("its shell runs on", kill(pid, 0) == 0)
        quick.toggle()
        check("it comes back with the same shell", await wait(2) { quick.isOnScreen } && quick.shellPid == pid)
        shell.run("exit")
        check("its shell exiting hides it", await wait(5) { quick.terminal == nil && !quick.isOnScreen })
        quick.show()
        check("the next show starts a new shell", await wait(10) { quick.shellPid.map { $0 != pid } ?? false })
        // An idle shell closes without asking.
        _ = await wait(5) { quick.terminal.map { !$0.hasForegroundJob && $0.foregroundGroup != nil } ?? false }
        quick.closeShell()
        check("closing ends it", quick.terminal == nil && !quick.isShown)

        // As with its key, from another app: it comes in front of that app
        // and takes the keyboard, and the other app gets it back after.
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return lines.append("info no Finder to come from")
        }
        NSApp.yieldActivation(to: other)
        other.activate()
        guard await wait(3, { !NSApp.isActive }) else { return lines.append("info Finder did not come to the front") }
        quick.show()
        try? await Task.sleep(for: .seconds(1))
        check("from another app, it takes the keyboard and stays", quick.isShown && quick.isKey && quick.isOnScreen,
              "shown \(quick.isShown) key \(quick.isKey) active \(NSApp.isActive)")
        check("the main window stays behind", window.window?.isKeyWindow == false)
        quick.toggle()
        check("the other app gets the keyboard back", await wait(3) {
            NSWorkspace.shared.frontmostApplication == other && !quick.isOnScreen
        }, NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
        NSApp.activate()
    }

    /// `AGENTZ_SMOKE_SNAPSHOT=<file.png>` saves how the window looks. The
    /// app draws it itself, so no screen recording permission is needed;
    /// Metal terminals come out blank.
    /// The git panel follows the shown session's repository, reads it again
    /// by itself when files change, and stages, commits, branches and
    /// stashes there.
    private func gitPanel(_ tmp: String) async {
        let ws = workspace
        let git = window.git
        let store = git.store
        let repo = tmp + "/git"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func run(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        func write(_ name: String, _ text: String) {
            FileManager.default.createFile(atPath: repo + "/" + name, contents: Data(text.utf8))
        }
        run("init", "-q", "-b", "main")
        run("config", "user.email", "t@t")
        run("config", "user.name", "t")
        run("config", "commit.gpgsign", "false")
        write("a.txt", "one\n")
        run("add", ".")
        run("commit", "-q", "-m", "first")

        let app = NSApp.delegate as! AppDelegate
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.toggleGit(_:)), keyEquivalent: "")
        window.setGitShown(false)
        ws.newSession(.shell, cwd: repo)
        guard let shell = ws.currentTab else { return check("start a shell for the git panel", false) }
        _ = await wait(5) { shell.terminal!.pid != nil }
        check("the git panel starts hidden here", !git.isShown && app.validateMenuItem(item) && item.state == .off)
        app.toggleGit(nil)
        _ = app.validateMenuItem(item)
        check("⇧⌘C shows it", window.isGitShown && git.isShown && item.state == .on)
        check("it shows the session's repository", await wait(8) {
            git.place == .repository && store.repositoryURL.map { realPath($0.path) == realPath(repo) } == true
                && store.branch == "main" && store.changes.isEmpty
        }, "\(git.place) \(String(describing: store.repositoryURL)) \(store.branch)")

        write("a.txt", "one\ntwo\n")
        write("b.txt", "new\n")
        check("changed files show without asking", await wait(6) {
            Set(store.changes.map(\.path)) == ["a.txt", "b.txt"]
        }, "\(store.changes.map(\.path))")
        snapshot("git-changes")

        // A file's button in the panel, or a double-click on it.
        if let b = store.changeEntries.first(where: { $0.change.path == "b.txt" }) {
            ws.openGit(repo, showing: b.id)
            check("a file opens its diff in the git tab", await wait(8) {
                ws.currentTab?.git.map {
                    $0.store.selectedSection == .changes && $0.store.selectedChange?.path == "b.txt" && !$0.store.diff.isEmpty
                } ?? false
            }, "\(ws.currentTab?.key.description ?? "none")")
            snapshot("git-tab-change")
            if let key = ws.currentTab?.key, key.agent == .git { ws.close(key) }
            ws.open(shell.key)
        }
        check("back on the shell, the panel shows again", await wait(3) { ws.current == shell.key && git.isShown })

        if let a = store.changes.first(where: { $0.path == "a.txt" }) { store.stage(a) }
        check("a file can be staged", await wait(5) {
            store.changes.contains { $0.path == "a.txt" && $0.isStaged && !$0.isUnstaged }
        }, "\(store.changes)")
        if let a = store.changes.first(where: { $0.path == "a.txt" }) { store.unstage(a) }
        check("and unstaged", await wait(5) {
            store.changes.contains { $0.path == "a.txt" && !$0.isStaged && $0.isUnstaged }
        }, "\(store.changes)")

        store.stageAll()
        _ = await wait(5) { store.changes.allSatisfy { $0.isStaged && !$0.isUnstaged } }
        store.commitMessage = "second"
        store.createCommit()
        check("a commit empties the changes, and shows in the history", await wait(6) {
            store.changes.isEmpty && store.commits.first?.subject == "second"
        }, "\(store.changes.count) \(store.commits.first?.subject ?? "none")")

        store.createBranch(named: "feature")
        check("a new branch is checked out", await wait(5) { store.branch == "feature" }, store.branch)

        shell.terminal!.run("cd \(shellQuote(tmp))")
        check("it follows the shell out of the repository", await wait(5) {
            git.place == .notARepo(folder: tmp) || git.place == .notARepo(folder: realPath(tmp) ?? tmp)
        }, "\(git.place)")
        app.toggleGit(nil)
        _ = app.validateMenuItem(item)
        check("⇧⌘C hides it again", !window.isGitShown && !git.isShown && item.state == .off)
        check("and it is out of sight", await wait(3) { self.window.gitPanelWidth == 0 }, "width \(window.gitPanelWidth)")
        ws.close(shell.key)
    }

    /// A git tab: GitFork's whole client for a worktree, in a pane like a
    /// terminal, one per worktree, kept across launches.
    private func gitTab(_ tmp: String) async {
        let ws = workspace
        let repo = tmp + "/tab"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"],
                     ["commit", "-q", "--allow-empty", "-m", "first"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        let root = realPath(repo) ?? repo
        let key = SessionKey(.git, root)
        ws.newSession(.shell, cwd: repo)
        guard let shell = ws.currentTab else { return check("start a shell for the git tab", false) }
        let before = ws.quitCounts()
        let app = NSApp.delegate as! AppDelegate
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.openGit(_:)), keyEquivalent: "")
        let changes = NSMenuItem(title: "", action: #selector(AppDelegate.toggleGit(_:)), keyEquivalent: "")
        window.setGitShown(true)
        check("the Changes panel shows over the shell", window.isGitShown && app.validateMenuItem(changes))
        check("Open Git works from a shell in a repository", app.validateMenuItem(item))
        app.openGit(nil)
        guard let tab = ws.tabs.first(where: { $0.key == key }), let git = tab.git else {
            return check("Open Git opens a git tab for the shell's worktree", false, "\(ws.tabs.map(\.key))")
        }
        check("Open Git opens a git tab for the shell's worktree", ws.current == key && tab.terminal == nil)
        check("the Changes panel hides over it, and can't be shown", await wait(3) {
            !self.window.isGitShown && self.window.gitPanelWidth == 0
        } && !app.validateMenuItem(changes), "width \(window.gitPanelWidth)")
        app.toggleGit(nil)
        check("not even with ⇧⌘C", !window.isGitShown)
        check("it reads the repository, and its row is named after the branch", await wait(8) {
            git.store.branch == "main" && ws.rows.contains { $0.key == key && $0.title == "main" }
        }, "\(git.store.branch) \(ws.rows.map(\.title))")
        check("its view shows, and it reads while it shows", !git.paneView.isHidden && git.paneView.window != nil)
        _ = await wait(5) { git.store.operationLabel == nil && !git.store.commits.isEmpty }
        snapshot("git-tab")
        ws.openGit(repo + "/.")
        check("one git tab per worktree", ws.tabs.filter { $0.key.agent == .git }.count == 1 && ws.current == key)
        FileManager.default.createFile(atPath: repo + "/wip.txt", contents: Data("wip\n".utf8))
        check("it sees new files", await wait(6) { !git.store.changes.isEmpty })
        git.store.stash(message: "wip")
        check("a stash takes the changes away", await wait(6) {
            git.store.changes.isEmpty && git.store.stashes.count == 1
        }, "\(git.store.changes.count) changes, \(git.store.stashes.count) stashes")
        check("quitting stops nothing in it", ws.quitCounts() == before)

        // A git tab always shows on its own: it can't be split, go into a
        // split, or get a session next to it.
        check("it can't be split, or go into a split", !ws.canSplit && !ws.canOpenInSplit(key) && !ws.canOpenInSplit(shell.key))
        ws.toggleSplit(.right)
        ws.openInSplit(shell.key, .right)
        check("so it stays on its own", ws.panes.split == nil && ws.current == key, "\(ws.panes)")
        check("it is saved with the tabs", ws.savedState().tabs.contains { $0.agent == .git && realPath($0.cwd) == root })

        // Opened from a split, it hides the split, which comes back as it
        // was, without it.
        ws.open(shell.key)
        ws.split(.right)
        let split = ws.panes
        check("the shell can be split", split.split == .right && split.keys.contains(shell.key), "\(split)")
        ws.openGit(repo)
        check("opened from a split, it shows on its own", ws.panes.split == nil && ws.current == key
            && ws.hiddenSplits.contains(split), "\(ws.panes)")
        check("and can't go into the split", !ws.canOpenInSplit(key))
        ws.open(shell.key)
        check("the split comes back without it", ws.panes.split == .right && ws.panes.keys == split.keys, "\(ws.panes)")
        // The Changes panel hid over the git tab. When it did so with an
        // animation, switching away this fast left it hidden, as if the
        // user had hidden it.
        _ = await wait(1) { false }
        check("switching away from it at once brings the Changes panel back", window.isGitShown && window.gitPanelWidth > 0,
              "width \(window.gitPanelWidth)")
        // A hidden git tab stays over the terminals, where SwiftUI took the
        // clicks even then.
        let shellView = shell.terminal!.view
        _ = await wait(3) { self.window.gitPanelWidth > 0 }
        _ = await wait(0.5) { false }
        let missed = missedClick(shellView)
        check("hidden, it takes no clicks meant for the terminals", git.paneView.isHidden && missed == nil, missed.map { "at \($0)" } ?? "")
        ws.unsplit()

        ws.close(key)
        check("closing it removes it", !ws.tabs.contains { $0.key == key } && !git.isRunning)
        check("and the Changes panel is back", await wait(3) { self.window.isGitShown && self.window.gitPanelWidth > 0 })
        // An earlier version let git tabs into splits. Such a saved split
        // comes back as its tabs on their own.
        var saved = SavedState(tabs: [
            SavedTab(agent: .git, id: nil, cwd: root, title: "main", pinned: false),
            SavedTab(agent: .shell, id: nil, cwd: root, title: Launch.shellName, pinned: false),
        ], project: ws.projectDir)
        saved.split = SavedSplit(direction: .right, panes: [0, 1], focused: 0)
        let tabsBefore = ws.tabs.map(\.key)
        _ = ws.restore(saved)
        check("a saved git tab comes back", ws.tabs.contains { $0.key == key && $0.git != nil })
        check("but not in the split it was saved in", ws.panes.split == nil
            && !ws.hiddenSplits.contains { $0.keys.contains(key) }, "\(ws.panes)")
        check("and hides the Changes panel again", ws.current != key || !window.isGitShown)
        ws.close(key)
        for r in ws.tabs where !tabsBefore.contains(r.key) {
            ws.close(r.key)
        }
        window.setGitShown(false)

        check("outside a repository there is none", !ws.openGit(tmp) && !ws.tabs.contains { $0.key == SessionKey(.git, tmp) })
        ws.close(shell.key)
    }

    private func snapshot(_ name: String? = nil) {
        guard var path = ProcessInfo.processInfo.environment["AGENTZ_SMOKE_SNAPSHOT"],
              let view = window.window?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        if let name { path = (path as NSString).deletingPathExtension + "-\(name).png" }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// What a click on the session's row does.
    private func pick(_ key: SessionKey) {
        workspace.selection = key
        workspace.select(key)
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

    /// The field of the sheet that asks where to start, once it has the
    /// keyboard.
    private func pickerField() async -> NSTextField? {
        var field: NSTextField?
        _ = await wait(3) {
            let editor = self.window.window?.attachedSheet?.firstResponder as? NSTextView
            field = editor?.delegate as? NSTextField
            return field != nil
        }
        return field
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

/// A left click at `point` in `view`, sent through the app like a real one.
@MainActor
private func click(_ view: NSView, at point: NSPoint) {
    guard let window = view.window else { return }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ) else { continue }
        NSApp.sendEvent(event)
    }
}

/// A point of `view` where a click would go to another view, if there is
/// one. Not at its edges, where the line between two panes takes clicks.
@MainActor
private func missedClick(_ view: NSView) -> NSPoint? {
    guard let content = view.window?.contentView else { return .zero }
    let b = view.bounds
    for y in [b.height * 0.25, b.midY, b.height * 0.75] {
        for x in stride(from: 6, through: b.width - 6, by: 8) {
            let p = view.convert(NSPoint(x: x, y: y), to: nil)
            let hit = content.hitTest(content.superview?.convert(p, from: nil) ?? p)
            if hit?.isDescendant(of: view) != true { return NSPoint(x: x, y: y) }
        }
    }
    return nil
}

/// One turn of the mouse wheel, up, over the middle of `view`, sent
/// through its window like a real one.
@MainActor
private func scroll(_ view: NSView) {
    guard let window = view.window,
          let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
    else { return }
    // An event made this way has no window, so its place on the screen is
    // its place in the window. The screen's y runs down from the top.
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    cg.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    guard let event = NSEvent(cgEvent: cg) else { return }
    window.sendEvent(event)
}

/// A key without modifiers, sent to `window` like a real one.
@MainActor
private func press(_ key: Key, in window: NSWindow) {
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: key.characters,
        charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
    ) else { return }
    window.sendEvent(event)
}

private enum Key {
    case `return`, escape

    var characters: String { self == .return ? "\r" : "\u{1b}" }
    var code: UInt16 { self == .return ? 36 : 53 }
}

/// The mouse moving to `point` in `view`, with no button down.
@MainActor
private func move(_ view: NSView, to point: NSPoint) {
    guard let window = view.window, let event = NSEvent.mouseEvent(
        with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0
    ) else { return }
    view.mouseMoved(with: event)
}

/// The left button going down at `point` in `view`, and not coming up.
@MainActor
private func press(_ view: NSView, at point: NSPoint) {
    guard let window = view.window, let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1
    ) else { return }
    NSApp.sendEvent(event)
}

@MainActor
private func paneContainer(in view: NSView) -> PaneContainer? {
    if let pane = view as? PaneContainer { return pane }
    return view.subviews.lazy.compactMap(paneContainer).first
}

/// A session dragged from the list, as the pane area sees it, without the
/// mouse.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingSource: Any?
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    /// `location` is in the window. A nil `source` is a drag from another app.
    init(_ key: SessionKey, at location: NSPoint, source: Any? = "agentz") {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("agentz-smoke-drag-\(getpid())"))
        draggingPasteboard.clearContents()
        draggingPasteboard.setData(Data(key.description.utf8), forType: SessionDrag.type)
        draggingLocation = location
        draggingSource = source
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions,
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

private func processName(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

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

        lines.append("info ghostty config: \(GhosttyApp.configIssue.map { "not used: \($0)" } ?? "used")")

        // `make smoke` opens this repo.
        check("worktrees of the repo are listed", await wait(10) { ws.currentWorktree != nil }, "\(ws.worktrees.count) worktrees")

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

        // A split shows two tabs. The new pane gets the focus and a shell in
        // the shown tab's folder.
        ws.newSession(.shell, cwd: tmp)
        guard let left = ws.currentTab else { return finish("no shell to split") }
        ws.split(.right)
        guard let right = ws.currentTab, right !== left else { return finish("no shell in the new pane") }
        let leftView = left.terminal.view, rightView = right.terminal.view
        check("split shows both tabs", ws.panes.keys == [left.key, right.key] && ws.panes.focused == 1)
        check("both terminals are visible", !leftView.isHidden && !rightView.isHidden)
        check("panes side by side", leftView.frame.maxX < rightView.frame.minX && leftView.frame.height == rightView.frame.height
            && abs(leftView.frame.width - rightView.frame.width) <= 1, "\(leftView.frame) \(rightView.frame)")
        check("new pane starts in the shown tab's folder", right.cwd == tmp || realPath(right.cwd) == tmp, right.cwd)

        // A click into a terminal works in its pane.
        left.terminal.focus()
        check("focus follows the terminal", ws.panes.focused == 0 && ws.selection == left.key)

        // A new session opens in the focused pane; the other keeps its tab.
        ws.newSession(.shell, cwd: tmp)
        guard let third = ws.currentTab, third !== left else { return finish("no shell for the focused pane") }
        let thirdView = third.terminal.view
        check("new session opens in the focused pane", ws.panes.keys == [third.key, right.key])
        check("the replaced tab runs on, hidden", left.isRunning && leftView.isHidden && ws.tabs.contains { $0 === left })
        check("the other pane's untouched shell stays", ws.tabs.contains { $0 === right })

        // Opening the session in the other pane moves there. Cycling skips
        // the other pane, and drops the untouched shell it leaves.
        ws.open(right.key)
        check("opening a shown session focuses its pane", ws.panes.focused == 1 && ws.panes.keys == [third.key, right.key])
        ws.cycle(1)
        check("cycling skips the other pane's session", ws.panes.keys == [third.key, left.key], "\(ws.panes.keys)")
        check("untouched split shell goes away", !ws.tabs.contains { $0 === right })

        ws.split(.down)
        check("split turns down", ws.panes.split == .down && thirdView.frame.minY > leftView.frame.maxY
            && thirdView.frame.width == leftView.frame.width, "\(thirdView.frame) \(leftView.frame)")
        // Saved with the tabs: `third` on top, `left` below and focused.
        let splitState = ws.savedState()
        let savedPanes = splitState.split?.panes.map { $0.map { splitState.tabs.indices.contains(Int($0)) } }
        check("saved state keeps the split", splitState.split?.direction == .down && splitState.split?.focused == 1
            && savedPanes == [true, true] && splitState.active == splitState.split?.panes[1],
            "\(String(describing: splitState.split)) active=\(String(describing: splitState.active))")

        // Unsplitting keeps the focused pane's tab; the other one runs on.
        ws.unsplit()
        check("unsplit keeps the focused tab", ws.panes == PaneLayout(keys: [left.key]))
        check("it fills the pane again", leftView.frame == leftView.superview?.bounds, "\(leftView.frame)")
        check("the other tab runs on, hidden", third.isRunning && thirdView.isHidden)

        // Closing a pane's tab, or exiting its shell, ends the split.
        ws.split(.right)
        guard let fourth = ws.currentTab, fourth !== left else { return finish("no shell in the second split") }
        ws.close(fourth.key)
        check("closing a pane's tab ends the split", ws.panes == PaneLayout(keys: [left.key]) && !ws.tabs.contains { $0 === fourth })
        ws.split(.down)
        guard let fifth = ws.currentTab, fifth !== left else { return finish("no shell in the third split") }
        _ = await wait(5) { fifth.terminal.pid != nil }
        fifth.terminal.run("exit")
        check("an exited shell ends the split", await wait(5) { ws.panes == PaneLayout(keys: [left.key]) }, "\(ws.panes.keys)")
        for tab in ws.tabs {
            ws.close(tab.key)
        }
        check("split tabs close", ws.tabs.isEmpty, "\(ws.tabs.count) left")

        // Restoring brings the split back, with each tab in its pane.
        _ = ws.restore(splitState)
        let restoredOK = ws.tabs.count == 2 && ws.panes.split == .down && ws.panes.focused == 1
            && splitState.split?.panes.map { $0.flatMap { i in ws.tabs.indices.contains(Int(i)) ? ws.tabs[Int(i)].key : nil } } == ws.panes.keys
        check("restore brings the split back", restoredOK, "\(ws.panes) of \(ws.tabs.map(\.key))")
        if let top = ws.panes.keys[0].flatMap({ key in ws.tabs.first { $0.key == key } }),
           let bottom = ws.panes.keys.last?.flatMap({ key in ws.tabs.first { $0.key == key } })
        {
            check("restored panes are laid out", !top.terminal.view.isHidden && !bottom.terminal.view.isHidden
                && top.terminal.view.frame.minY > bottom.terminal.view.frame.maxY,
                "\(top.terminal.view.frame) \(bottom.terminal.view.frame)")
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
        first.terminal.view.window?.makeFirstResponder(nil)
        click(first.terminal.view, at: NSPoint(x: 40, y: 40))
        check("a click reaches the only terminal", first.terminal.isFocused)
        ws.split(.right)
        guard let second = ws.currentTab, second !== first else { return finish("no second pane to click from") }
        _ = await wait(5) { first.terminal.pid != nil && second.terminal.pid != nil }
        first.terminal.run("echo one two three four five six seven eight nine ten")
        second.terminal.run("echo one two three four five six seven eight nine ten")
        _ = await wait(1) { false }
        let firstView = first.terminal.view
        click(firstView, at: NSPoint(x: 40, y: firstView.bounds.height - 10))
        _ = await wait(0.5) { false }
        check("a click focuses the other pane", ws.panes.focused == 0 && firstView.window?.firstResponder === firstView,
            "focused=\(ws.panes.focused) responder=\(String(describing: firstView.window?.firstResponder))")
        move(firstView, to: NSPoint(x: 300, y: firstView.bounds.height - 10))
        _ = await wait(0.3) { false }
        check("the click ends with the mouse up", firstView.selectionMenuPoint(at: .zero) == nil)
        move(second.terminal.view, to: NSPoint(x: 300, y: firstView.bounds.height - 10))
        _ = await wait(0.3) { false }
        check("the pane left behind has no click stuck either", second.terminal.view.selectionMenuPoint(at: .zero) == nil)
        click(second.terminal.view, at: NSPoint(x: 40, y: firstView.bounds.height - 10))
        _ = await wait(0.5) { false }
        check("a click focuses the first pane again", ws.panes.focused == 1 && firstView.window?.firstResponder === second.terminal.view)
        ws.unsplit()
        for tab in ws.tabs {
            ws.close(tab.key)
        }

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

import AgentzCore
import AppKit
import Observation

/// An agent or shell we started, keyed by the session it belongs to.
@MainActor
final class Tab {
    var key: SessionKey
    let terminal: Terminal
    var cwd: String
    let spawnedAt = Date()
    var fallbackTitle: String
    /// Started by resuming an existing transcript.
    let resumed: Bool
    /// A shell we opened by ourselves after an agent quit, and that the user
    /// has not typed into yet. It is closed when the user switches away.
    var placeholder = false
    /// For a shell: the session of the agent the user started inside it.
    var linked: SessionKey?
    /// Last scanned foreground job: process group and command name.
    var foreground: Foreground?
    let turns = TurnTracker()
    /// What `turns` said on the last tick.
    var busy = false

    init(key: SessionKey, terminal: Terminal, cwd: String, title: String, resumed: Bool) {
        self.key = key
        self.terminal = terminal
        self.cwd = cwd
        fallbackTitle = title
        self.resumed = resumed
    }

    /// True if this tab shows `key`: its own session, or the session of the
    /// agent running inside it.
    func shows(_ key: SessionKey) -> Bool {
        self.key == key || linked == key
    }

    /// A shell is named after the command it runs, e.g. `vim`.
    var title: String {
        if key.agent == .shell, let fg = foreground, terminal.foregroundGroup == fg.group {
            return fg.name
        }
        return fallbackTitle
    }

    var isRunning: Bool { terminal.isRunning }
    var isBusy: Bool { isRunning && busy }
}

/// One row in the sidebar.
struct Row: Identifiable, Equatable {
    var key: SessionKey
    var title: String
    var cwd: String
    /// `repo`, or `repo/worktree` outside the main checkout.
    var place: String
    var updated: Date
    /// What the list sorts by, newest first. For a session with a tab of
    /// ours, when the tab started: new and resumed sessions go to the top
    /// and stay there, instead of moving up each time the agent writes.
    var order: Date
    var id: SessionKey { key }
}

/// The repo the list is limited to: all its worktrees, or one folder
/// outside a repo.
struct RepoFilter: Equatable {
    let name: String
    /// The main checkout, or the folder outside a repo.
    let root: String
    /// The worktrees' folders, and their real paths.
    private(set) var dirs: [String]

    init(name: String, root: String, worktrees: [Worktree]) {
        self.name = name
        self.root = root
        let paths = worktrees.isEmpty ? [root] : worktrees.map(\.path)
        var dirs: [String] = []
        for p in paths + paths.compactMap(realPath) where !dirs.contains(p) {
            dirs.append(p)
        }
        self.dirs = dirs
    }

    func contains(_ cwd: String) -> Bool {
        dirs.contains { pathStarts(cwd, with: $0) }
    }
}

@MainActor
@Observable
final class Workspace {
    private(set) var sessions: [Session] = []
    private(set) var loaded = false
    /// The folder the user last started a session in. ⌘N and friends
    /// start there too.
    private(set) var projectDir: String
    /// The worktrees of the project's repo, main first. Empty outside a
    /// repo.
    private(set) var worktrees: [Worktree] = []
    /// Show only this repo's sessions; nil shows all repos.
    var repo: RepoFilter? { didSet { rebuildRows() } }
    /// Show only sessions with a running agent or shell.
    var hideInactive = true { didSet { rebuildRows() } }
    var filter = "" { didSet { rebuildRows() } }
    private(set) var rows: [Row] = []
    /// The row the user picked in the list.
    var selection: SessionKey?
    /// The tab shown in the pane, by its own key.
    private(set) var current: SessionKey? {
        didSet {
            if let tab = currentTab { waiting.remove(ObjectIdentifier(tab)) }
            onLayout?()
        }
    }
    /// The session of the agent running inside the shown shell.
    private(set) var currentLinked: SessionKey?
    private(set) var runningKeys: Set<SessionKey> = []
    private(set) var busyKeys: Set<SessionKey> = []
    /// Rows whose agent finished while the user was not looking, until the
    /// user looks.
    private(set) var waitingKeys: Set<SessionKey> = []
    /// macOS does not let agentz show notifications.
    var notificationsOff = false
    private(set) var runningCount = 0
    private(set) var status: String?
    private(set) var limits = Limits()
    /// Updated every few seconds, for the "5m ago" labels.
    private(set) var now = Date()

    @ObservationIgnored private(set) var tabs: [Tab] = [] {
        didSet {
            // However a tab goes away, its terminal goes with it.
            for old in oldValue where !tabs.contains(where: { $0 === old }) {
                old.terminal.close()
                waiting.remove(ObjectIdentifier(old))
            }
            onLayout?()
        }
    }
    /// Where new sessions start: the top of the project's git worktree.
    @ObservationIgnored private(set) var root: String
    @ObservationIgnored private var statusAt = Date.distantPast
    @ObservationIgnored private var nextNewId = 1
    /// Tabs whose agent wants attention.
    @ObservationIgnored private var waiting = Set<ObjectIdentifier>()
    /// `Row.place` by folder.
    @ObservationIgnored private var places: [String: String] = [:]

    /// The tabs or the shown tab changed.
    @ObservationIgnored var onLayout: (() -> Void)?
    @ObservationIgnored var onTick: (() -> Void)?
    @ObservationIgnored var focusTerminal: (() -> Void)?
    @ObservationIgnored var notify: ((_ agent: Agent, _ title: String, _ message: String?, _ key: SessionKey) -> Void)?
    /// False while the window is in the background.
    @ObservationIgnored var isWindowFocused: () -> Bool = { true }
    @ObservationIgnored var requestScan: (() -> Void)?

    init(projectDir: String) {
        let dir = URL(fileURLWithPath: projectDir).standardizedFileURL.path
        self.projectDir = dir
        root = dir
        findRoot()
    }

    var currentTab: Tab? {
        tabs.first { $0.key == current }
    }

    /// Pids of our running shells, for the process scan.
    var shellPids: [Int32] {
        tabs.filter { $0.key.agent == .shell && $0.isRunning }.compactMap(\.terminal.pid)
    }

    /// Pids of the Codex processes we started whose thread we don't know.
    var newCodexPids: [Int32] {
        tabs.filter { $0.key.agent == .codex && $0.key.id.hasPrefix("new-") && $0.isRunning }
            .compactMap(\.terminal.pid)
    }

    func setStatus(_ message: String) {
        status = message
        statusAt = Date()
    }

    /// The worktree the open folder is in.
    var currentWorktree: Worktree? {
        worktree(containing: projectDir, in: worktrees)
    }

    func openProject(_ dir: String) {
        let dir = URL(fileURLWithPath: dir).standardizedFileURL.path
        guard dir != projectDir else { return }
        projectDir = dir
        // Another worktree of the same repo keeps the list until the scan.
        if worktree(containing: dir, in: worktrees) == nil { worktrees = [] }
        root = dir
        findRoot()
        rebuildRows()
        requestScan?()
    }

    /// Asks git for the top of the worktree off the main thread. Until it
    /// answers, new sessions start in the folder itself.
    private func findRoot() {
        let dir = projectDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let root = projectRoot(dir)
            DispatchQueue.main.async {
                guard let self, self.projectDir == dir else { return }
                self.root = root
            }
        }
    }

    // MARK: - Saving and restoring

    /// Save only tabs that still have a process. The screen and shell
    /// history are transient; agents continue from their transcripts.
    func savedState() -> SavedState {
        var state = SavedState(project: projectDir)
        for r in tabs where r.isRunning {
            let linked = r.linked.flatMap { key in sessions.first { $0.key == key } }
            let session = linked ?? sessions.first { $0.key == r.key }
            let agent = linked?.agent ?? r.key.agent
            let id = session?.id ?? (r.resumed && r.key.agent != .shell ? r.key.id : nil)
            let cwd: String = if let linked {
                linked.cwd
            } else if agent == .shell {
                r.terminal.pid.flatMap(workingDirectory) ?? r.cwd
            } else {
                r.cwd
            }
            let title = session?.title ?? (agent == .shell ? Launch.shellName : r.fallbackTitle)
            if current == r.key { state.active = UInt32(state.tabs.count) }
            state.tabs.append(SavedTab(agent: agent, id: id, cwd: cwd, title: title))
        }
        return state
    }

    /// Recreates saved tabs in their original order, then shows the tab that
    /// was selected on quit. Returns tabs that could not be opened so the
    /// next launch can try them again.
    func restore(_ saved: SavedState) -> SavedState {
        var selected: SessionKey?
        var failed = SavedState(project: saved.project)
        for (i, tab) in saved.tabs.enumerated() {
            if start(tab.agent, resume: tab.id, cwd: tab.cwd, title: tab.title, focus: false) {
                if saved.active.map(Int.init) == i { selected = current }
            } else {
                if saved.active.map(Int.init) == i { failed.active = UInt32(failed.tabs.count) }
                failed.tabs.append(tab)
            }
        }
        if let selected {
            selection = selected
            current = selected
            rebuildRows()
        }
        return failed
    }

    // MARK: - Updates

    /// Runs a few times a second. Reads what every program signaled, and
    /// tells the user about agents that want attention while the user is
    /// not looking at them: the window is in the background, or another tab
    /// is shown.
    func tick() {
        var cwdChanged = false
        let focused = isWindowFocused()
        for r in tabs {
            r.terminal.poll()
        }
        for r in tabs {
            let looking = focused && current == r.key
            let update = r.turns.update(r.isRunning)
            r.busy = update.busy
            if let cwd = update.cwd, r.key.agent == .shell, cwd != r.cwd {
                r.cwd = cwd
                cwdChanged = true
            }
            guard let notice = update.notice, !looking else { continue }
            // A plain shell only counts while an agent runs inside it.
            guard let key = r.key.agent == .shell ? r.linked : r.key else { continue }
            let title = sessions.first { $0.key == key }?.title ?? r.fallbackTitle
            waiting.insert(ObjectIdentifier(r))
            notify?(key.agent, title, notice.message, key)
        }
        let titleChanged = tabs.contains { r in
            r.key.agent == .shell && r.linked == nil && rows.contains { $0.key == r.key && $0.title != r.title }
        }
        if cwdChanged || titleChanged {
            rebuildRows()
        } else {
            refreshStates()
        }
        if status != nil, Date().timeIntervalSince(statusAt) > 6 { status = nil }
        if Date().timeIntervalSince(now) >= 10 { now = Date() }
        onTick?()
    }

    /// Results of a background scan of `dir`.
    func apply(_ scan: Scan, dir: String) {
        // Nil when nothing changed since the last scan.
        if let scanned = scan.sessions { sessions = scanned }
        loaded = true
        if scan.limits != limits { limits = scan.limits }
        if dir == projectDir, scan.worktrees != worktrees {
            worktrees = scan.worktrees
            places = [:]
            // A worktree was added or removed in the filtered repo.
            if let r = repo, r.root == worktrees.first?.path {
                repo = RepoFilter(name: r.name, root: r.root, worktrees: worktrees)
            }
        }
        linkShells(scan.shells)
        bindNewCodexSessions(scan.codexThreads)
        rebuildRows()
    }

    /// Attaches each shell to the session of the agent the user started in
    /// it, so that session's row opens the shell instead of a second copy.
    private func linkShells(_ shells: [ShellProcess]) {
        for r in tabs where r.key.agent == .shell {
            let found = r.terminal.pid.flatMap { pid in shells.first { $0.pid == pid } }
            r.foreground = found?.foreground
            let linked = found?.agent
            if linked != nil {
                // The shell's row is about to be hidden behind the session's.
                if selection == r.key { selection = linked }
                r.placeholder = false
            } else if let old = r.linked, selection == old {
                selection = r.key
            }
            if r.linked != nil, linked == nil {
                // The agent exited; what it said about being busy was about
                // itself, not the shell.
                r.turns.forgetReportedBusy()
                r.busy = false
            }
            r.linked = linked
        }
    }

    /// Codex does not let us choose the id of a new session. Once the
    /// process we started has a thread open (`threads`, by pid), the tab
    /// takes that thread's id.
    private func bindNewCodexSessions(_ threads: [Int32: String]) {
        for r in tabs where r.key.agent == .codex && r.key.id.hasPrefix("new-") {
            guard let id = r.terminal.pid.flatMap({ threads[$0] }) else { continue }
            let key = SessionKey(.codex, id)
            guard !tabs.contains(where: { $0 !== r && $0.shows(key) }) else { continue }
            let old = r.key
            r.key = key
            if current == old { current = key }
            if selection == old { selection = key }
        }
    }

    func rebuildRows() {
        // Rows with a process of ours stay visible even when inactive ones
        // are hidden, so a running agent can't get lost.
        var rows: [Row] = sessions.compactMap { s in
            let key = s.key
            let tab = tabs.first { $0.shows(key) }
            guard tab != nil || !hideInactive else { return nil }
            let order = tab?.spawnedAt ?? s.updated
            return Row(key: key, title: s.title, cwd: s.cwd, place: place(s.cwd), updated: s.updated, order: order)
        }
        // Sessions we started that have no transcript yet, and shells. A
        // shell running an agent is shown as that agent's session.
        for r in tabs where !rows.contains(where: { r.shows($0.key) }) {
            rows.append(Row(key: r.key, title: r.title, cwd: r.cwd, place: place(r.cwd), updated: r.spawnedAt, order: r.spawnedAt))
        }
        if let repo {
            rows = rows.filter { repo.contains($0.cwd) }
        }
        if !filter.isEmpty {
            let q = filter.lowercased()
            rows = rows.filter {
                $0.title.lowercased().contains(q) || $0.cwd.lowercased().contains(q) || $0.key.agent.name.contains(q)
            }
        }
        rows.sort { $0.order > $1.order }
        if rows != self.rows { self.rows = rows }
        refreshStates()
    }

    private func place(_ cwd: String) -> String {
        if let p = places[cwd] { return p }
        let p = placeName(cwd)
        places[cwd] = p
        return p
    }

    /// Which rows run and work, for the list. Only assigned when it changed,
    /// so the list does not redraw on every tick.
    private func refreshStates() {
        var running = Set<SessionKey>()
        var busy = Set<SessionKey>()
        var waitingRows = Set<SessionKey>()
        for row in rows {
            guard let r = tabs.first(where: { $0.shows(row.key) && $0.isRunning }) else { continue }
            running.insert(row.key)
            if r.isBusy { busy.insert(row.key) }
            if waiting.contains(ObjectIdentifier(r)) { waitingRows.insert(row.key) }
        }
        if running != runningKeys { runningKeys = running }
        if busy != busyKeys { busyKeys = busy }
        if waitingRows != waitingKeys { waitingKeys = waitingRows }
        let count = tabs.filter(\.isRunning).count
        if count != runningCount { runningCount = count }
        let linked = currentTab?.linked
        if linked != currentLinked { currentLinked = linked }
    }

    func isCurrent(_ key: SessionKey) -> Bool {
        key == current || key == currentLinked
    }

    // MARK: - Starting and switching

    /// Shows the session. If its agent is already running we just switch to
    /// it; otherwise we resume it in a new terminal.
    func open(_ key: SessionKey) {
        if let r = tabs.first(where: { $0.shows(key) && $0.isRunning }) {
            prune(keep: key)
            current = r.key
            focusTerminal?()
            return
        }
        guard let row = rows.first(where: { $0.key == key }) else { return }
        // A Codex session that never got a transcript starts fresh.
        let resume = key.id.hasPrefix("new-") || key.agent == .shell ? nil : key.id
        startFromActiveShell(key.agent, resume: resume, cwd: row.cwd, shellCwd: false, title: row.title)
    }

    /// The list selection moved. Running sessions are shown right away;
    /// others wait for `open`, since resuming starts a process.
    func select(_ key: SessionKey?) {
        guard let key, let r = tabs.first(where: { $0.shows(key) && $0.isRunning }) else { return }
        if current != r.key {
            prune(keep: key)
            current = r.key
        }
    }

    /// Shows the next (or previous) running session in list order.
    func cycle(_ delta: Int) {
        let keys = rows.map(\.key).filter { runningKeys.contains($0) }
        guard !keys.isEmpty else { return }
        let at = keys.firstIndex { isCurrent($0) } ?? (delta > 0 ? -1 : 0)
        let key = keys[(at + delta + keys.count) % keys.count]
        selection = key
        open(key)
    }

    func newSession(_ agent: Agent) {
        startFromActiveShell(agent, resume: nil, cwd: root, shellCwd: true, title: newTitle(agent))
    }

    /// Starts a new session in `cwd`, e.g. the folder of another session.
    /// Unlike `newSession`, it never takes the place of the shown shell.
    func newSession(_ agent: Agent, cwd: String) {
        prune(keep: nil)
        start(agent, resume: nil, cwd: cwd, title: newTitle(agent))
    }

    private func newTitle(_ agent: Agent) -> String {
        agent == .shell ? Launch.shellName : "New \(agent.name) session"
    }

    /// The shell shown in the pane can be replaced only when it is at its
    /// prompt. Reads its real folder because not every shell reports it.
    private func activeIdleShell() -> (key: SessionKey, cwd: String)? {
        guard let r = currentTab, r.key.agent == .shell, r.isRunning, r.linked == nil,
              !r.terminal.hasForegroundJob
        else { return nil }
        return (r.key, r.terminal.pid.flatMap(workingDirectory) ?? r.cwd)
    }

    /// Starts an agent in place of the idle shell shown in the pane, if
    /// there is one. With `shellCwd` it starts in the shell's folder.
    private func startFromActiveShell(_ agent: Agent, resume: String?, cwd: String, shellCwd: Bool, title: String) {
        let shell = agent != .shell ? activeIdleShell() : nil
        prune(keep: shell?.key)
        // A session opened from the list keeps its own folder: Claude finds
        // its transcript by folder, and Codex would carry on in another repo.
        let cwd = shellCwd ? shell?.cwd ?? cwd : cwd
        if start(agent, resume: resume, cwd: cwd, title: title), let key = shell?.key {
            tabs.removeAll { $0.key == key }
            rebuildRows()
        }
    }

    /// Placeholder shells are kept only until the user moves on. Drops
    /// them, except the one showing `keep`.
    private func prune(keep: SessionKey?) {
        tabs.removeAll { r in !(keep.map(r.shows) ?? false) && (!r.isRunning || r.placeholder) }
    }

    /// Spawns an agent or shell. `resume` is the session id to resume, or
    /// nil for a new session. Returns false if it could not start.
    @discardableResult
    func start(_ agent: Agent, resume: String?, cwd: String, title: String, focus: Bool = true) -> Bool {
        guard isDirectory(cwd) else {
            setStatus("Folder no longer exists: \(tilde(cwd))")
            return false
        }
        let key: SessionKey
        var args: [String] = []
        switch (agent, resume) {
        case let (.claude, id?):
            key = SessionKey(.claude, id)
            args = ["--resume", id]
        case (.claude, nil):
            let id = UUID().uuidString.lowercased()
            key = SessionKey(.claude, id)
            args = ["--session-id", id]
        case let (.codex, id?):
            key = SessionKey(.codex, id)
            args = ["resume", id]
        case (.codex, nil):
            key = SessionKey(.codex, "new-\(nextNewId)")
            nextNewId += 1
        case (.shell, _):
            key = SessionKey(.shell, "shell-\(nextNewId)")
            nextNewId += 1
        }
        let launch = agent == .shell ? Launch.shell() : Launch.agent(agent, args: args, cwd: cwd)
        let terminal = Terminal(command: launch.command, cwd: cwd, env: launch.env)
        let tab = Tab(key: key, terminal: terminal, cwd: cwd, title: title, resumed: resume != nil && agent != .shell)
        terminal.onSignal = { [weak tab] signal in tab?.turns.receive(signal) }
        terminal.onExit = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.exited(tab)
        }
        tabs.append(tab)
        current = key
        selection = key
        rebuildRows()
        if focus { focusTerminal?() }
        return true
    }

    private func exited(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let key = tab.key
        let hadFocus = tab.terminal.isFocused
        if key.agent != .shell, Date().timeIntervalSince(tab.spawnedAt) < 3 {
            setStatus("\(key.agent.name) quit right after starting. Is it installed and in your login shell's PATH?")
        }
        if current != key {
            tabs.remove(at: i)
        } else if key.agent == .shell {
            // Like closing a terminal tab.
            tabs.remove(at: i)
            current = nil
        } else {
            // The shown agent quit. A fresh shell takes its place, in the
            // same folder, so the user can start `claude` or `codex` by hand.
            tabs.remove(at: i)
            current = nil
            if start(.shell, resume: nil, cwd: tab.cwd, title: Launch.shellName, focus: hadFocus) {
                tabs.last?.placeholder = true
            }
        }
        rebuildRows()
    }

    /// Stops the session's agent or shell and closes its tab, then shows the
    /// next running one.
    func close(_ key: SessionKey) {
        guard let i = tabs.firstIndex(where: { $0.shows(key) }) else { return }
        let wasShown = current == tabs[i].key
        // Dropping the terminal frees Ghostty's surface, which hangs up on
        // the program.
        tabs.remove(at: i)
        rebuildRows()
        if wasShown {
            let next = rows.lazy.compactMap { row in
                self.tabs.first { $0.shows(row.key) && $0.isRunning }.map { (row: row.key, tab: $0.key) }
            }.first
            current = next?.tab
            selection = next?.row
            if next != nil { focusTerminal?() }
        }
    }

    /// The user typed into a terminal: a new turn starts, and a placeholder
    /// shell becomes a real one.
    func userTyped(in view: NSView) {
        guard let r = tabs.first(where: { $0.terminal.view === view }) else { return }
        r.turns.userInput()
        r.placeholder = false
        waiting.remove(ObjectIdentifier(r))
    }

    /// What quitting would stop. Agents started by hand in a shell count as
    /// agents; a shell counts only while it runs a command.
    func quitCounts() -> (working: Int, idle: Int, commands: Int) {
        var working = 0, idle = 0, commands = 0
        for r in tabs where r.isRunning && !r.placeholder {
            if r.key.agent != .shell || r.linked != nil {
                if r.isBusy { working += 1 } else { idle += 1 }
            } else if r.terminal.hasForegroundJob {
                commands += 1
            }
        }
        return (working, idle, commands)
    }
}

/// Scans transcripts, processes and rate limits every few seconds, off the
/// main thread.
@MainActor
final class Scanner {
    private let queue = DispatchQueue(label: "agentz.scan", qos: .utility)
    private let scanner = SessionScanner()
    private weak var workspace: Workspace?
    private var scanning = false
    private var again = false

    init(_ workspace: Workspace) {
        self.workspace = workspace
        workspace.requestScan = { [weak self] in self?.scan() }
    }

    func scan() {
        guard let workspace else { return }
        if scanning {
            again = true
            return
        }
        scanning = true
        let dir = workspace.projectDir
        let pids = workspace.shellPids
        let codexPids = workspace.newCodexPids
        let scanner = self.scanner
        queue.async {
            let scan = scanner.scan(dir, pids, codexPids)
            DispatchQueue.main.async {
                self.scanning = false
                self.workspace?.apply(scan, dir: dir)
                if self.again {
                    self.again = false
                    self.scan()
                }
            }
        }
    }

    func start() {
        scan()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }
}

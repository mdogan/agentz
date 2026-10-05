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
    /// Can't be closed, stays when its program ends, and comes back on
    /// every launch.
    var pinned = false

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
    /// Pinned rows come first.
    var pinned = false
    /// Has a tab of ours: a running agent or shell, or one that just
    /// ended. Active rows come before the rest, whatever their time.
    var active = false
    var id: SessionKey { key }

    /// The list's groups, in order: pinned, active, the rest.
    var group: Int { pinned ? 0 : active ? 1 : 2 }
}

/// Which sessions the list shows, by when they were last used. Sessions
/// with a running agent or shell show in all of them.
enum SessionRange: CaseIterable {
    case active, today, week, month, all

    var title: String {
        switch self {
        case .active: "Only Active Sessions"
        case .today: "Today's Sessions"
        case .week: "Last 7 Days' Sessions"
        case .month: "Last 30 Days' Sessions"
        case .all: "All Sessions"
        }
    }

    func includes(_ updated: Date, now: Date) -> Bool {
        switch self {
        case .active: false
        case .today: updated >= Calendar.current.startOfDay(for: now)
        case .week: updated >= now.addingTimeInterval(-7 * 86400)
        case .month: updated >= now.addingTimeInterval(-30 * 86400)
        case .all: true
        }
    }
}

/// What the pane area shows: one tab, or two after a split.
struct PaneLayout: Equatable {
    /// The tab in each pane, by its own key, left or top first. Nil for a
    /// pane with no terminal.
    var keys: [SessionKey?] = [nil]
    /// Nil with one pane.
    var split: SplitDirection?
    /// The pane the user works in: the list picks what it shows, and new
    /// and resumed sessions open there.
    var focused = 0

    var current: SessionKey? {
        get { keys[focused] }
        set { keys[focused] = newValue }
    }

    /// The tab in the pane the user does not work in.
    var other: SessionKey? {
        split == nil ? nil : keys[1 - focused]
    }
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
    /// At start, today's sessions.
    var range = SessionRange.today { didSet { rebuildRows() } }
    var filter = "" { didSet { rebuildRows() } }
    private(set) var rows: [Row] = []
    /// The row the user picked in the list.
    var selection: SessionKey?
    /// The tabs on screen.
    private(set) var panes = PaneLayout() {
        didSet {
            for r in tabs where panes.keys.contains(r.key) {
                waiting.remove(ObjectIdentifier(r))
            }
            onLayout?()
        }
    }
    /// The tab shown in the focused pane, by its own key.
    private(set) var current: SessionKey? {
        get { panes.current }
        set { panes.current = newValue }
    }
    /// The session of the agent running inside the shown shell.
    private(set) var currentLinked: SessionKey?
    /// The same for the shell in the other pane.
    private(set) var otherLinked: SessionKey?
    private(set) var runningKeys: Set<SessionKey> = []
    private(set) var busyKeys: Set<SessionKey> = []
    /// Rows whose agent finished while the user was not looking, until the
    /// user looks.
    private(set) var waitingKeys: Set<SessionKey> = []
    /// Rows whose agent quit while the user was not looking.
    private(set) var quitKeys: Set<SessionKey> = []
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
                quit.remove(ObjectIdentifier(old))
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
    /// Tabs whose agent quit while the user was not looking. They stay,
    /// without a process, until the user resumes or closes the session.
    @ObservationIgnored private var quit = Set<ObjectIdentifier>()
    /// `Row.place` by folder.
    @ObservationIgnored private var places: [String: String] = [:]

    /// The tabs or the shown tab changed.
    @ObservationIgnored var onLayout: (() -> Void)?
    @ObservationIgnored var onTick: (() -> Void)?
    @ObservationIgnored var focusTerminal: (() -> Void)?
    /// Shows a notification: `heading`, then the session's `title` and
    /// `message`. Clicking it opens `key`.
    @ObservationIgnored var notify: ((_ heading: String, _ title: String, _ message: String?, _ key: SessionKey) -> Void)?
    /// False while the window is in the background.
    @ObservationIgnored var isWindowFocused: () -> Bool = { true }
    @ObservationIgnored var requestScan: (() -> Void)?
    /// The pinned tabs changed, and should be kept for the next launch.
    @ObservationIgnored var savePins: (([SavedTab]) -> Void)?
    /// What `savePins` got last.
    @ObservationIgnored private var savedPins: [SavedTab]?

    init(projectDir: String) {
        let dir = URL(fileURLWithPath: projectDir).standardizedFileURL.path
        self.projectDir = dir
        root = dir
        findRoot()
    }

    var currentTab: Tab? {
        tabs.first { $0.key == current }
    }

    /// The tab in the pane the user does not work in, while split.
    var otherTab: Tab? {
        tabs.first { $0.key == panes.other }
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

    /// Save only tabs that still have a process, and pinned ones, and the
    /// split. The screen and shell history are transient; agents continue
    /// from their transcripts.
    func savedState() -> SavedState {
        var state = SavedState(project: projectDir)
        var index: [SessionKey: UInt32] = [:]
        for r in tabs where r.isRunning || r.pinned {
            index[r.key] = UInt32(state.tabs.count)
            state.tabs.append(saved(r))
        }
        state.active = current.flatMap { index[$0] }
        if let split = panes.split {
            state.split = SavedSplit(
                direction: split,
                panes: panes.keys.map { $0.flatMap { index[$0] } },
                focused: UInt32(panes.focused)
            )
        }
        return state
    }

    private func saved(_ r: Tab) -> SavedTab {
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
        return SavedTab(agent: agent, id: id, cwd: cwd, title: title, pinned: r.pinned)
    }

    /// Hands the pinned tabs to `savePins` when they changed: pinned,
    /// unpinned, or their session or folder moved on.
    private func keepPins() {
        guard let savePins else { return }
        let pins = tabs.filter(\.pinned).map(saved)
        guard pins != savedPins else { return }
        savedPins = pins
        savePins(pins)
    }

    /// Recreates saved tabs in their original order, then shows the tab that
    /// was selected on quit, or the split. Returns tabs that could not be
    /// opened so the next launch can try them again.
    func restore(_ saved: SavedState) -> SavedState {
        // The new tabs' keys, by their index in `saved.tabs`.
        var started: [Int: SessionKey] = [:]
        var failed = SavedState(project: saved.project)
        for (i, tab) in saved.tabs.enumerated() {
            if start(tab.agent, resume: tab.id, cwd: tab.cwd, title: tab.title, focus: false) {
                tabs.last?.pinned = tab.pinned
                started[i] = current
            } else {
                if saved.active.map(Int.init) == i { failed.active = UInt32(failed.tabs.count) }
                failed.tabs.append(tab)
            }
        }
        let layout = saved.split.flatMap { split -> PaneLayout? in
            let keys = split.panes.map { $0.flatMap { started[Int($0)] } }
            // Not if both its tabs are gone.
            guard keys.count == 2, split.focused < 2, keys.contains(where: { $0 != nil }) else { return nil }
            return PaneLayout(keys: keys, split: split.direction, focused: Int(split.focused))
        }
        if let layout {
            panes = layout
            // Nil leaves an empty focused pane as it is.
            selection = current
        } else if let selected = saved.active.flatMap({ started[Int($0)] }) {
            selection = selected
            current = selected
        }
        rebuildRows()
        keepPins()
        return failed
    }

    // MARK: - Updates

    /// Runs a few times a second. Reads what every program signaled, and
    /// tells the user about agents that want attention while the user is
    /// not looking at them: the window is in the background, or the agent
    /// is in no pane.
    func tick() {
        var cwdChanged = false
        let focused = isWindowFocused()
        for r in tabs {
            r.terminal.poll()
        }
        for r in tabs {
            let looking = focused && panes.keys.contains(r.key)
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
            notify?("\(key.agent.displayName) is waiting", title, notice.message, key)
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
        keepPins()
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
            if let pane = panes.keys.firstIndex(of: old) { panes.keys[pane] = key }
            if selection == old { selection = key }
        }
    }

    func rebuildRows() {
        // Rows with a process of ours stay visible whatever the range, so a
        // running agent can't get lost.
        let now = Date()
        var rows: [Row] = sessions.compactMap { s in
            let key = s.key
            let tab = tabs.first { $0.shows(key) }
            guard tab != nil || range.includes(s.updated, now: now) else { return nil }
            let order = tab?.spawnedAt ?? s.updated
            return Row(key: key, title: s.title, cwd: s.cwd, place: place(s.cwd), updated: s.updated, order: order, pinned: tab?.pinned ?? false, active: tab != nil)
        }
        // Sessions we started that have no transcript yet, and shells. A
        // shell running an agent is shown as that agent's session.
        for r in tabs where !rows.contains(where: { r.shows($0.key) }) {
            rows.append(Row(key: r.key, title: r.title, cwd: r.cwd, place: place(r.cwd), updated: r.spawnedAt, order: r.spawnedAt, pinned: r.pinned, active: true))
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
        rows.sort { $0.group != $1.group ? $0.group < $1.group : $0.order > $1.order }
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
        var quitRows = Set<SessionKey>()
        for row in rows {
            guard let r = tabs.first(where: { $0.shows(row.key) && $0.isRunning }) else {
                if tabs.contains(where: { $0.shows(row.key) && quit.contains(ObjectIdentifier($0)) }) {
                    quitRows.insert(row.key)
                }
                continue
            }
            running.insert(row.key)
            if r.isBusy { busy.insert(row.key) }
            if waiting.contains(ObjectIdentifier(r)) { waitingRows.insert(row.key) }
        }
        if running != runningKeys { runningKeys = running }
        if busy != busyKeys { busyKeys = busy }
        if waitingRows != waitingKeys { waitingKeys = waitingRows }
        if quitRows != quitKeys { quitKeys = quitRows }
        let count = tabs.filter(\.isRunning).count
        if count != runningCount { runningCount = count }
        let linked = currentTab?.linked
        if linked != currentLinked { currentLinked = linked }
        let other = otherTab?.linked
        if other != otherLinked { otherLinked = other }
    }

    func isCurrent(_ key: SessionKey) -> Bool {
        key == current || key == currentLinked
    }

    /// True if the session shows in the pane the user does not work in.
    func isInOtherPane(_ key: SessionKey) -> Bool {
        guard let other = panes.other else { return false }
        return key == other || key == otherLinked
    }

    // MARK: - Starting and switching

    /// Shows the session. If its agent is already running we just switch to
    /// it; otherwise we resume it in a new terminal.
    func open(_ key: SessionKey) {
        if let r = tabs.first(where: { $0.shows(key) && $0.isRunning }) {
            show(r, for: key)
            focusTerminal?()
            return
        }
        // From a notification, the session may not be listed any more.
        guard let (cwd, title) = rows.first(where: { $0.key == key }).map({ ($0.cwd, $0.title) })
            ?? sessions.first(where: { $0.key == key }).map({ ($0.cwd, $0.title) })
        else { return }
        // The tab of an agent that quit makes way for the resumed one, and
        // hands it its pin.
        let ended = tabs.filter { $0.shows(key) && !$0.isRunning }
        tabs.removeAll { $0.shows(key) && !$0.isRunning }
        // A Codex session that never got a transcript starts fresh.
        let resume = key.id.hasPrefix("new-") || key.agent == .shell ? nil : key.id
        let started = startFromActiveShell(key.agent, resume: resume, cwd: cwd, shellCwd: false, title: title)
        guard ended.contains(where: \.pinned) else { return }
        if started {
            currentTab?.pinned = true
            rebuildRows()
            keepPins()
        } else {
            // Its folder is gone. Keep the pin until the user unpins it.
            tabs.append(contentsOf: ended.filter(\.pinned))
        }
    }

    func isPinned(_ key: SessionKey) -> Bool {
        tabs.contains { $0.shows(key) && $0.pinned }
    }

    /// Pins or unpins the session's tab. Sessions without a tab can't be
    /// pinned.
    func setPinned(_ key: SessionKey, _ pinned: Bool) {
        guard let r = tabs.first(where: { $0.shows(key) }), r.pinned != pinned else { return }
        r.pinned = pinned
        r.placeholder = false
        if !pinned, !r.isRunning, !quit.contains(ObjectIdentifier(r)), !panes.keys.contains(r.key) {
            // An ended tab was only kept for its pin.
            tabs.removeAll { $0 === r }
        }
        rebuildRows()
        keepPins()
    }

    /// The list selection moved. Running sessions are shown right away;
    /// others wait for `open`, since resuming starts a process. Until then
    /// the pane offers to resume them.
    func select(_ key: SessionKey?) {
        guard let key else { return }
        guard let r = tabs.first(where: { $0.shows(key) && $0.isRunning }) else {
            current = nil
            return
        }
        show(r, for: key)
    }

    /// Shows the running tab `r`, for the session `key`, in the focused
    /// pane. One already in a pane stays there, and its pane gets the focus.
    private func show(_ r: Tab, for key: SessionKey) {
        if let pane = panes.keys.firstIndex(of: r.key) {
            panes.focused = pane
        } else {
            prune(keep: key)
            current = r.key
        }
    }

    /// Shows the next (or previous) running session in list order. The
    /// session in the other pane stays there and is skipped.
    func cycle(_ delta: Int) {
        let keys = rows.map(\.key).filter { runningKeys.contains($0) && !isInOtherPane($0) }
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
    /// prompt and not pinned. Reads its real folder because not every shell
    /// reports it.
    private func activeIdleShell() -> (key: SessionKey, cwd: String)? {
        guard let r = currentTab, r.key.agent == .shell, r.isRunning, r.linked == nil, !r.pinned,
              !r.terminal.hasForegroundJob
        else { return nil }
        return (r.key, r.terminal.pid.flatMap(workingDirectory) ?? r.cwd)
    }

    /// Starts an agent in place of the idle shell shown in the pane, if
    /// there is one. With `shellCwd` it starts in the shell's folder.
    /// Returns false if it could not start.
    @discardableResult
    private func startFromActiveShell(_ agent: Agent, resume: String?, cwd: String, shellCwd: Bool, title: String) -> Bool {
        let shell = agent != .shell ? activeIdleShell() : nil
        prune(keep: shell?.key)
        // A session opened from the list keeps its own folder: Claude finds
        // its transcript by folder, and Codex would carry on in another repo.
        let cwd = shellCwd ? shell?.cwd ?? cwd : cwd
        guard start(agent, resume: resume, cwd: cwd, title: title) else { return false }
        if let key = shell?.key {
            tabs.removeAll { $0.key == key }
            rebuildRows()
        }
        return true
    }

    /// Placeholder shells are kept only until the user moves on. Drops
    /// them and ended tabs, except the one showing `keep`, the one in the
    /// other pane, pinned ones, and agents that quit while the user was
    /// away.
    private func prune(keep: SessionKey?) {
        let other = panes.other
        tabs.removeAll { r in
            r.key != other && !(keep.map(r.shows) ?? false) && !r.pinned && !quit.contains(ObjectIdentifier(r))
                && (!r.isRunning || r.placeholder)
        }
    }

    // MARK: - Splitting

    /// Splits the pane area in two. The new pane gets the focus and a new
    /// shell in the folder of the shown tab; ⌘N there starts an agent in its
    /// place. Already split, it turns the split to `direction`.
    func split(_ direction: SplitDirection) {
        guard panes.split == nil else {
            panes.split = direction
            return
        }
        let cwd = currentTab.map { r in
            r.key.agent == .shell ? r.terminal.pid.flatMap(workingDirectory) ?? r.cwd : r.cwd
        } ?? root
        panes = PaneLayout(keys: [current, nil], split: direction, focused: 1)
        // Like the shell that replaces an agent that quit, it goes away if
        // the user moves on without typing into it.
        if start(.shell, resume: nil, cwd: cwd, title: Launch.shellName) {
            tabs.last?.placeholder = true
        }
    }

    /// What ⌘D and ⇧⌘D do: splits the pane that way, turns the split, or
    /// unsplits it if it is split that way already.
    func toggleSplit(_ direction: SplitDirection) {
        if panes.split == direction {
            unsplit()
        } else {
            split(direction)
        }
    }

    /// False for the session shown in the only pane: it can't be split off
    /// from itself.
    func canOpenInSplit(_ key: SessionKey) -> Bool {
        panes.split != nil || !isCurrent(key)
    }

    /// Shows the session in a pane of a split `direction`, the right or
    /// bottom one unless `pane` is 0, and works there. A running session
    /// moves there; others are resumed there. If it is in the other pane
    /// already, the two trade places.
    func openInSplit(_ key: SessionKey, _ direction: SplitDirection, pane: Int = 1) {
        guard canOpenInSplit(key), pane == 0 || pane == 1 else { return }
        let running = tabs.first { $0.shows(key) && $0.isRunning }
        if panes.split == nil {
            var keys = [current, current]
            keys[pane] = nil
            panes = PaneLayout(keys: keys, split: direction, focused: pane)
            open(key)
            // It could not be resumed, e.g. its folder is gone.
            guard current != nil else {
                panes = PaneLayout(keys: [panes.keys[1 - pane]])
                return
            }
        } else if let r = running, panes.keys[1 - pane] == r.key {
            panes = PaneLayout(keys: panes.keys.reversed(), split: direction, focused: pane)
            open(key)
        } else {
            panes.split = direction
            panes.focused = pane
            open(key)
        }
        if currentTab?.shows(key) == true { selection = key }
    }

    /// Back to one pane, with the focused pane's tab, or the other one's if
    /// the focused pane is empty. The tab that goes off screen keeps
    /// running, in the list.
    func unsplit() {
        guard panes.split != nil else { return }
        let hadFocus = [currentTab, otherTab].contains { $0?.terminal.isFocused == true }
        dropPane(current == nil ? panes.focused : 1 - panes.focused)
        prune(keep: current)
        if hadFocus { focusTerminal?() }
    }

    /// Ends the split without pane `i`. The other pane fills the space and
    /// gets the focus.
    private func dropPane(_ i: Int) {
        let moved = panes.focused == i
        panes = PaneLayout(keys: [panes.keys[1 - i]])
        if moved, let r = currentTab { selection = r.linked ?? r.key }
    }

    /// Makes pane `i` the one the user works in, and moves the keyboard to
    /// its terminal, or to the list if it has none.
    func focusPane(_ i: Int) {
        guard panes.split != nil, panes.keys.indices.contains(i) else { return }
        if panes.focused != i {
            panes.focused = i
            if let r = currentTab { selection = r.linked ?? r.key }
        }
        focusTerminal?()
    }

    func focusOtherPane() {
        focusPane(1 - panes.focused)
    }

    /// The user clicked into the terminal of a tab: its pane becomes the
    /// one the user works in, and the list selects its session.
    private func terminalFocused(_ tab: Tab) {
        guard let pane = panes.keys.firstIndex(of: tab.key), pane != panes.focused else { return }
        panes.focused = pane
        selection = tab.linked ?? tab.key
    }

    /// Spawns an agent or shell, in the focused pane unless `pane` says
    /// another. `resume` is the session id to resume, or nil for a new
    /// session. Returns false if it could not start.
    @discardableResult
    func start(_ agent: Agent, resume: String?, cwd: String, title: String, focus: Bool = true, pane: Int? = nil) -> Bool {
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
        if agent == .shell {
            terminal.onCommandFinished = { [weak self, weak tab] exitCode, seconds in
                guard let self, let tab else { return }
                self.commandFinished(tab, exitCode: exitCode, seconds: seconds)
            }
        }
        terminal.onFocus = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.terminalFocused(tab)
        }
        // The pane first, so the terminal starts at the pane's size.
        let pane = pane ?? panes.focused
        panes.keys[pane] = key
        tabs.append(tab)
        if pane == panes.focused { selection = key }
        rebuildRows()
        if focus { focusTerminal?() }
        return true
    }

    private func exited(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let key = tab.key
        let pane = panes.keys.firstIndex(of: key)
        let hadFocus = tab.terminal.isFocused
        let early = Date().timeIntervalSince(tab.spawnedAt) < 3
        if key.agent != .shell, early {
            setStatus("\(key.agent.name) quit right after starting. Is it installed and in your login shell's PATH?")
        }
        // An agent only quits when told to, in its own tab. Quitting while
        // nobody looks means it crashed or something killed it.
        let unexpected = key.agent != .shell && !early && !(isWindowFocused() && pane != nil)
        if unexpected {
            let title = sessions.first { $0.key == key }?.title ?? tab.fallbackTitle
            notify?("\(key.agent.displayName) quit", title, "It quit while you were away. Open the session to resume it.", key)
        }
        if tab.pinned {
            // A pinned tab stays, without a process, until the user opens
            // it again. The pane offers to resume it.
            if unexpected { quit.insert(ObjectIdentifier(tab)) }
            if let pane { panes.keys[pane] = nil }
        } else if let pane {
            tabs.remove(at: i)
            if key.agent == .shell {
                // Like closing a terminal tab, or a split.
                if panes.split != nil {
                    dropPane(pane)
                    if hadFocus { focusTerminal?() }
                } else {
                    panes.keys[pane] = nil
                }
            } else {
                // The shown agent quit. A fresh shell takes its place, in
                // the same pane and folder, so the user can start `claude`
                // or `codex` by hand.
                panes.keys[pane] = nil
                if start(.shell, resume: nil, cwd: tab.cwd, title: Launch.shellName, focus: hadFocus, pane: pane) {
                    tabs.last?.placeholder = true
                }
            }
        } else if unexpected {
            quit.insert(ObjectIdentifier(tab))
        } else {
            tabs.remove(at: i)
        }
        rebuildRows()
    }

    /// A command the user ran in a shell ended. Tells the user as the
    /// Ghostty config's `notify-on-command-finish` settings say.
    private func commandFinished(_ tab: Tab, exitCode: Int?, seconds: TimeInterval) {
        let settings = GhosttyApp.commandFinish
        let looking = isWindowFocused() && panes.keys.contains(tab.key)
        guard settings.applies(seconds: seconds, looking: looking), settings.bell || settings.notify else { return }
        if !looking {
            waiting.insert(ObjectIdentifier(tab))
            refreshStates()
        }
        // Ghostty's bell bounces the Dock icon; it does nothing while the
        // app is in front.
        if settings.bell { NSApp.requestUserAttention(.informationalRequest) }
        guard settings.notify else { return }
        // The scan saw the command if it ran for a few seconds.
        let command = tab.foreground?.name
        let failed = exitCode.map { $0 != 0 } ?? false
        let heading = "\(command ?? "Command") \(failed ? "failed" : "finished")"
        var message = "Took \(elapsed(seconds))"
        if failed, let exitCode { message = "Exit code \(exitCode) after \(elapsed(seconds))" }
        notify?(heading, tilde(tab.cwd), message, tab.linked ?? tab.key)
    }

    /// Stops the session's agent or shell and closes its tab, then shows the
    /// next running one. In a split, the other pane takes the space instead.
    /// Pinned tabs have to be unpinned first.
    func close(_ key: SessionKey) {
        guard let i = tabs.firstIndex(where: { $0.shows(key) }), !tabs[i].pinned else { return }
        let pane = panes.keys.firstIndex(of: tabs[i].key)
        let wasShown = pane == panes.focused
        // Dropping the terminal frees Ghostty's surface, which hangs up on
        // the program.
        tabs.remove(at: i)
        if let pane, panes.split != nil {
            dropPane(pane)
            rebuildRows()
            if wasShown { focusTerminal?() }
            return
        }
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

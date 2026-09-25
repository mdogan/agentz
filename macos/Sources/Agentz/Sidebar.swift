import AgentzCore
import AppKit
import SwiftUI

/// Where a menu command wants the keyboard focus in the sidebar.
@MainActor
@Observable
final class SidebarFocus {
    enum Target { case list, filter }
    private(set) var target: Target?
    private(set) var serial = 0

    func request(_ target: Target) {
        self.target = target
        serial += 1
    }
}

/// What the sidebar asks the app to do.
struct SidebarActions {
    var close: (SessionKey) -> Void
    /// Starts a session in `dir`. `repo` is the recent folder it was picked
    /// from, which goes to the top of the recent folders.
    var start: (_ agent: Agent, _ dir: String, _ repo: String) -> Void
    /// Asks for a folder to start the agent in.
    var chooseFolder: (Agent) -> String?
    var recentFolders: () -> [String]
    var clearRecentFolders: () -> Void
    var notificationSettings: () -> Void
}

struct SidebarView: View {
    @Bindable var workspace: Workspace
    let look: Look
    let focus: SidebarFocus
    let actions: SidebarActions
    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool
    @State private var hovered: SessionKey?
    @State private var newWorktree: WorktreeRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .foregroundStyle(look.text)
        .background(look.sidebar.ignoresSafeArea())
        .tint(look.accent)
        .onChange(of: focus.serial) {
            switch focus.target {
            case .list: listFocused = true
            case .filter: filterFocused = true
            case nil: break
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach([Agent.claude, .codex, .shell], id: \.self) { agent in
                        PopUpButton(look: look, help: "New \(agent.displayName) session. Pick a folder, or a worktree of a repo.", menu: { startMenu(agent) }) {
                            Text(agent.icon)
                                .foregroundStyle(look.color(for: agent))
                            Text(agent.displayName)
                                .lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                }
                // The buttons' hover padding, so the icon lines up with the
                // filter below.
                .padding(.leading, -5)
                Spacer(minLength: 0)
                PopUpButton(look: look, help: filterHelp, chevron: false, menu: filterMenu) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(workspace.repo == nil ? look.text : look.accent)
                }
                .padding(.trailing, -5)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(look.secondary)
                TextField("Filter", text: $workspace.filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onSubmit { listFocused = true }
                    .onExitCommand {
                        workspace.filter = ""
                        listFocused = true
                    }
                if !workspace.filter.isEmpty {
                    Button { workspace.filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(look.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(look.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                Text("\(workspace.rows.count) sessions")
                if let repo = workspace.repo {
                    Text("in \(repo.name)").foregroundStyle(look.accent)
                }
                Text("·")
                Text("\(workspace.runningCount) running")
                if !workspace.busyKeys.isEmpty {
                    Text("·")
                    Text("\(workspace.busyKeys.count) working").foregroundStyle(look.yellow)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(look.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .sheet(item: $newWorktree) { request in
            NewWorktreeView(
                worktrees: request.repo.worktrees,
                current: worktree(containing: workspace.projectDir, in: request.repo.worktrees),
                created: { made in
                    actions.start(request.agent, made.path, request.repo.dir)
                    workspace.requestScan?()
                    if let problem = made.warnings.first {
                        let more = made.warnings.count > 1 ? " (and \(made.warnings.count - 1) more)" : ""
                        workspace.setStatus("Created \(tilde(made.path)). \(problem)\(more)")
                    } else {
                        workspace.setStatus("Created worktree \(tilde(made.path))")
                    }
                },
                switchTo: { wt in actions.start(request.agent, wt.path, request.repo.dir) }
            )
        }
    }

    /// Where to start a new session: a recent folder, or in a git repo one
    /// of its worktrees.
    private func startMenu(_ agent: Agent) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let repos = recentRepos(actions.recentFolders())
        if !repos.isEmpty {
            menu.addItem(.sectionHeader(title: "Start \(agent.displayName) In"))
            for repo in repos {
                let item = MenuAction(repo.name, detail: repo.parent) { actions.start(agent, repo.dir, repo.dir) }
                item.toolTip = tilde(repo.dir)
                if !repo.worktrees.isEmpty {
                    item.submenu = worktreeMenu(agent, repo)
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(MenuAction("Open Folder…") {
            if let dir = actions.chooseFolder(agent) { actions.start(agent, dir, dir) }
        })
        if !repos.isEmpty {
            menu.addItem(MenuAction("Clear Recent Folders", actions.clearRecentFolders))
        }
        return menu
    }

    private func worktreeMenu(_ agent: Agent, _ repo: RecentRepo) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Worktrees"))
        for wt in repo.worktrees where !wt.bare {
            var detail = wt.missing ? "folder is gone" : tilde(wt.path)
            if wt.locked { detail += " · locked" }
            let item = MenuAction(wt.label, detail: detail) { actions.start(agent, wt.path, repo.dir) }
            item.isEnabled = !wt.missing
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction("New Worktree…") { newWorktree = WorktreeRequest(agent: agent, repo: repo) })
        return menu
    }

    private var filterHelp: String {
        let repo = workspace.repo.map { "Sessions in \($0.name) · \(tilde($0.root))" } ?? "Sessions from all repos"
        return "\(repo)\nWhich sessions to show"
    }

    private func filterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Repos"))
        let all = MenuAction("All Repos") { workspace.repo = nil }
        all.state = workspace.repo == nil ? .on : .off
        menu.addItem(all)
        var repos = recentRepos(actions.recentFolders())
        // Keep a filtered repo that fell off the recent folders.
        if let current = workspace.repo, !repos.contains(where: { $0.root == current.root }) {
            repos.append(RecentRepo(dir: current.root, worktrees: listWorktrees(current.root)))
        }
        for repo in repos {
            let item = MenuAction(repo.name, detail: repo.parent) { workspace.repo = repo.filter }
            item.state = workspace.repo?.root == repo.root ? .on : .off
            item.toolTip = tilde(repo.root)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let inactive = MenuAction("Inactive Sessions") { workspace.hideInactive.toggle() }
        inactive.state = workspace.hideInactive ? .off : .on
        inactive.keyEquivalent = "I"
        menu.addItem(inactive)
        return menu
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.rows) { row in
                        let running = workspace.runningKeys.contains(row.key)
                        RowView(
                            row: row,
                            look: look,
                            selected: workspace.selection == row.key,
                            listFocused: listFocused,
                            isCurrent: workspace.isCurrent(row.key),
                            running: running,
                            busy: workspace.busyKeys.contains(row.key),
                            waiting: workspace.waitingKeys.contains(row.key),
                            hovered: hovered == row.key,
                            now: workspace.now
                        )
                        .id(row.key)
                        .onTapGesture(count: 2) { workspace.open(row.key) }
                        .simultaneousGesture(TapGesture().onEnded {
                            workspace.selection = row.key
                            listFocused = true
                        })
                        .contextMenu { rowMenu(row.key) }
                        // After the row's gestures, so a click on it does
                        // not also select the row.
                        .overlay(alignment: .trailing) {
                            if hovered == row.key {
                                RowButtons(
                                    look: look,
                                    closable: running,
                                    start: { agent in workspace.newSession(agent, cwd: row.cwd) },
                                    close: { actions.close(row.key) }
                                )
                                .padding(.trailing, 4)
                            }
                        }
                        // Around the button too, or moving onto it would
                        // leave the row and hide it.
                        .onHover { inside in
                            if inside {
                                hovered = row.key
                            } else if hovered == row.key {
                                hovered = nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
            .overlay {
                if workspace.rows.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(look.secondary)
                        .padding()
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.pageUp) { move(-10) }
            .onKeyPress(.pageDown) { move(10) }
            .onKeyPress(.home) { move(-workspace.rows.count) }
            .onKeyPress(.end) { move(workspace.rows.count) }
            .onKeyPress(.return) {
                guard let key = workspace.selection else { return .ignored }
                workspace.open(key)
                return .handled
            }
            .onKeyPress(.escape) {
                guard workspace.currentTab != nil else { return .ignored }
                workspace.focusTerminal?()
                return .handled
            }
            .onChange(of: workspace.selection) { _, key in
                workspace.select(key)
                if let key { proxy.scrollTo(key) }
            }
        }
    }

    /// Moves the selection like arrow keys in a list.
    private func move(_ delta: Int) -> KeyPress.Result {
        let rows = workspace.rows
        guard !rows.isEmpty else { return .ignored }
        let at = rows.firstIndex { $0.key == workspace.selection } ?? (delta > 0 ? -1 : rows.count)
        workspace.selection = rows[min(max(at + delta, 0), rows.count - 1)].key
        return .handled
    }

    @ViewBuilder
    private func rowMenu(_ key: SessionKey) -> some View {
        let running = workspace.runningKeys.contains(key)
        Button(running ? "Show" : "Resume") { workspace.open(key) }
        if running {
            Button("Close") { actions.close(key) }
        }
        Divider()
        if let row = workspace.rows.first(where: { $0.key == key }) {
            ForEach([Agent.claude, .codex, .shell], id: \.self) { agent in
                Button(agent.newHere) { workspace.newSession(agent, cwd: row.cwd) }
            }
            Divider()
            Button("Show Folder in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.cwd)
            }
            Button("Copy Folder Path") { copy(row.cwd) }
        }
        if key.agent != .shell, !key.id.hasPrefix("new-") {
            Button("Copy Session ID") { copy(key.id) }
        }
    }

    private var emptyMessage: String {
        if !workspace.loaded { return "Loading sessions…" }
        if workspace.hideInactive { return "No running sessions.\nShow inactive ones with ⇧⌘I." }
        if let repo = workspace.repo { return "No sessions in \(repo.name).\nShow all repos from the filter menu." }
        return "No sessions"
    }

    // MARK: - Footer

    private var footer: some View {
        let now = unixNow()
        let usage = [(Agent.claude, workspace.limits.claude), (Agent.codex, workspace.limits.codex)]
            .compactMap { agent, u in u.map { (agent, $0) } }
        return VStack(alignment: .leading, spacing: 10) {
            if let status = workspace.status {
                Label(status, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(look.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if workspace.notificationsOff {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bell.slash")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notifications are off for agentz.")
                        Button("Turn On in System Settings…", action: actions.notificationSettings)
                            .buttonStyle(.link)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(look.secondary)
            }
            if !usage.isEmpty {
                UsageView(usage: usage, now: now, look: look)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !usage.isEmpty || workspace.status != nil || workspace.notificationsOff {
                Rectangle().fill(look.divider).frame(height: 1)
            }
        }
    }
}

/// A repo to make a new worktree in, and the agent to start there.
private struct WorktreeRequest: Identifiable {
    let id = UUID()
    let agent: Agent
    let repo: RecentRepo
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Row

private struct RowView: View {
    let row: Row
    let look: Look
    let selected: Bool
    let listFocused: Bool
    let isCurrent: Bool
    let running: Bool
    let busy: Bool
    let waiting: Bool
    /// The list shows its buttons where the state would be.
    let hovered: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(row.key.agent.icon)
                .font(.system(size: 13))
                .foregroundStyle(look.color(for: row.key.agent))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(running || selected ? look.text : look.text.opacity(0.75))
                    .lineLimit(1)
                Text("\(row.place) · \(age(now: now, row.updated))")
                    .font(.system(size: 11))
                    .foregroundStyle(look.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            state
                .opacity(hovered ? 0 : 1)
                // Room for the buttons, so the text stops before them.
                .frame(width: hovered ? RowButtons.width(closable: running) - 2 : 14)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule()
                    .fill(look.accent)
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .offset(x: -1)
            }
        }
        .contentShape(Rectangle())
        .help("\(row.title)\n\(row.key.agent.name) · \(tilde(row.cwd))")
    }

    private var background: Color {
        if selected { return listFocused ? look.selection : look.hover.opacity(1.6) }
        return hovered ? look.hover : .clear
    }

    @ViewBuilder
    private var state: some View {
        if busy {
            ProgressView()
                .controlSize(.mini)
                .tint(look.yellow)
                .help("Working")
        } else if waiting {
            Image(systemName: "bell.fill")
                .font(.system(size: 10))
                .foregroundStyle(look.accent)
                .help("Done while you were away")
        } else if running {
            Circle()
                .fill(look.green)
                .frame(width: 7, height: 7)
                .help("Running, waiting for you")
        }
    }
}

/// The buttons on a hovered row: start a new session in its folder, and
/// stop the session's agent or shell, like File › Close Session.
private struct RowButtons: View {
    let look: Look
    let closable: Bool
    let start: (Agent) -> Void
    let close: () -> Void

    static let size: CGFloat = 18

    static func width(closable: Bool) -> CGFloat {
        size * (closable ? 4 : 3)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach([Agent.claude, .codex, .shell], id: \.self) { agent in
                RowButton(look: look, help: agent.newHere, action: { start(agent) }) { _ in
                    Text(agent.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(look.color(for: agent))
                }
            }
            if closable {
                RowButton(look: look, help: "Close Session", action: close) { hovered in
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hovered ? look.text : look.secondary)
                }
            }
        }
    }
}

private struct RowButton<Label: View>: View {
    let look: Look
    let help: String
    let action: () -> Void
    @ViewBuilder let label: (_ hovered: Bool) -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label(hovered)
                .frame(width: RowButtons.size, height: RowButtons.size)
                .background(hovered ? look.selection : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Rate limits

/// The agents' rate limits: a bar per window with what is left, and when
/// it starts over. One grid, so the bars line up.
private struct UsageView: View {
    let usage: [(Agent, Usage)]
    let now: UInt64
    let look: Look

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rate limits · left · resets in")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(look.faint)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(usage, id: \.0) { agent, u in
                    GridRow {
                        HStack(spacing: 5) {
                            Text(agent.icon).foregroundStyle(look.color(for: agent))
                            Text(agent.displayName).fontWeight(.semibold)
                        }
                        .gridCellColumns(4)
                        .padding(.top, agent == usage.first?.0 ? 0 : 4)
                    }
                    if let w = u.session { line("5h", w) }
                    if let w = u.week { line("week", w) }
                }
            }
            .font(.system(size: 11))
        }
    }

    private func line(_ label: String, _ w: AgentzCore.Window) -> some View {
        let left = w.left(now)
        let color = left < 10 ? look.red : left < 20 ? look.yellow : look.green
        let reset = w.resetsAt > now ? until(w.resetsAt - now) : ""
        return GridRow {
            Text(label)
                .foregroundStyle(look.secondary)
            Bar(fraction: left / 100, color: color, track: look.fieldBackground)
                .frame(height: 5)
            Text("\(Int(left.rounded()))%")
                .monospacedDigit()
                .foregroundStyle(left < 20 ? color : look.text)
                .gridColumnAlignment(.trailing)
            Text(reset)
                .monospacedDigit()
                .foregroundStyle(look.secondary)
                .gridColumnAlignment(.trailing)
        }
        .help("\(Int(left.rounded()))% of the \(label == "5h" ? "5-hour" : "weekly") limit left" + (reset.isEmpty ? "" : ", starts over in \(reset)"))
    }
}

/// What is left of a limit.
private struct Bar: View {
    let fraction: Double
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 4 : 0))
            }
        }
    }
}

// MARK: - Empty pane

/// Shown in the pane when no terminal is.
struct EmptyPaneView: View {
    let workspace: Workspace
    let look: Look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let key = workspace.selection, !workspace.runningKeys.contains(key),
               let row = workspace.rows.first(where: { $0.key == key })
            {
                HStack(spacing: 8) {
                    Text(row.key.agent.icon).foregroundStyle(look.color(for: row.key.agent))
                    Text(row.title).font(.title3).lineLimit(2)
                }
                Text("\(row.key.agent.name) · \(tilde(row.cwd)) · \(age(now: workspace.now, row.updated))")
                    .foregroundStyle(look.secondary)
                Button("Resume") { workspace.open(key) }
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 4)
            } else {
                Text("Pick a session on the left. Double-click it or press Return to open it.")
                    .foregroundStyle(look.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    hint("⌘N", "New Claude session")
                    hint("⇧⌘N", "New Codex session")
                    hint("⌘T", "New shell")
                    hint("⇧⌘I", "Show inactive sessions")
                    hint("⌘O", "Pick the folder these start in")
                }
            }
        }
        .foregroundStyle(look.text)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(look.background)
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(look.accent)
            Text(text).foregroundStyle(look.secondary)
        }
    }
}

extension Agent {
    var icon: String {
        switch self {
        case .claude: "✻"
        case .codex: "◆"
        case .shell: "❯"
        }
    }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: "Shell"
        }
    }

    /// Starts one in the folder of the session it is for.
    var newHere: String {
        self == .shell ? "New Shell Here" : "New \(displayName) Session Here"
    }
}

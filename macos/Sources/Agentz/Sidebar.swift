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
    var openFolder: () -> Void
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
                Button(action: actions.openFolder) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(look.accent)
                        Text(baseName(workspace.projectDir))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("\(tilde(workspace.projectDir))\nOpen another folder (⌘O)")
                Spacer(minLength: 0)
                Menu {
                    Button("New Claude Session") { workspace.newSession(.claude) }
                    Button("New Codex Session") { workspace.newSession(.codex) }
                    Button("New Shell") { workspace.newSession(.shell) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New session")
                Menu {
                    Toggle("Sessions From All Repos", isOn: $workspace.allRepos)
                    Toggle("Inactive Sessions", isOn: Binding(
                        get: { !workspace.hideInactive },
                        set: { workspace.hideInactive = !$0 }
                    ))
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Which sessions to show")
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
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.rows) { row in
                        let running = workspace.runningKeys.contains(row.key)
                        let closable = running && hovered == row.key
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
                            closable: closable,
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
                            if closable {
                                CloseButton(look: look) { actions.close(row.key) }
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
            Button("New Claude Session Here") { workspace.newSession(.claude, cwd: row.cwd) }
            Button("New Codex Session Here") { workspace.newSession(.codex, cwd: row.cwd) }
            Button("New Shell Here") { workspace.newSession(.shell, cwd: row.cwd) }
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
        if !workspace.allRepos { return "No sessions here.\nShow all repos with ⇧⌘A." }
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
    let hovered: Bool
    /// The list shows a close button where the state would be.
    let closable: Bool
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
                Text("\(baseName(row.cwd)) · \(age(now: now, row.updated))")
                    .font(.system(size: 11))
                    .foregroundStyle(look.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            state
                .opacity(closable ? 0 : 1)
                .frame(width: 14)
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

/// Stops the session's agent or shell, like File › Close Session.
private struct CloseButton: View {
    let look: Look
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovered ? look.text : look.secondary)
                .frame(width: 18, height: 18)
                .background(hovered ? look.selection : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Close")
        .accessibilityLabel("Close Session")
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
                    hint("⌘O", "Open another folder")
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
}

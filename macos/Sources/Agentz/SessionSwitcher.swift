import AgentzCore
import SwiftUI

/// A session in Go to Session, as it was when the sheet opened.
struct SwitcherSession: Identifiable {
    let row: Row
    let state: TabState
    /// It runs in another app, and not here.
    let elsewhere: RunningElsewhere?
    /// Shown in the pane the user works in.
    let isCurrent: Bool
    let note: SessionNote?
    var id: SessionKey { row.key }

    /// Searched after the title: where it ran, its branch, its agent and
    /// its note.
    var detail: String {
        [row.place, row.branch ?? "", row.key.agent.name, tilde(row.cwd), note?.text ?? ""].joined(separator: " ")
    }

    /// Every session, whatever the list's range and filters, the ones shown
    /// most recently first.
    @MainActor
    static func collect(_ workspace: Workspace) -> [SwitcherSession] {
        let notes = Dictionary(workspace.notes.notes.map { ($0.session, $0) }, uniquingKeysWith: { first, _ in first })
        return workspace.switcherRows().map { row in
            let state = workspace.tabState(row.key)
            return SwitcherSession(
                row: row,
                state: state,
                elsewhere: state == .notRunning ? workspace.elsewhere[row.key] : nil,
                isCurrent: workspace.isCurrent(row.key),
                note: notes[row.key.description]
            )
        }
    }

    /// Without a search, the session shown before the current one, so
    /// Return goes back to it, like ⌘Tab.
    static func start(_ shown: [SwitcherSession], query: String) -> SessionKey? {
        let previous = query.allSatisfy(\.isWhitespace) ? shown.first { !$0.isCurrent } : nil
        return (previous ?? shown.first)?.id
    }
}

/// Only the session fields that affect ranking are folded. The snapshot keeps
/// its MRU order; equal scores go into the same bucket in that order.
actor SessionSearchIndex {
    private struct Entry {
        let title: String
        let place: String
        let branch: String?
        let cwd: String
        let note: String?
        let foldedTitle: String
        let foldedDetail: String

        init(_ s: SwitcherSession) {
            title = s.row.title
            place = s.row.place
            branch = s.row.branch
            cwd = s.row.cwd
            note = s.note?.text
            foldedTitle = PaletteSearch.normalized(title)
            foldedDetail = PaletteSearch.normalized(s.detail)
        }

        func matches(_ s: SwitcherSession) -> Bool {
            title == s.row.title && place == s.row.place && branch == s.row.branch && cwd == s.row.cwd && note == s.note?.text
        }
    }
    private var cache: [SessionKey: Entry] = [:]
    private var snapshot: UUID?
    private var entries: [Entry] = []

    func search(_ sessions: [SwitcherSession], snapshot id: UUID, query: String) -> [SwitcherSession] {
        if snapshot != id {
            var ordered = [Entry]()
            var next = [SessionKey: Entry]()
            for session in sessions {
                if Task.isCancelled { return [] }
                let entry: Entry
                if let cached = cache[session.id], cached.matches(session) { entry = cached }
                else { entry = Entry(session) }
                next[session.id] = entry
                ordered.append(entry)
            }
            cache = next
            entries = ordered
            snapshot = id
        }
        let words = PaletteSearch.normalized(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return sessions }
        var buckets: [Int: [SwitcherSession]] = [:]
        for (i, entry) in entries.enumerated() {
            if Task.isCancelled { return [] }
            if let score = PaletteSearch.score(words, title: entry.foldedTitle, detail: entry.foldedDetail) {
                buckets[score, default: []].append(sessions[i])
            }
        }
        return buckets.keys.sorted().flatMap { buckets[$0] ?? [] }
    }
}

extension PaletteSheet {
    /// Go to Session: shows the picked session, or resumes it.
    func showSessions(in parent: NSWindow, workspace: Workspace) {
        let sessions = SwitcherSession.collect(workspace)
        let now = Date()
        let snapshot = UUID(), index = sessionIndex
        show(in: parent, title: "Go to Session") { close in
            PaletteView(
                title: "Go to Session", keys: "⌘E", prompt: "Search sessions…", empty: "No matching sessions", verb: "open",
                items: sessions, backgroundSearch: { await index.search(sessions, snapshot: snapshot, query: $0) }, start: SwitcherSession.start,
                label: { "\($0.row.key.agent.name), \($0.row.title), \($0.row.place)" },
                row: { SwitcherRow(session: $0, now: now) }
            ) { session in
                close(session.map { session in
                    {
                        workspace.selection = session.id
                        workspace.open(session.id)
                    }
                })
            }
        }
    }
}

private struct SwitcherRow: View {
    let session: SwitcherSession
    let now: Date

    private var row: Row { session.row }

    var body: some View {
        let look = Look.shared
        HStack(spacing: 10) {
            row.key.agent.icon
                .font(.system(size: 13))
                .foregroundStyle(look.color(for: row.key.agent))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 13, weight: session.isCurrent ? .semibold : .regular))
                        .foregroundStyle(look.text)
                    if session.note != nil {
                        Image(systemName: "note.text")
                            .font(.system(size: 10))
                            .foregroundStyle(look.accent)
                    }
                    if row.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(look.secondary)
                    }
                    if row.bookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(look.secondary)
                    }
                }
                subtitle.font(.system(size: 11))
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if session.isCurrent {
                Text("Shown").font(.system(size: 11)).foregroundStyle(look.secondary)
            }
            state.frame(width: 16)
        }
        .help("\(row.title)\n\(row.key.agent.name) · \(tilde(row.cwd))")
    }

    /// What it wants, else what it does, else where and when it ran.
    @ViewBuilder
    private var subtitle: some View {
        let look = Look.shared
        switch session.state {
        case let .waiting(message):
            Text(message).foregroundStyle(look.accent)
        case .quit:
            Text("Quit while you were away").foregroundStyle(look.red)
        case .busy where row.action != nil:
            if let action = row.action {
                Text("\(Image(systemName: action.kind.symbol)) \(action.detail)").foregroundStyle(look.secondary)
            }
        default:
            Group {
                if let branch = row.branch {
                    Text("\(row.place) · \(Image(systemName: "arrow.triangle.branch")) \(branch) · \(age(now: now, row.updated))")
                } else {
                    Text("\(row.place) · \(age(now: now, row.updated))")
                }
            }
            .foregroundStyle(look.secondary)
        }
    }

    @ViewBuilder
    private var state: some View {
        let look = Look.shared
        switch session.state {
        case .quit:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(look.red)
                .help("Quit while you were away. Open it to resume.")
        case .waiting:
            Image(systemName: "bell.fill")
                .font(.system(size: 11))
                .foregroundStyle(look.accent)
                .help("Waiting for you")
        case .busy:
            ProgressView()
                .controlSize(.mini)
                .tint(look.yellow)
                .help("Working")
        case .running:
            Circle()
                .fill(look.green)
                .frame(width: 7, height: 7)
                .help("Running, waiting for you")
        case .notRunning:
            if let elsewhere = session.elsewhere {
                Image(systemName: "macwindow")
                    .font(.system(size: 10))
                    .foregroundStyle(look.secondary)
                    .help("Running in \(elsewhere.appName)")
            }
        }
    }
}

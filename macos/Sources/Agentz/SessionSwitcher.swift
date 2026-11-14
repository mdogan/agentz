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
        workspace.switcherRows().map { row in
            let state = workspace.tabState(row.key)
            return SwitcherSession(
                row: row,
                state: state,
                elsewhere: state == .notRunning ? workspace.elsewhere[row.key] : nil,
                isCurrent: workspace.isCurrent(row.key),
                note: workspace.notes.note(for: row.key)
            )
        }
    }

    @MainActor
    static func search(_ sessions: [SwitcherSession], query: String) -> [SwitcherSession] {
        PaletteSearch.rank(sessions, query: query, title: \.row.title, detail: \.detail)
    }

    /// Without a search, the session shown before the current one, so
    /// Return goes back to it, like ⌘Tab.
    static func start(_ shown: [SwitcherSession], query: String) -> SessionKey? {
        let previous = query.allSatisfy(\.isWhitespace) ? shown.first { !$0.isCurrent } : nil
        return (previous ?? shown.first)?.id
    }
}

extension PaletteSheet {
    /// Go to Session: shows the picked session, or resumes it.
    func showSessions(in parent: NSWindow, workspace: Workspace) {
        let sessions = SwitcherSession.collect(workspace)
        let now = Date()
        show(in: parent, title: "Go to Session") { close in
            PaletteView(
                title: "Go to Session", keys: "⌘E", prompt: "Search sessions…", empty: "No matching sessions", verb: "open",
                items: sessions, search: SwitcherSession.search, start: SwitcherSession.start,
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

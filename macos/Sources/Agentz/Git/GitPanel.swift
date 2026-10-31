import AgentzCore
import AppKit
import SwiftUI

/// What the Changes panel shows: the uncommitted changes in the repository
/// of the shown session, or of the one picked in the list. It follows them; there is no other way to pick a
/// repository. Its store reads the repository only while the panel is shown
/// and the window can be seen.
@MainActor
@Observable
final class GitPanelModel {
    enum Place: Equatable {
        /// No session is shown or picked.
        case noFolder
        case notARepo(folder: String)
        case repository
    }

    /// GitFork's state and actions for one repository.
    @ObservationIgnored let store = RepositoryStore()
    private(set) var place = Place.noFolder

    /// The store, while the panel is shown with a repository: actions from
    /// the menu go there. Hidden, the store may still hold a repository the
    /// panel showed before.
    var shownStore: RepositoryStore? {
        isShown && place == .repository && store.repositoryURL != nil ? store : nil
    }
    /// The panel is on screen.
    var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            if isShown { show() }
            updateMonitoring()
        }
    }

    @ObservationIgnored private var folder: String?
    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private var resolving: Task<Void, Never>?
    @ObservationIgnored private let client = GitClient()

    /// Shows the repository `folder` is in from now on. Nil when no session
    /// is shown or picked.
    func follow(_ folder: String?) {
        guard folder != self.folder else { return }
        self.folder = folder
        if isShown { show() }
    }

    /// The window can (or can no longer) be seen.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateMonitoring()
    }

    private func show() {
        resolving?.cancel()
        guard let folder else {
            set(.noFolder)
            return
        }
        resolving = Task {
            let root = await GitCommandLogScope.$isSuppressed.withValue(true) {
                try? await client.repositoryRoot(from: URL(fileURLWithPath: folder, isDirectory: true))
            }
            guard !Task.isCancelled, folder == self.folder else { return }
            guard let root else {
                set(.notARepo(folder: folder))
                return
            }
            set(.repository)
            // Another folder of the same worktree changes nothing.
            if store.repositoryURL?.standardizedFileURL != root.standardizedFileURL {
                store.openRepository(root)
            }
        }
    }

    private func set(_ new: Place) {
        if new != place { place = new }
        updateMonitoring()
    }

    private func updateMonitoring() {
        store.setMonitoringActive(isShown && windowVisible && place == .repository)
    }
}

/// The Changes panel, on the right of the window: the staged and unstaged
/// files in the shown session's repository, with GitFork's lists. It stages,
/// unstages and discards files, resolves conflicts and commits. A file's
/// button, or a double-click on it, shows its diff in the repository's git
/// tab, which has the rest of git.
struct GitPanel: View {
    let model: GitPanelModel
    @ObservedObject var store: RepositoryStore
    let look: Look
    /// Opens the repository's git tab, showing the diff of a change if one
    /// is given.
    let openGit: (ChangeEntryID?) -> Void
    @State private var showingStashSheet = false
    @State private var stashScope = StashScope.all

    init(model: GitPanelModel, look: Look, openGit: @escaping (ChangeEntryID?) -> Void) {
        self.model = model
        store = model.store
        self.look = look
        self.openGit = openGit
    }

    var body: some View {
        Group {
            switch model.place {
            case .noFolder:
                placeholder("Show or pick a session to see its changes.")
            case let .notARepo(folder):
                placeholder("\(tilde(folder)) is not in a git repository.")
            case .repository:
                changes
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(look.text)
        .background(look.sidebar.ignoresSafeArea())
        .tint(look.accent)
        .environmentObject(store)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .multilineTextAlignment(.center)
            .foregroundStyle(look.secondary)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var changes: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(look.divider).frame(height: 1)
            GitChangesView(showingStashSheet: $showingStashSheet, stashScope: $stashScope, showsStash: false)
                .environment(\.openChange) { openGit($0) }
        }
        .modifier(GitDialogs(store: store, showingStashSheet: $showingStashSheet, stashScope: stashScope))
    }

    /// The repository, where HEAD is, and the way to the rest of git.
    private var header: some View {
        HStack(spacing: 6) {
            Button {
                store.showBranchPicker()
            } label: {
                BranchToolbarBadge(branch: store.branch, ahead: store.ahead, behind: store.behind)
            }
            .buttonStyle(.plain)
            .help("Switch to another branch")
            Spacer(minLength: 4)
            Text(store.repositoryName)
                .font(.system(size: 11))
                .foregroundStyle(look.secondary)
                .lineLimit(1)
                .help(store.repositoryURL.map { tilde($0.path) } ?? "")
            ToolbarIconButton("Open Git", systemImage: "arrow.up.left.and.arrow.down.right", help: "Open the repository's diffs, history, branches and the rest in a git tab (⌥⌘G). A double-click on a file opens its diff there.") {
                openGit(nil)
            }
            ToolbarIconButton("Refresh", systemImage: "arrow.clockwise", help: "Read the changes again. They are read again by themselves when files change.") {
                store.refresh()
            }
            .disabled(store.isLoading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 36)
    }
}

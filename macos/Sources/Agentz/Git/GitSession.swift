import AgentzCore
import AppKit
import Combine
import SwiftUI

/// A tab that shows a repository's git client: GitFork's whole window, in a
/// pane like a terminal. There is one per worktree. It has a store of its
/// own, so what it shows does not change the Changes panel; each reads the
/// repository again when files change. It reads only while it is in a pane
/// and the window can be seen.
@MainActor
final class GitSession: PaneContent {
    let root: URL
    let store = RepositoryStore()
    /// Takes no clicks meant for the terminals while hidden.
    private let host: PaneHostingView<GitSessionView>
    private(set) var isRunning = true
    private var visible = false
    private var windowVisible = true
    /// A change to show once the repository is read and has it.
    private var pendingChange: ChangeEntryID?
    private var changesRead: AnyCancellable?

    init(root: URL) {
        self.root = root
        host = PaneHostingView(rootView: GitSessionView(store: store, look: Look.shared))
        // Read once now; watch only while shown.
        store.setMonitoringActive(false)
        store.openRepository(root)
        // `changes` is published before it changes: look after.
        changesRead = store.$changes.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.showPendingChange() }
        }
    }

    /// Shows the changes, with the diff of the file `id`, as soon as the
    /// repository has it.
    func showChange(_ id: ChangeEntryID) {
        pendingChange = id
        store.selectChanges()
        showPendingChange()
    }

    private func showPendingChange() {
        guard let id = pendingChange, store.changeEntries.contains(where: { $0.id == id }) else { return }
        pendingChange = nil
        if store.selectedSection != .changes { store.selectChanges() }
        store.selectChangeEntry(id)
    }

    /// The branch it is on, for the session list.
    var title: String {
        switch BranchDisplay(store.branch) {
        case let .branch(name): name.isEmpty ? "Git" : name
        case let .detached(hash): "Detached at \(hash)"
        }
    }

    var paneView: NSView { host }

    var isFocused: Bool {
        (host.window?.firstResponder as? NSView)?.isDescendant(of: host) == true
    }

    func focus() {
        host.window?.makeFirstResponder(host)
    }

    func setVisible(_ visible: Bool) {
        host.isHidden = !visible
        self.visible = visible
        updateMonitoring()
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateMonitoring()
    }

    func close() {
        isRunning = false
        updateMonitoring()
    }

    private func updateMonitoring() {
        store.setMonitoringActive(isRunning && visible && windowVisible)
    }
}

/// A repository's git in a pane: a bar with where HEAD is, the tabs and
/// the repository's actions; under it the changes, the history or the
/// branches on the left, and the picked file or commit on the right.
struct GitSessionView: View {
    @ObservedObject var store: RepositoryStore
    let look: Look
    @State private var showingStashSheet = false
    @State private var stashScope = StashScope.all

    var body: some View {
        // In a pane narrower than its columns, e.g. in a small window, they
        // start at its left edge and the pane cuts off the right of the
        // last one. Centered, the pane cut off both ends.
        VStack(alignment: .leading, spacing: 0) {
            GitSessionBar()
            Rectangle().fill(look.divider).frame(height: 1)
            HSplitView {
                // A stack, not a Group: the split view would take each view
                // in a Group as a column of its own, so a new tab would be a
                // new column, at the first width and not the one it was given.
                ZStack {
                    if store.showsReferences {
                        GitSidebarView()
                    } else {
                        switch store.selectedSection {
                        case .history:
                            HistoryView()
                        case .changes:
                            GitChangesView(showingStashSheet: $showingStashSheet, stashScope: $stashScope)
                        }
                    }
                }
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 600)
                .background(look.sidebar)
                DetailView()
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(.system(size: 12))
        .foregroundStyle(look.text)
        .background(look.background)
        .tint(look.accent)
        .environmentObject(store)
        .modifier(GitDialogs(store: store, showingStashSheet: $showingStashSheet, stashScope: stashScope))
    }
}

/// The bar on top of a git tab: where HEAD is, the tabs, the repository's
/// actions and the repository.
private struct GitSessionBar: View {
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        HStack(spacing: 2) {
            Button {
                store.showBranchPicker()
            } label: {
                BranchToolbarBadge(branch: store.branch, ahead: store.ahead, behind: store.behind)
            }
            .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
            .help("Switch to another branch (⌘B)")
            .padding(.trailing, 10)
            GitTabButton(title: "Changes", count: store.changes.count, isSelected: !store.showsReferences && store.selectedSection == .changes,
                         help: "The staged and unstaged changes (⌘P)") {
                if store.selectedSection == .changes {
                    store.showsReferences = false
                } else {
                    store.selectChanges()
                }
            }
            GitTabButton(title: "History", count: nil, isSelected: !store.showsReferences && store.selectedSection == .history,
                         help: "The commits, of all branches or of the one picked under Branches") {
                if store.selectedSection == .history {
                    store.showsReferences = false
                } else {
                    store.selectReference(nil)
                }
            }
            GitTabButton(title: "Branches", count: nil, isSelected: store.showsReferences,
                         help: "The branches, remotes, tags, stashes and worktrees") {
                store.showsReferences = true
            }
            Spacer(minLength: 12)
            ToolbarIconButton("Fetch", systemImage: "arrow.down.circle", help: "Fetch all remotes") {
                store.fetch()
            }
            .disabled(store.isLoading)
            ToolbarIconButton("Pull", systemImage: "arrow.down.to.line", help: "Pull with fast-forward only") {
                store.pull()
            }
            .disabled(store.isLoading)
            ToolbarIconButton("Push", systemImage: "arrow.up.to.line", help: "Push the current branch") {
                store.requestPushConfirmation()
            }
            .disabled(store.isLoading)
            ToolbarSeparator()
            ToolbarIconButton(
                "New Branch", systemImage: "arrow.triangle.branch", badge: "plus.circle.fill",
                help: "Create a branch at HEAD and switch to it"
            ) {
                store.isShowingNewBranchSheet = true
            }
            .disabled(store.isLoading)
            ToolbarIconButton("Refresh", systemImage: "arrow.clockwise", help: "Read the repository again (⌘R)") {
                store.refresh()
            }
            .disabled(store.isLoading)
            ToolbarSeparator()
            ToolbarIconButton("Git Command Log", systemImage: "terminal", help: "The git commands run here, and how each went (⇧⌘L)") {
                GitCommandLog.shared.requestFocus(on: store.repositoryURL)
                GitWindows.openCommandLog()
            }
            ToolbarIconButton("Open in Zed", systemImage: "chevron.left.forwardslash.chevron.right", help: "Open the repository in Zed") {
                store.openZedEditor()
            }
            ToolbarIconButton("Show in Finder", systemImage: "folder", help: "Show the repository in Finder") {
                store.openInFinder()
            }
            repository
                .padding(.leading, 8)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 36)
    }

    /// The repository, and the worktree when it is not the main one.
    private var repository: some View {
        let look = Look.shared
        return HStack(spacing: 3) {
            Text(store.repositoryName)
            if let root = store.repositoryURL, root != store.mainWorktreeURL {
                Text("·").foregroundStyle(look.faint)
                Text(baseName(root.path))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(look.secondary)
        .lineLimit(1)
        .help(store.repositoryURL.map { tilde($0.path) } ?? "")
    }
}

/// A tab in the git tab's bar: what its left column shows.
private struct GitTabButton: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let look = Look.shared
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(isSelected ? look.text : look.secondary)
                if let count, count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? look.secondary : look.faint)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                isSelected ? look.selection : hovered ? look.hover : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The sheets, alerts and the busy label the git views use, for both the
/// Changes panel and the git tab.
struct GitDialogs: ViewModifier {
    @ObservedObject var store: RepositoryStore
    @Binding var showingStashSheet: Bool
    let stashScope: StashScope
    /// It can show a branch's commits: the git tab can, the Changes panel can't.
    var showsHistory = true

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let label = store.operationLabel {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(label).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: store.operationLabel)
            .sheet(isPresented: $store.isShowingNewBranchSheet) {
                BranchSheet(isPresented: $store.isShowingNewBranchSheet)
                    .environmentObject(store)
                    .lookWindowStyle()
            }
            .sheet(isPresented: $showingStashSheet) {
                StashSheet(isPresented: $showingStashSheet, scope: stashScope)
                    .environmentObject(store)
                    .lookWindowStyle()
            }
            .sheet(isPresented: $store.isShowingBranchPicker) {
                BranchPickerSheet(showsCommits: showsHistory)
                    .environmentObject(store)
                    .lookWindowStyle()
            }
            .sheet(isPresented: $store.isShowingPathHistoryPicker) {
                PathHistoryPickerSheet()
                    .environmentObject(store)
                    .lookWindowStyle()
            }
            .sheet(isPresented: $store.isShowingCommitHashPicker) {
                CommitHashPickerSheet()
                    .environmentObject(store)
                    .lookWindowStyle()
            }
            .alert(
                "Switch to \(store.pendingCheckout?.reference.name ?? "the Branch")?",
                isPresented: Binding(
                    get: { store.pendingCheckout != nil },
                    set: { if !$0 { store.cancelCheckout() } }
                )
            ) {
                Button("Cancel", role: .cancel) { store.cancelCheckout() }
                switch store.pendingCheckout?.reason {
                case .agentsWorking:
                    Button("Switch Anyway", role: .destructive) { store.checkoutDespiteAgents() }
                case .overwrites:
                    Button("Stash and Switch") { store.stashAndCheckout() }
                case nil:
                    EmptyView()
                }
            } message: {
                Text(checkoutMessage)
            }
            .alert("Push \(store.pendingPushPlan?.branchName ?? store.branch)?", isPresented: $store.isConfirmingPush) {
                Button("Cancel", role: .cancel) { store.cancelPushConfirmation() }
                Button("Push") { store.push() }
            } message: {
                Text(pushMessage)
            }
            .alert(
                "Git",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
    }

    private var checkoutMessage: String {
        switch store.pendingCheckout?.reason {
        case let .agentsWorking(agents):
            let who = agents.count == 1
                ? "\(agents[0]) is working in this worktree."
                : "\(agents.formatted(.list(type: .and))) are working in this worktree."
            return "\(who)\n\nSwitching changes the files during that work. Agents aren't told, "
                + "so they may go on as if nothing changed, and their work may end up on the wrong branch."
        case let .overwrites(files):
            return overwriteMessage(files)
        case nil:
            return ""
        }
    }

    private func overwriteMessage(_ files: [String]) -> String {
        var names = files.prefix(3).map { ($0 as NSString).lastPathComponent }
        if files.count > names.count { names.append("\(files.count - names.count) more") }
        return "Switching would overwrite your changes to \(names.formatted(.list(type: .and))).\n\n"
            + "Stash and Switch puts all your changes away first, untracked files too. "
            + "To get them back, apply the stash under Branches in the git tab."
    }

    private var pushMessage: String {
        guard let plan = store.pendingPushPlan else {
            return "No safe place to push to was found."
        }
        let summary: String
        if let ahead = plan.ahead, ahead > 0 {
            summary = "\(ahead) \(ahead == 1 ? "commit" : "commits") from \(plan.branchName)"
        } else {
            summary = plan.branchName
        }
        let upstream = plan.target.establishesUpstream ? " and set it as the upstream branch" : ""
        return "This will push \(summary) to \(plan.target.displayName)\(upstream)."
    }
}

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
    private let host: NSHostingView<GitSessionView>
    private(set) var isRunning = true
    private var visible = false
    private var windowVisible = true
    /// A change to show once the repository is read and has it.
    private var pendingChange: ChangeEntryID?
    private var changesRead: AnyCancellable?

    init(root: URL) {
        self.root = root
        host = NSHostingView(rootView: GitSessionView(store: store, look: Look.shared))
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

/// GitFork's window in a pane: the branches, worktrees, stashes and tags
/// on the left, the history or the changes in the middle, and the picked
/// commit or file on the right, under a bar with the repository's actions.
struct GitSessionView: View {
    @ObservedObject var store: RepositoryStore
    let look: Look
    @State private var showingStashSheet = false
    @State private var stashScope = StashScope.all

    var body: some View {
        VStack(spacing: 0) {
            GitSessionBar()
            Rectangle().fill(look.divider).frame(height: 1)
            HSplitView {
                GitSidebarView(showsSections: true)
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 320)
                Group {
                    switch store.selectedSection {
                    case .history:
                        HistoryView()
                    case .changes:
                        GitChangesView(showingStashSheet: $showingStashSheet, stashScope: $stashScope)
                    }
                }
                .frame(minWidth: 300, idealWidth: 430, maxWidth: 640)
                DetailView()
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .foregroundStyle(look.text)
        .background(look.background)
        .tint(look.accent)
        .environmentObject(store)
        .modifier(GitDialogs(store: store, showingStashSheet: $showingStashSheet, stashScope: stashScope))
    }
}

/// GitFork's toolbar as a bar on top of the pane: the outside tools, the
/// remote, then the branch; where HEAD is in the middle; the repository on
/// the right.
private struct GitSessionBar: View {
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton("Open in Zed", systemImage: "chevron.left.forwardslash.chevron.right", help: "Open the repository in Zed") {
                store.openZedEditor()
            }
            ToolbarIconButton("Show in Finder", systemImage: "folder", help: "Show the repository in Finder") {
                store.openInFinder()
            }
            ToolbarSeparator()
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
            Spacer(minLength: 12)
            Button {
                store.showBranchPicker()
            } label: {
                BranchToolbarBadge(branch: store.branch, ahead: store.ahead, behind: store.behind)
            }
            .buttonStyle(.plain)
            .help("Switch to another branch (⌘B)")
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 0) {
                Text(store.repositoryName)
                    .font(.system(size: 12, weight: .semibold))
                if let root = store.repositoryURL, root != store.mainWorktreeURL {
                    Text(baseName(root.path))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .help(store.repositoryURL.map { tilde($0.path) } ?? "")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }
}

/// The sheets, alerts and the busy label the git views use, for both the
/// Changes panel and the git tab.
struct GitDialogs: ViewModifier {
    @ObservedObject var store: RepositoryStore
    @Binding var showingStashSheet: Bool
    let stashScope: StashScope

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let label = store.operationLabel {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(label).font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
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
                BranchPickerSheet()
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

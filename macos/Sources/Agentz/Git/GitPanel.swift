import AgentzCore
import AppKit
import SwiftUI

/// What the git panel shows: the repository of the shown session, or of the
/// one picked in the list. It follows them; there is no other way to pick a
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
    var tab = GitPanel.Tab.changes
    var showingBranchSheet = false

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

/// The git panel, on the right of the window: the shown session's
/// repository, with GitFork's views stacked for a narrow panel. Changes
/// stages, unstages and discards files or single lines, and commits;
/// History shows the commits and what each changed; Branches holds the
/// branches, remotes, tags, worktrees and stashes.
struct GitPanel: View {
    @Bindable var model: GitPanelModel
    @ObservedObject var store: RepositoryStore
    let look: Look
    @State private var showingStashSheet = false
    @State private var stashScope = StashScope.all

    enum Tab: Hashable {
        case changes, history, branches
    }

    init(model: GitPanelModel, look: Look) {
        self.model = model
        store = model.store
        self.look = look
    }

    var body: some View {
        Group {
            switch model.place {
            case .noFolder:
                placeholder("Show or pick a session to see its repository.")
            case let .notARepo(folder):
                placeholder("\(tilde(folder)) is not in a git repository.")
            case .repository:
                repository
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

    private var repository: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $model.tab) {
                Text(store.changes.isEmpty ? "Changes" : "Changes \(store.changes.count)").tag(Tab.changes)
                Text("History").tag(Tab.history)
                Text("Branches").tag(Tab.branches)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Rectangle().fill(look.divider).frame(height: 1)
            switch model.tab {
            case .changes:
                VSplitView {
                    GitChangesView(showingStashSheet: $showingStashSheet, stashScope: $stashScope)
                        .frame(minHeight: 140, idealHeight: 300)
                    DetailView()
                        .frame(minHeight: 160)
                }
            case .history:
                VSplitView {
                    HistoryView()
                        .frame(minHeight: 140, idealHeight: 300)
                    DetailView()
                        .frame(minHeight: 160)
                }
            case .branches:
                GitSidebarView()
            }
        }
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
        // The tabs and the store's own section stay in step: GitFork's
        // views pick what they show from the section.
        .onChange(of: model.tab) { _, tab in
            switch tab {
            case .changes:
                if store.selectedSection != .changes { store.selectChanges() }
                pickFirstChange()
            case .history:
                if store.selectedSection != .history { store.selectedSection = .history }
            case .branches:
                break
            }
        }
        .onChange(of: store.selectedSection) { _, section in
            if section == .changes {
                model.tab = .changes
            } else if model.tab == .changes {
                model.tab = .history
            }
        }
        // Picking a branch, tag or stash shows its history.
        .onChange(of: store.selectedReference) { _, reference in
            if reference != nil, model.tab == .branches { model.tab = .history }
        }
        .onChange(of: store.selectedStash) { _, stash in
            if stash != nil, model.tab == .branches { model.tab = .history }
        }
        .onChange(of: store.historyScope) { _, _ in
            if model.tab == .branches { model.tab = .history }
        }
        .onChange(of: store.repositoryURL) { _, _ in
            if model.tab == .changes, store.selectedSection != .changes { store.selectChanges() }
        }
        .onChange(of: store.changes) { _, _ in pickFirstChange() }
        .onAppear { pickFirstChange() }
        .sheet(isPresented: $model.showingBranchSheet) {
            BranchSheet(isPresented: $model.showingBranchSheet)
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

    /// The repository, where HEAD is, and the actions on the remote and
    /// the branch.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(store.repositoryName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .help(store.repositoryURL.map { tilde($0.path) } ?? "")
                Spacer(minLength: 4)
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
                    model.showingBranchSheet = true
                }
                .disabled(store.isLoading)
                ToolbarIconButton("Refresh", systemImage: "arrow.clockwise", help: "Read the repository again") {
                    store.refresh()
                }
                .disabled(store.isLoading)
            }
            Button {
                store.showBranchPicker()
            } label: {
                BranchToolbarBadge(branch: store.branch, ahead: store.ahead, behind: store.behind)
            }
            .buttonStyle(.plain)
            .help("Switch to another branch")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Files show up by themselves as the agent works: with none picked,
    /// the first one's diff shows.
    private func pickFirstChange() {
        guard model.tab == .changes, store.selectedSection == .changes, store.selectedChange == nil,
              let first = store.changeEntries.first
        else { return }
        store.selectChangeEntry(first.id)
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

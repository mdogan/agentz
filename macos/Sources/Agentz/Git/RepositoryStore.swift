import AgentzCore
import AppKit
import Combine
import Foundation

@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositoryURL: URL?
    /// The main worktree of the repository this window shows. It is
    /// `repositoryURL` itself unless the window shows a linked worktree, so
    /// the repository keeps its name while the window moves between worktrees.
    @Published private(set) var mainWorktreeURL: URL?
    @Published private(set) var branch = ""
    @Published private(set) var upstream: String?
    @Published private(set) var pushTarget: GitPushTarget?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var changes: [WorkingChange] = []
    @Published private(set) var references: [GitReference] = []
    @Published private(set) var stashes: [GitStash] = []
    @Published private(set) var worktrees: [GitWorktree] = []
    @Published private(set) var commits: [GitCommit] = [] {
        didSet { lineages = [:] }
    }
    /// The loaded commits each tip leads to, by the tip's hash.
    private var lineages: [String: Set<String>] = [:]
    /// A rebase, merge, cherry-pick or revert that stopped and waits.
    @Published private(set) var operation: GitOperationInProgress?
    /// An action that asks first.
    @Published var confirmation: GitConfirmation?
    /// The commits the interactive rebase sheet rewrites.
    @Published var rebasePlan: RebasePlan?
    /// The commit whose message the sheet edits.
    @Published var rewordRequest: RewordRequest?
    /// Tells the app about a worktree made here, so its list picks it up.
    var worktreeMade: ((NewWorktree) -> Void)?
    @Published private(set) var canLoadMoreHistory = false
    @Published private(set) var isLoadingMoreHistory = false
    @Published private(set) var diff = ""
    @Published private(set) var conflictDocument: ConflictDocument?
    @Published private(set) var isLoading = false
    @Published private(set) var operationLabel: String?
    @Published var compactDetailShown = false
    @Published var selectedSection: WorkspaceSection = .history {
        didSet { if oldValue != selectedSection { compactDetailShown = false } }
    }
    @Published private(set) var historyScope: CommitHistoryScope = .currentBranch
    @Published var selectedCommit: GitCommit?
    @Published private(set) var selectedChange: WorkingChange?
    @Published private(set) var selectedChangeIsStaged = false
    /// The Changes view shows the selected file in the editor, not its diff.
    @Published var isEditingFile = false
    @Published private(set) var changeSelection = ChangeSelectionModel()
    @Published var selectedReference: GitReference?
    @Published var selectedStash: GitStash?
    @Published var searchText = "" {
        didSet { if oldValue != searchText { searchHistory() } }
    }
    @Published private(set) var searchingHistory = false
    @Published private var olderMatches: [GitCommit] = []
    private var historySearchTask: Task<Void, Never>?
    @Published var commitMessage = ""
    @Published var amend = false
    @Published var signCommit = false {
        didSet {
            UserDefaults.standard.set(signCommit, forKey: Self.signCommitKey)
        }
    }
    @Published var errorMessage: String?
    @Published private(set) var branchPendingForceDelete: GitReference?
    /// A switch that waits for the user: agents work in the worktree, or
    /// git refused because of uncommitted changes.
    @Published private(set) var pendingCheckout: PendingCheckout?
    /// The last pick in the branch list made during another operation. It
    /// runs when that one ends: clicking down the list isn't an error.
    private var queuedPick: (() -> Void)?
    @Published private(set) var worktreePendingForceDelete: GitWorktree?
    @Published private(set) var pendingPushPlan: GitPushPlan?
    @Published private(set) var pendingBranchMove: GitBranchMove?
    @Published var isConfirmingPush = false
    @Published var isShowingBranchPicker = false
    /// The sheet that names a new branch.
    @Published var isShowingNewBranchSheet = false
    /// Where the sheet's branch starts. Without one, it starts at HEAD.
    @Published private(set) var newBranchStart: GitReference?
    /// Whether the sheet's checkbox to check out the branch starts on.
    @Published private(set) var newBranchChecksOut = true
    @Published var isShowingPathHistoryPicker = false
    @Published var isShowingCommitHashPicker = false
    @Published var isShowingKeyboardShortcuts = false
    @Published private(set) var commitReveal: CommitReveal?
    @Published private(set) var repositoryPathItems: [RepositoryPathItem] = []
    @Published private(set) var isLoadingRepositoryPaths = false

    /// Starts a session of the agent in a folder, e.g. in another
    /// worktree. The panel's host sets it.
    var startSession: ((Agent, URL) -> Void)?
    /// The agents working in a worktree right now, to warn before its files
    /// change under them. Described for the user to read.
    var agentsWorking: ((URL) -> [String])?

    private let client = GitClient()
    private var loadGeneration = 0
    private var detailTask: Task<Void, Never>?
    private var historyPaginationTask: Task<Void, Never>?
    private var historyPaginationID: UUID?
    private var historyNextOffset = 0
    private var repositoryPathTask: Task<Void, Never>?
    private var repositoryPathLoadID: UUID?
    private var monitorTask: Task<Void, Never>?
    /// Wakes the monitor when files in the worktree or its git folder change.
    private var watcher: FolderWatcher?
    private var monitoredState: RepositoryStateToken?
    private var isMonitoringActive = true
    private var activeOperationID: UUID?
    private var cachedCommitHash: String?
    private var cachedCommitDetails: String?
    private var cachedVerifiedCommit: GitCommit?
    private let monitorInterval: Duration
    private let historyPageSize: Int
    private static let signCommitKey = "signCommitsWithGPG"

    /// `monitorInterval`: how often the repository is checked when no
    /// file change woke the check, in case one went unnoticed.
    init(
        monitorInterval: Duration = .seconds(30),
        historyPageSize: Int = GitClient.historyPageSize
    ) {
        precondition(historyPageSize > 0)
        self.monitorInterval = monitorInterval
        self.historyPageSize = historyPageSize
        signCommit = UserDefaults.standard.bool(forKey: Self.signCommitKey)
    }

    var repositoryName: String {
        mainWorktreeURL?.lastPathComponent ?? "Git"
    }

    var stagedChanges: [WorkingChange] {
        changes.filter(\.isStaged)
    }

    var conflictedChanges: [WorkingChange] {
        changes.filter(\.isConflicted)
    }

    var unstagedChanges: [WorkingChange] {
        changes.filter(\.isUnstaged)
    }

    /// Every change-list row in the order the list draws them: staged first,
    /// then conflicts, then working tree. Each section is in folder-tree order.
    /// Shift-click ranges follow this order.
    var changeEntries: [ChangeEntry] {
        ChangeTree.ordered(stagedChanges.map { ChangeEntry($0, staged: true) })
            + ChangeTree.ordered(conflictedChanges.map { ChangeEntry($0, staged: false) })
            + ChangeTree.ordered(unstagedChanges.map { ChangeEntry($0, staged: false) })
    }

    var selectedChangeEntries: [ChangeEntry] {
        changeEntries.filter { changeSelection.contains($0.id) }
    }

    private var changeOrder: [ChangeEntryID] {
        changeEntries.map(\.id)
    }

    var filteredCommits: [GitCommit] {
        guard !searchText.isEmpty else { return commits }
        let loaded = commits.filter { $0.matchesHistory(searchText) }
        var seen = Set(loaded.map(\.hash))
        return loaded + olderMatches.filter { seen.insert($0.hash).inserted }
    }

    private func searchHistory() {
        historySearchTask?.cancel()
        olderMatches = []
        let query = searchText, scope = historyScope
        guard !query.isEmpty, canLoadMoreHistory, let root = repositoryURL else {
            searchingHistory = false
            return
        }
        searchingHistory = true
        let offset = historyNextOffset
        historySearchTask = Task { [weak self, client] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                var next = offset
                let batch = scope == .lostAndDangling ? Int(Int32.max) : 2048
                while !Task.isCancelled {
                    let page = try await client.searchPage(at: root, scope: scope, offset: next, limit: batch, query: query)
                    try Task.checkCancellation()
                    guard let self, self.historyScope == scope, self.isCurrentRepository(root) else { return }
                    if !page.matches.isEmpty { self.olderMatches += page.matches }
                    next += page.count
                    if page.count < batch { break }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(error)
            }
            if !Task.isCancelled { self?.searchingHistory = false }
        }
    }

    func showPathHistoryPicker() {
        guard let root = repositoryURL else { return }
        isShowingPathHistoryPicker = true
        repositoryPathTask?.cancel()

        let loadID = UUID()
        repositoryPathLoadID = loadID
        isLoadingRepositoryPaths = true
        repositoryPathTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.repositoryPathLoadID == loadID {
                    self.repositoryPathLoadID = nil
                    self.repositoryPathTask = nil
                    self.isLoadingRepositoryPaths = false
                }
            }

            do {
                let items = try await self.client.repositoryPaths(at: root)
                try Task.checkCancellation()
                guard self.isCurrentRepository(root),
                      self.repositoryPathLoadID == loadID else {
                    return
                }
                self.repositoryPathItems = items
            } catch is CancellationError {
                // A newer picker load or repository switch superseded this load.
            } catch {
                guard self.isCurrentRepository(root),
                      self.repositoryPathLoadID == loadID else {
                    return
                }
                self.show(error)
            }
        }
    }

    func showCommitHashPicker() {
        guard repositoryURL != nil else { return }
        isShowingCommitHashPicker = true
    }

    func showBranchPicker() {
        guard repositoryURL != nil else { return }
        isShowingBranchPicker = true
    }

    func showNewBranchSheet(from start: GitReference? = nil, checkout: Bool = true) {
        guard repositoryURL != nil else { return }
        newBranchStart = start
        newBranchChecksOut = checkout
        isShowingNewBranchSheet = true
    }

    /// Resolves a hash without changing what the window shows, so the commit
    /// picker can say whether a hash exists before the user opens it.
    func lookUpCommit(hash: String) async throws -> GitCommit {
        guard let root = repositoryURL else {
            throw GitOperationError(
                command: "git rev-parse --verify \(hash)",
                message: "Open a repository before looking up a commit."
            )
        }
        return try await client.commit(at: root, matchingHash: hash)
    }

    /// Opens the commit a short or full hash points at. A commit that is
    /// already loaded keeps the current history in place; anything else — an
    /// older commit, or one no reference reaches — narrows the history to that
    /// commit and its ancestors.
    func openCommit(hash: String) {
        guard let root = repositoryURL else { return }
        guard let query = CommitHashQuery.normalized(hash) else {
            errorMessage = """
            Enter a commit hash of at least \(CommitHashQuery.minimumLength) \
            hexadecimal characters.
            """
            return
        }

        _ = startOperation("Opening commit \(query)") {
            let commit = try await self.client.commit(at: root, matchingHash: query)
            try Task.checkCancellation()
            guard self.isCurrentRepository(root) else { return }

            self.selectedStash = nil
            self.selectedSection = .history
            if let loaded = self.commits.first(where: { $0.hash == commit.hash }) {
                if !self.filteredCommits.contains(loaded) {
                    self.searchText = ""
                }
                self.showCommit(loaded)
            } else {
                self.searchText = ""
                self.selectedReference = nil
                self.historyScope = .commit(commit.hash)
                self.selectedCommit = commit
                try await self.reloadHistory(root: root, scope: self.historyScope)
            }
            self.commitReveal = CommitReveal(hash: commit.hash)
        }
    }

    /// Shows the repository `url` is in: the panel follows the shown
    /// session's folder. Nothing is reloaded when that is the repository
    /// shown already.
    func openRepository(_ url: URL) {
        _ = startOperation("Opening repository") {
            let root = try await self.client.repositoryRoot(from: url)
            try Task.checkCancellation()
            self.stopMonitoring()
            self.repositoryURL = root
            self.mainWorktreeURL = GitWorktree.mainWorktree(ofLinked: root) ?? root
            GitCommandLog.shared.registerRepository(root)
            self.prepareForRepositorySwitch()
            try await self.reload(root: root, historyScope: self.historyScope)
            try Task.checkCancellation()
            guard self.isCurrentRepository(root) else { return }
            if !self.changes.isEmpty {
                self.selectChanges()
            }
            self.startMonitoring(root: root)
        }
    }

    func refresh() {
        guard let root = repositoryURL else { return }
        _ = startOperation("Refreshing") {
            try await self.reload(root: root, historyScope: self.historyScope)
        }
    }

    func openZedEditor() {
        guard let root = repositoryURL else { return }
        Task {
            do {
                try await ZedLauncher().openRepository(at: root)
            } catch {
                self.show(error)
            }
        }
    }

    func openInFinder() {
        guard let root = repositoryURL else { return }
        NSWorkspace.shared.open(root)
    }

    /// Shows the changes. What the history shows stays as it is, for when
    /// the user comes back to it.
    func selectChanges() {
        cancelHistoryPagination(resetState: false)
        selectedSection = .changes
        if let change = changes.first {
            selectChange(change, staged: change.isStaged)
        }
    }

    /// Goes back to the history as it was left: the same branch and commit.
    func showHistory() {
        guard selectedSection != .history else { return }
        selectedSection = .history
        showCommit(selectedCommit)
    }

    func selectCommit(_ commit: GitCommit?) {
        selectedStash = nil
        showCommit(commit)
    }

    private func showCommit(_ commit: GitCommit?) {
        detailTask?.cancel()
        detailTask = nil
        selectedCommit = commit
        selectedChange = nil
        guard let root = repositoryURL, let commit else {
            diff = ""
            return
        }

        let usesCache = cachedCommitHash == commit.hash
        if usesCache, let cachedVerifiedCommit {
            replaceCommit(cachedVerifiedCommit)
            selectedCommit = cachedVerifiedCommit
        }
        diff = usesCache ? cachedCommitDetails ?? "" : ""
        guard !usesCache
                || cachedCommitDetails == nil
                || cachedVerifiedCommit == nil else {
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        detailTask = Task {
            do {
                async let detailsResult = client.commitDetails(at: root, hash: commit.hash)
                async let verifiedCommitResult = client.commit(
                    at: root,
                    revision: commit.hash
                )
                let (details, verifiedCommit) = try await (
                    detailsResult,
                    verifiedCommitResult
                )
                try Task.checkCancellation()
                guard generation == loadGeneration,
                      selectedCommit?.hash == verifiedCommit.hash else {
                    return
                }
                cachedCommitHash = verifiedCommit.hash
                cachedCommitDetails = details
                cachedVerifiedCommit = verifiedCommit
                diff = details
                replaceCommit(verifiedCommit)
                selectedCommit = verifiedCommit
            } catch is CancellationError {
                // A newer selection superseded this detail load.
            } catch {
                if generation == loadGeneration {
                    show(error)
                }
            }
        }
    }

    private func replaceCommit(_ commit: GitCommit) {
        if let index = commits.firstIndex(where: { $0.hash == commit.hash }) {
            commits[index] = commit
        } else if let index = olderMatches.firstIndex(where: { $0.hash == commit.hash }) {
            olderMatches[index] = commit
        }
    }

    /// Selects a single row, replacing any multi-selection: a plain click.
    func selectChange(_ change: WorkingChange?, staged: Bool) {
        changeSelection.select(change.map { ChangeEntryID(path: $0.path, staged: staged) })
        showPrimaryChange()
    }

    /// Updates the primary row through SwiftUI's native `List` selection.
    func selectChangeEntry(_ id: ChangeEntryID?) {
        guard let id else {
            clearChangeSelection()
            return
        }
        guard changeEntries.contains(where: { $0.id == id }) else { return }
        changeSelection.select(id)
        showPrimaryChange()
    }

    /// Adds or removes one row without disturbing the rest: a Command-click.
    func toggleSelection(of entry: ChangeEntry) {
        changeSelection.toggle(entry.id, in: changeOrder)
        showPrimaryChange()
    }

    /// Selects every row between the anchor and `entry`: a Shift-click.
    func extendSelection(to entry: ChangeEntry) {
        changeSelection.extend(to: entry.id, in: changeOrder)
        showPrimaryChange()
    }

    func clearChangeSelection() {
        changeSelection.clear()
        showPrimaryChange()
    }

    func isSelected(_ entry: ChangeEntry) -> Bool {
        changeSelection.contains(entry.id)
    }

    /// Loads the diff for the row that drives the detail pane. Clicks skip the
    /// reload while the same row stays primary; a refresh always reloads,
    /// because the file may have changed underneath an unchanged row.
    private func showPrimaryChange(alwaysReloadDiff: Bool = false) {
        let entry = changeSelection.primary.flatMap { id in
            changeEntries.first { $0.id == id }
        }
        guard let entry else {
            if selectedChange != nil {
                showChange(nil, staged: false)
            }
            return
        }
        guard alwaysReloadDiff
                || entry.change != selectedChange
                || entry.staged != selectedChangeIsStaged else {
            return
        }
        showChange(entry.change, staged: entry.staged)
    }

    private func showChange(_ change: WorkingChange?, staged: Bool) {
        let previousEntryID = selectedChange.map {
            ChangeEntryID(path: $0.path, staged: selectedChangeIsStaged)
        }
        let nextEntryID = change.map {
            ChangeEntryID(path: $0.path, staged: staged)
        }
        let isReloadingCurrentEntry = previousEntryID == nextEntryID

        detailTask?.cancel()
        detailTask = nil
        selectedStash = nil
        selectedChange = change
        selectedChangeIsStaged = staged
        conflictDocument = nil
        selectedCommit = nil
        guard let root = repositoryURL, let change else {
            diff = ""
            return
        }
        if !isReloadingCurrentEntry {
            diff = ""
        }
        loadGeneration += 1
        let generation = loadGeneration
        detailTask = Task {
            do {
                async let patchTask = client.diff(
                    at: root,
                    change: change,
                    staged: staged
                )
                async let conflictTask = client.conflictDocument(
                    at: root,
                    change: change
                )
                let (patch, loadedConflictDocument) = try await (
                    patchTask,
                    conflictTask
                )
                try Task.checkCancellation()
                if generation == loadGeneration {
                    diff = patch
                    conflictDocument = loadedConflictDocument
                }
            } catch is CancellationError {
                // A newer selection superseded this diff load.
            } catch {
                if generation == loadGeneration {
                    show(error)
                }
            }
        }
    }

    /// Shows the reference's commits; nil shows all branches.
    func selectReference(_ reference: GitReference?) {
        showHistory(of: reference, scope: CommitHistoryScope(revision: reference?.fullName))
    }

    /// Shows the checked-out branch's commits, and goes on following HEAD.
    func showCurrentBranch() {
        showHistory(of: nil, scope: .currentBranch)
    }

    /// The history follows the checked-out branch.
    var showsCurrentBranch: Bool {
        historyScope == .currentBranch && selectedStash == nil
    }

    /// The history shows every branch.
    var showsAllBranches: Bool {
        historyScope == .all && selectedStash == nil
    }

    private func showHistory(of reference: GitReference?, scope: CommitHistoryScope) {
        guard let root = repositoryURL else { return }
        guard !isLoading else {
            queuedPick = { [weak self] in self?.showHistory(of: reference, scope: scope) }
            return
        }
        cancelHistoryPagination()
        let label = reference?.name ?? (scope == .all ? "all branches" : "the current branch")
        _ = startOperation("Loading \(label)") {
            self.selectedStash = nil
            self.selectedReference = reference
            self.selectedSection = .history
            self.historyScope = scope
            try await self.reloadHistory(root: root, scope: self.historyScope)
        }
    }

    func selectLostAndDanglingCommits() {
        guard let root = repositoryURL else { return }
        guard !isLoading else {
            queuedPick = { [weak self] in self?.selectLostAndDanglingCommits() }
            return
        }
        cancelHistoryPagination()
        _ = startOperation("Loading unreachable commits") {
            self.selectedStash = nil
            self.selectedReference = nil
            self.selectedSection = .history
            self.historyScope = .lostAndDangling
            try await self.reloadHistory(root: root, scope: self.historyScope)
        }
    }

    /// The reference a file or directory history is limited to: the selected
    /// reference when the sidebar has one, otherwise the checked-out branch.
    var pathHistoryReferenceName: String {
        if let selectedReference {
            return selectedReference.name
        }
        return branch.isEmpty ? "HEAD" : branch
    }

    private var pathHistoryRevision: String {
        selectedReference?.fullName ?? "HEAD"
    }

    /// Shows the commits that touch `proposedPath`. The selected reference
    /// stays selected: a path history narrows the branch already on screen
    /// rather than searching every ref in the repository.
    func selectPathHistory(_ proposedPath: String) {
        guard let root = repositoryURL,
              let path = RepositoryPathSelection.normalizedSelection(proposedPath) else {
            return
        }
        cancelHistoryPagination()
        let revision = pathHistoryRevision
        _ = startOperation("Loading history for \(path)") {
            self.selectedStash = nil
            self.selectedSection = .history
            self.historyScope = .path(path, revision: revision)
            try await self.reloadHistory(root: root, scope: self.historyScope)
        }
    }

    func selectStash(_ stash: GitStash) {
        guard let root = repositoryURL else { return }
        guard !isLoading else {
            queuedPick = { [weak self] in self?.selectStash(stash) }
            return
        }
        cancelHistoryPagination()
        _ = startOperation("Loading \(stash.displayName)") {
            self.selectedStash = stash
            self.selectedReference = nil
            self.selectedSection = .history
            let commit = try await self.client.commit(
                at: root,
                revision: stash.selector
            )
            guard self.selectedStash?.id == stash.id else { return }
            self.showCommit(commit)
        }
    }

    func stage(_ change: WorkingChange) {
        stage([ChangeEntry(change, staged: false)])
    }

    func unstage(_ change: WorkingChange) {
        unstage([ChangeEntry(change, staged: true)])
    }

    /// Stages every row of `entries` that sits on the working-tree side; rows
    /// already in the index are ignored, so a selection spanning both sections
    /// still does the expected thing.
    func stage(_ entries: [ChangeEntry]) {
        let paths = entries.unstagedSide.paths
        guard !paths.isEmpty else { return }
        mutate(
            Self.operationLabel("Staging", paths: paths),
            reloadScope: .workingTree
        ) { root in
            try await self.client.stage(at: root, paths: paths)
        }
    }

    /// Unstages every row of `entries` that sits on the staged side.
    func unstage(_ entries: [ChangeEntry]) {
        let paths = entries.stagedSide.paths
        guard !paths.isEmpty else { return }
        mutate(
            Self.operationLabel("Unstaging", paths: paths),
            reloadScope: .workingTree
        ) { root in
            try await self.client.unstage(at: root, paths: paths)
        }
    }

    func markConflictsResolved(_ entries: [ChangeEntry]) {
        let conflicts = entries.conflicted.map(\.change)
        guard !conflicts.isEmpty else { return }
        mutate(
            Self.operationLabel("Marking resolved", paths: conflicts.map(\.path)),
            reloadScope: .workingTree
        ) { root in
            try await self.client.markConflictsResolved(at: root, conflicts: conflicts)
        }
    }

    func resolveConflicts(
        _ entries: [ChangeEntry],
        using side: ConflictResolutionSide
    ) {
        let conflicts = entries.conflicted.map(\.change)
        guard !conflicts.isEmpty else { return }
        mutate(
            Self.operationLabel("Resolving with \(side.title)", paths: conflicts.map(\.path)),
            reloadScope: .workingTree
        ) { root in
            try await self.client.resolveConflicts(
                at: root,
                conflicts: conflicts,
                using: side
            )
        }
    }

    func resolveConflictBlock(
        _ block: ConflictBlock,
        using side: ConflictResolutionSide
    ) {
        guard let change = selectedChange,
              change.isConflicted,
              let document = conflictDocument,
              document.conflicts.contains(where: { $0.id == block.id }) else {
            return
        }
        mutate(
            "Using \(side.title) for one conflict in \(change.path)",
            reloadScope: .workingTree
        ) { root in
            try await self.client.resolveConflictBlock(
                at: root,
                change: change,
                document: document,
                blockID: block.id,
                using: side
            )
        }
    }

    func stage(_ patch: String, in change: WorkingChange) {
        mutate(
            "Staging selected lines in \(change.path)",
            reloadScope: .workingTree
        ) { root in
            try await self.client.stage(at: root, patch: patch)
        }
    }

    func unstage(_ patch: String, in change: WorkingChange) {
        mutate(
            "Unstaging selected lines in \(change.path)",
            reloadScope: .workingTree
        ) { root in
            try await self.client.unstage(at: root, patch: patch)
        }
    }

    func discard(_ patch: String, in change: WorkingChange) {
        mutate(
            "Discarding selected lines in \(change.path)",
            reloadScope: .workingTree
        ) { root in
            try await self.client.discard(at: root, patch: patch)
        }
    }

    func discard(_ change: WorkingChange) {
        discard([ChangeEntry(change, staged: false)])
    }

    /// Discards the working-tree changes of every row of `entries` on the
    /// unstaged side. Staged rows are left alone: the index is never rewritten
    /// by a discard.
    func discard(_ entries: [ChangeEntry]) {
        let targets = entries.unstagedSide.map(\.change)
        guard !targets.isEmpty else { return }
        mutate(
            Self.operationLabel("Discarding changes in", paths: targets.map(\.path)),
            reloadScope: .workingTree
        ) { root in
            try await self.client.discard(at: root, changes: targets)
        }
    }

    func stageAll() {
        mutate("Staging all changes", reloadScope: .workingTree) { root in
            try await self.client.stage(at: root, paths: self.unstagedChanges.map(\.path))
        }
    }

    func unstageAll() {
        mutate("Unstaging all changes", reloadScope: .workingTree) { root in
            try await self.client.unstage(at: root, paths: self.stagedChanges.map(\.path))
        }
    }

    private static func operationLabel(_ verb: String, paths: [String]) -> String {
        paths.count == 1 ? "\(verb) \(paths[0])" : "\(verb) \(paths.count) files"
    }

    func createCommit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            errorMessage = "Enter a commit message first."
            return
        }
        let shouldAmend = amend
        let shouldSign = signCommit
        let operation: String
        if shouldAmend {
            operation = shouldSign ? "Amending with GPG signature" : "Amending commit"
        } else {
            operation = shouldSign ? "Creating GPG-signed commit" : "Creating commit"
        }

        mutate(operation) { root in
            try await self.client.commit(
                at: root,
                message: message,
                amend: shouldAmend,
                signWithGPG: shouldSign
            )
            self.commitMessage = ""
            self.amend = false
            self.selectedSection = .history
            // The history shows next, with the new commit in it: only a
            // filter on the current branch has that commit.
            if self.showsCurrentBranch
                || self.selectedReference?.isCurrent == true && self.historyScope.revision != nil {
                return
            }
            self.selectedStash = nil
            self.selectedReference = nil
            self.historyScope = .currentBranch
        }
    }

    func fetch() {
        mutate("Fetching all remotes") { root in
            try await self.client.fetch(at: root)
        }
    }

    func pull() {
        mutate("Pulling \(upstream ?? "upstream")") { root in
            try await self.client.pull(at: root)
        }
    }

    func push() {
        guard let plan = pendingPushPlan else {
            errorMessage = "Choose a local branch to push first."
            return
        }
        pendingPushPlan = nil
        mutate("Pushing \(plan.branchName)") { root in
            try await self.client.push(
                at: root,
                target: plan.target,
                sourceRef: plan.sourceRef
            )
        }
    }

    func requestPushConfirmation() {
        guard !isLoading else {
            showBusyError()
            return
        }
        guard let pushTarget else {
            if BranchDisplay(branch).isDetached {
                errorMessage = "Create or check out a branch before pushing a detached HEAD."
            } else {
                errorMessage = """
                This branch has no safe push target. Add a remote or repair its \
                upstream configuration.
                """
            }
            return
        }
        pendingPushPlan = GitPushPlan(
            branchName: branch,
            sourceRef: "HEAD",
            target: pushTarget,
            ahead: ahead
        )
        isConfirmingPush = true
    }

    func requestPushConfirmation(for reference: GitReference) {
        guard reference.kind == .localBranch else { return }
        guard let root = repositoryURL else { return }
        pendingPushPlan = nil

        let preparation = startOperation("Preparing to push \(reference.name)") {
            let target = try await self.client.pushTarget(at: root, for: reference)
            guard let target else {
                throw GitOperationError(
                    command: "git push",
                    message: """
                    \(reference.name) has no safe push target. Add a remote or repair its \
                    upstream configuration.
                    """
                )
            }
            try Task.checkCancellation()
            guard self.isCurrentRepository(root) else { return }
            self.pendingPushPlan = GitPushPlan(
                branchName: reference.name,
                sourceRef: reference.fullName,
                target: target,
                ahead: reference.isCurrent ? self.ahead : nil
            )
        }
        guard let preparation else { return }

        Task {
            await preparation.value
            guard self.isCurrentRepository(root),
                  self.pendingPushPlan?.sourceRef == reference.fullName else {
                return
            }
            self.isConfirmingPush = true
        }
    }

    func cancelPushConfirmation() {
        pendingPushPlan = nil
    }

    /// Switches to `reference`. With agents working in the worktree,
    /// `pendingCheckout` asks the user first. Changes git can carry along
    /// come along; if it would have to overwrite them, it asks as well.
    func checkout(_ reference: GitReference) {
        guard !reference.isCurrent else { return }
        if let root = repositoryURL, let agents = agentsWorking?(root), !agents.isEmpty {
            pendingCheckout = PendingCheckout(reference: reference, reason: .agentsWorking(agents))
            return
        }
        performCheckout(reference)
    }

    /// The user wants the switch even though agents work in the worktree.
    func checkoutDespiteAgents() {
        guard let pending = pendingCheckout, case .agentsWorking = pending.reason, !isLoading else { return }
        pendingCheckout = nil
        performCheckout(pending.reference, newBranch: pending.newBranch)
    }

    private func performCheckout(_ reference: GitReference, newBranch: String? = nil) {
        mutate("Switching to \(newBranch ?? reference.name)") { root in
            do {
                try await self.switchTo(reference, newBranch: newBranch, at: root)
            } catch let error as CheckoutOverwriteError {
                self.pendingCheckout = PendingCheckout(
                    reference: reference,
                    newBranch: newBranch,
                    reason: .overwrites(error.files)
                )
                return
            }
            self.selectedReference = nil
            self.historyScope = .currentBranch
        }
    }

    private func switchTo(_ reference: GitReference, newBranch: String?, at root: URL) async throws {
        if let newBranch {
            try await client.createBranch(at: root, name: newBranch, from: reference)
        } else {
            try await client.checkout(at: root, reference: reference)
        }
    }

    /// Puts all changes in a stash, untracked files too, then does the
    /// switch git refused. The stash stays, to apply wherever the user wants.
    func stashAndCheckout() {
        guard let pending = pendingCheckout, case .overwrites = pending.reason, !isLoading else { return }
        pendingCheckout = nil
        let message = "Before switching to \(pending.destination)"
        mutate("Stashing and switching to \(pending.destination)") { root in
            try await self.client.stash(at: root, message: message, scope: .all)
            do {
                try await self.switchTo(pending.reference, newBranch: pending.newBranch, at: root)
            } catch {
                throw GitOperationError(
                    command: "git switch \(pending.destination)",
                    message: "\(error.localizedDescription)\n\nYour changes are in the stash “\(message)”."
                )
            }
            self.selectedReference = nil
            self.historyScope = .currentBranch
        }
    }

    func cancelCheckout() {
        pendingCheckout = nil
    }

    /// Makes a branch at `start`, or at HEAD without one, and switches to it
    /// if `checkout`. A switch that changes files asks first, as `checkout`
    /// does; if the user cancels, the branch isn't made.
    func createBranch(named name: String, from start: GitReference? = nil, checkout: Bool = true) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let head = references.first(where: \.isCurrent)
        guard checkout, let start, start.target != head?.target else {
            mutate("Creating \(cleanName)") { root in
                try await self.client.createBranch(at: root, name: cleanName, from: start, checkout: checkout)
                if checkout {
                    self.selectedReference = nil
                    self.historyScope = .currentBranch
                }
            }
            return
        }
        if let root = repositoryURL, let agents = agentsWorking?(root), !agents.isEmpty {
            pendingCheckout = PendingCheckout(reference: start, newBranch: cleanName, reason: .agentsWorking(agents))
            return
        }
        performCheckout(start, newBranch: cleanName)
    }

    func rename(_ reference: GitReference, to name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName != reference.name else { return }
        mutate("Renaming \(reference.name) to \(cleanName)") { root in
            try await self.client.rename(at: root, reference: reference, to: cleanName)
            self.followRename(of: reference, to: cleanName)
        }
    }

    /// Asks for confirmation before moving the local branch `name` under
    /// `prefix`. Returns `false` when the drop does nothing: the payload is not
    /// a local branch, or the branch already sits under that prefix.
    @discardableResult
    func requestBranchMove(named name: String, toPrefix prefix: String) -> Bool {
        guard !isLoading,
              let reference = references.first(where: {
                  $0.kind == .localBranch && $0.name == name
              }),
              let move = GitBranchMove(reference: reference, toPrefix: prefix) else {
            return false
        }
        if let conflict = move.conflictingBranch(in: references) {
            errorMessage = conflict.name == move.newName
                ? "Cannot move \(reference.name): a branch named \(move.newName) already exists."
                : "Cannot move \(reference.name): \(move.newName) is already a folder of branches, such as \(conflict.name)."
            return false
        }
        pendingBranchMove = move
        return true
    }

    func confirmBranchMove() {
        guard let move = pendingBranchMove else { return }
        pendingBranchMove = nil
        rename(move.reference, to: move.newName)
    }

    func cancelBranchMove() {
        pendingBranchMove = nil
    }

    /// Keeps a renamed branch selected under its new name. Git moves the ref
    /// itself, so the history scope has to follow it or the reload that comes
    /// next asks for a ref that no longer exists.
    private func followRename(of reference: GitReference, to name: String) {
        guard selectedReference == reference else { return }
        selectedReference = GitReference(
            name: name,
            fullName: "refs/heads/\(name)",
            kind: reference.kind,
            target: reference.target,
            isCurrent: reference.isCurrent,
            upstream: reference.upstream
        )
        historyScope = CommitHistoryScope(revision: selectedReference?.fullName)
    }

    /// The remote-tracking branch that can be deleted along with `reference`.
    /// Returns `nil` when the branch has no upstream, or when its remote-tracking
    /// ref is already gone locally, in which case the remote branch is either
    /// gone too or unknown to this repository until the next fetch.
    func deletableRemoteBranch(for reference: GitReference) -> GitUpstream? {
        guard reference.kind == .localBranch,
              let upstream = reference.upstream else {
            return nil
        }
        let isTracked = references.contains {
            $0.kind == .remoteBranch && $0.fullName == upstream.fullName
        }
        return isTracked ? upstream : nil
    }

    func delete(_ reference: GitReference, includingRemote: Bool = false) {
        let kind = reference.kind == .tag ? "tag" : "branch"
        let upstream = includingRemote ? deletableRemoteBranch(for: reference) : nil
        let label = upstream.map { "Deleting branch \(reference.name) and \($0.shortName)" }
            ?? "Deleting \(kind) \(reference.name)"
        mutate(label) { root in
            do {
                try await self.client.delete(at: root, reference: reference)
            } catch let error as UnmergedBranchDeletionError {
                guard error.branch == reference.name else {
                    throw error
                }
                self.branchPendingForceDelete = reference
                return
            }
            try await self.deleteRemoteBranch(upstream, at: root, after: reference)
            self.clearSelection(of: reference)
        }
    }

    func forceDelete(_ reference: GitReference, includingRemote: Bool = false) {
        guard branchPendingForceDelete == reference, !isLoading else { return }
        branchPendingForceDelete = nil
        let upstream = includingRemote ? deletableRemoteBranch(for: reference) : nil
        let label = upstream.map { "Force deleting branch \(reference.name) and \($0.shortName)" }
            ?? "Force deleting branch \(reference.name)"
        mutate(label) { root in
            try await self.client.forceDelete(at: root, reference: reference)
            try await self.deleteRemoteBranch(upstream, at: root, after: reference)
            self.clearSelection(of: reference)
        }
    }

    func cancelForceDelete() {
        branchPendingForceDelete = nil
    }

    /// Local branches whose upstream is `reference`. Deleting the remote branch
    /// leaves their tracking configuration pointing at a ref that is gone.
    func localBranchesTracking(_ reference: GitReference) -> [GitReference] {
        guard reference.kind == .remoteBranch else { return [] }
        return references.filter {
            $0.kind == .localBranch && $0.upstream?.fullName == reference.fullName
        }
    }

    /// Deletes a branch from its remote directly, without requiring a local
    /// branch that tracks it. Git removes the remote-tracking ref on success.
    func deleteRemoteBranch(_ reference: GitReference) {
        guard let upstream = reference.remoteBranchTarget else {
            errorMessage = """
            \(reference.name) does not name a branch on a remote, so GitFork \
            cannot delete it.
            """
            return
        }
        mutate("Deleting \(upstream.shortName) from \(upstream.remote)") { root in
            try await self.client.deleteRemoteBranch(at: root, upstream: upstream)
            self.clearSelection(of: reference)
        }
    }

    /// Deletes the remote branch after its local branch is gone. A failure here
    /// must name the local deletion that already succeeded, because the two
    /// halves of the operation cannot be rolled back together.
    private func deleteRemoteBranch(
        _ upstream: GitUpstream?,
        at root: URL,
        after reference: GitReference
    ) async throws {
        guard let upstream else { return }
        do {
            try await client.deleteRemoteBranch(at: root, upstream: upstream)
        } catch let error as GitOperationError {
            throw GitOperationError(
                command: error.command,
                message: """
                Deleted the local branch \(reference.name), but deleting \
                \(upstream.shortName) failed. \(error.message)
                """
            )
        }
    }

    private func clearSelection(of reference: GitReference) {
        guard selectedReference == reference else { return }
        selectedReference = nil
        historyScope = .currentBranch
    }

    func delete(_ worktree: GitWorktree) {
        mutate("Deleting worktree \(worktree.displayName)") { root in
            do {
                try await self.client.removeWorktree(at: root, worktree: worktree)
            } catch let error as DirtyWorktreeRemovalError {
                guard error.path == worktree.path else {
                    throw error
                }
                self.worktreePendingForceDelete = worktree
            }
        }
    }

    func forceDelete(_ worktree: GitWorktree) {
        guard worktreePendingForceDelete == worktree, !isLoading else { return }
        worktreePendingForceDelete = nil
        mutate("Force deleting worktree \(worktree.displayName)") { root in
            try await self.client.removeWorktree(
                at: root,
                worktree: worktree,
                force: true
            )
        }
    }

    func cancelWorktreeForceDelete() {
        worktreePendingForceDelete = nil
    }

    func pruneStaleWorktrees() {
        mutate("Pruning stale worktrees") { root in
            try await self.client.pruneStaleWorktrees(at: root)
        }
    }

    func stash(message: String, scope: StashScope = .all) {
        mutate("Stashing \(scope.title.lowercased())") { root in
            let resolved = message.trimmingCharacters(in: .whitespacesAndNewlines)
            try await self.client.stash(
                at: root,
                message: resolved.isEmpty ? "agentz stash" : resolved,
                scope: scope
            )
        }
    }

    func apply(_ stash: GitStash) {
        mutate("Applying \(stash.displayName)") { root in
            try await self.client.applyStash(at: root, stash: stash)
        }
    }

    func drop(_ stash: GitStash) {
        mutate("Dropping \(stash.displayName)") { root in
            try await self.client.dropStash(at: root, stash: stash)
            if self.selectedStash == stash {
                self.selectedStash = nil
            }
        }
    }

    private enum ReloadScope {
        case full
        case workingTree
    }

    private func mutate(
        _ label: String,
        reloadScope: ReloadScope = .full,
        action: @escaping @MainActor (URL) async throws -> Void
    ) {
        guard let root = repositoryURL else { return }
        _ = startOperation(label) {
            do {
                try await action(root)
            } catch {
                try? await self.reload(
                    root: root,
                    historyScope: self.historyScope,
                    scope: reloadScope
                )
                throw error
            }
            try await self.reload(
                root: root,
                historyScope: self.historyScope,
                scope: reloadScope
            )
        }
    }

    /// Checks the repository again whenever files in the worktree or its git
    /// folder change, at most once a second, and every `monitorInterval`
    /// otherwise. Git's objects and logs are left out: they change along with
    /// the refs and the index.
    private func startMonitoring(
        root: URL,
        refreshImmediately: Bool = false
    ) {
        stopMonitoring(resetState: false)
        guard isMonitoringActive else { return }
        let monitorInterval = monitorInterval
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gitDirectory = GitWorktree.linkedGitDirectory(at: root) ?? root.appendingPathComponent(".git")
        let paths = [root.path, gitDirectory.path].map { realPath($0) ?? $0 }
        let git = paths[1]
        watcher = FolderWatcher(
            pathStarts(git, with: paths[0]) ? [paths[0]] : paths,
            ignoring: [git + "/objects", git + "/logs"]
        ) {
            changed.yield()
        }
        monitorTask = Task { [weak self] in
            // The checks run Git; keep them out of the command log so the
            // commands the user caused stay visible.
            await GitCommandLogScope.$isSuppressed.withValue(true) {
                let fallback = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: monitorInterval)
                        changed.yield()
                    }
                }
                defer { fallback.cancel() }
                if refreshImmediately {
                    await self?.refreshIfRepositoryChanged(root: root)
                }
                for await _ in changes {
                    guard let self, !Task.isCancelled else { return }
                    await self.refreshIfRepositoryChanged(root: root)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func stopMonitoring(resetState: Bool = true) {
        watcher = nil
        monitorTask?.cancel()
        monitorTask = nil
        if resetState {
            monitoredState = nil
        }
    }

    func setMonitoringActive(_ isActive: Bool) {
        guard isMonitoringActive != isActive else { return }
        isMonitoringActive = isActive
        guard let root = repositoryURL else { return }
        if isActive {
            startMonitoring(root: root, refreshImmediately: true)
        } else {
            stopMonitoring(resetState: false)
        }
    }

    private func refreshIfRepositoryChanged(root: URL) async {
        guard repositoryURL?.standardizedFileURL == root.standardizedFileURL,
              !isLoading else {
            return
        }

        do {
            let state = try await client.stateToken(at: root)
            guard !Task.isCancelled,
                  repositoryURL?.standardizedFileURL == root.standardizedFileURL,
                  !isLoading,
                  monitoredState != state else {
                return
            }

            isLoading = true
            defer { isLoading = false }
            if let previous = monitoredState, previous.sameHistory(as: state) {
                let previousOrder = changeOrder
                changes = GitParser.parseStatus(Data(state.status.utf8))
                monitoredState = state
                if selectedSection == .changes { reconcileChangeSelection(previousOrder: previousOrder) }
            } else {
                try await reload(root: root, historyScope: historyScope)
            }
        } catch {
            // External Git operations can leave short-lived lock or ref states.
            // The next polling pass retries without interrupting the user.
        }
    }

    private func reload(
        root: URL,
        historyScope: CommitHistoryScope = .all,
        scope: ReloadScope = .full
    ) async throws {
        switch scope {
        case .full:
            try await reloadFull(root: root, historyScope: historyScope)
        case .workingTree:
            try await reloadWorkingTree(root: root)
        }
    }

    private func reloadFull(
        root: URL,
        historyScope: CommitHistoryScope
    ) async throws {
        cancelHistoryPagination(resetState: false)
        let previousChangeOrder = changeOrder
        let depth = max(historyPageSize, commits.count)
        let previousSelection = selectedCommit?.hash
        let load: RepositoryLoad
        do {
            load = try await client.snapshotAndStateToken(
                at: root,
                historyScope: historyScope,
                historyLimit: depth
            )
        } catch {
            // The filter's branch may be gone, deleted in a terminal or by a
            // fetch. It must not stop the changes from being read.
            guard !(error is CancellationError),
                  historyScope != .currentBranch,
                  let revision = historyScope.revision,
                  (try? await client.commit(at: root, revision: revision)) == nil else {
                throw error
            }
            try Task.checkCancellation()
            guard isCurrentRepository(root) else { return }
            let fallback = CommitHistoryScope.currentBranch
            self.selectedReference = nil
            self.historyScope = fallback
            load = try await client.snapshotAndStateToken(
                at: root,
                historyScope: fallback,
                historyLimit: depth
            )
        }
        try Task.checkCancellation()
        guard isCurrentRepository(root) else { return }
        let snapshot = load.snapshot
        monitoredState = load.stateToken
        branch = snapshot.branch
        upstream = snapshot.upstream
        pushTarget = snapshot.pushTarget
        ahead = snapshot.ahead
        behind = snapshot.behind
        changes = snapshot.changes
        references = snapshot.references
        stashes = snapshot.stashes
        worktrees = snapshot.worktrees
        operation = snapshot.operation
        var history = snapshot.commits
        // Incoming commits can push even a previously loaded selection past the last page.
        if let hash = previousSelection, history.count == depth,
           !history.contains(where: { $0.hash == hash }),
           commits.contains(where: { $0.hash == hash }) || olderMatches.contains(where: { $0.hash == hash }) {
            var count = depth
            var offset = depth
            var seen = Set(history.map(\.hash))
            while count >= historyPageSize && !seen.contains(hash) {
                let page = try await client.history(at: root, scope: self.historyScope, offset: offset, limit: historyPageSize)
                try Task.checkCancellation()
                guard isCurrentRepository(root) else { return }
                history.append(contentsOf: page.filter { seen.insert($0.hash).inserted })
                count = page.count
                offset += count
            }
            replaceHistory(history, nextOffset: offset, more: count >= historyPageSize)
        } else {
            replaceHistory(history, more: history.count == depth)
        }

        // The selected reference is a value, so it goes stale whenever its
        // target, upstream, or name changes. Re-bind it to the reloaded ref of
        // the same name so the sidebar keeps showing the selection.
        if let selectedReference,
           let replacement = references.first(where: { $0.fullName == selectedReference.fullName }) {
            self.selectedReference = replacement
        }

        if let selectedStash,
           let replacement = stashes.first(where: { $0.id == selectedStash.id }) {
            self.selectedStash = replacement
            self.selectedCommit = try await client.commit(
                at: root,
                revision: replacement.selector
            )
        } else {
            selectedStash = nil
            if let selectedCommit,
               let replacement = commits.first(where: { $0.hash == selectedCommit.hash }) {
                self.selectedCommit = replacement
            } else {
                selectedCommit = commits.first
            }
        }

        if selectedSection == .history {
            showCommit(selectedCommit)
        } else {
            reconcileChangeSelection(previousOrder: previousChangeOrder)
        }
    }

    private func reloadWorkingTree(root: URL) async throws {
        let previousChangeOrder = changeOrder
        let snapshot = try await client.workingTreeSnapshot(at: root)
        try Task.checkCancellation()
        guard isCurrentRepository(root) else { return }
        changes = snapshot.changes
        if let monitoredState {
            self.monitoredState = monitoredState.replacingWorkingTree(
                with: snapshot
            )
        }
        guard selectedSection == .changes else { return }
        reconcileChangeSelection(previousOrder: previousChangeOrder)
    }

    private func reloadHistory(
        root: URL,
        scope: CommitHistoryScope
    ) async throws {
        cancelHistoryPagination()
        let loadedCommits = try await client.history(
            at: root,
            scope: scope,
            limit: historyPageSize
        )
        try Task.checkCancellation()
        guard isCurrentRepository(root) else { return }
        replaceHistory(loadedCommits)
        if let selectedCommit,
           let replacement = commits.first(where: { $0.hash == selectedCommit.hash }) {
            self.selectedCommit = replacement
        } else {
            selectedCommit = commits.first
        }
        showCommit(selectedCommit)
    }

    func loadMoreHistory() {
        guard selectedSection == .history,
              let root = repositoryURL,
              canLoadMoreHistory,
              !isLoading,
              !isLoadingMoreHistory else {
            return
        }

        let scope = historyScope
        let offset = historyNextOffset
        let paginationID = UUID()
        historyPaginationID = paginationID
        isLoadingMoreHistory = true
        historyPaginationTask = Task { [weak self] in
            guard let self else { return }
            await self.loadHistoryPage(
                root: root,
                scope: scope,
                offset: offset,
                paginationID: paginationID
            )
        }
    }

    private func loadHistoryPage(
        root: URL,
        scope: CommitHistoryScope,
        offset: Int,
        paginationID: UUID
    ) async {
        defer {
            if historyPaginationID == paginationID {
                historyPaginationID = nil
                historyPaginationTask = nil
                isLoadingMoreHistory = false
            }
        }

        do {
            let page = try await client.history(
                at: root,
                scope: scope,
                offset: offset,
                limit: historyPageSize
            )
            try Task.checkCancellation()
            guard isCurrentRepository(root),
                  historyScope == scope,
                  historyNextOffset == offset else {
                return
            }

            historyNextOffset += page.count
            let existingHashes = Set(commits.map(\.hash))
            commits.append(contentsOf: page.filter { !existingHashes.contains($0.hash) })
            canLoadMoreHistory = page.count == historyPageSize
        } catch is CancellationError {
            // A scope change or full refresh superseded this page.
        } catch {
            guard isCurrentRepository(root), historyScope == scope else { return }
            show(error)
        }
    }

    private func replaceHistory(_ loadedCommits: [GitCommit], nextOffset: Int? = nil, more: Bool? = nil) {
        commits = loadedCommits
        historyNextOffset = nextOffset ?? loadedCommits.count
        canLoadMoreHistory = more ?? (loadedCommits.count == historyPageSize)
        searchHistory()
    }

    private func cancelHistoryPagination(resetState: Bool = true) {
        historyPaginationTask?.cancel()
        historyPaginationTask = nil
        historyPaginationID = nil
        isLoadingMoreHistory = false
        if resetState {
            canLoadMoreHistory = false
            historyNextOffset = 0
        }
    }

    /// Carries the change selection across a refresh while keeping the primary
    /// row in its original section for as long as that section has rows.
    private func reconcileChangeSelection(previousOrder: [ChangeEntryID]) {
        changeSelection.reconcile(
            previousOrder: previousOrder,
            order: changeOrder
        ) { id in
            guard let change = self.changes.first(where: { $0.path == id.path }) else {
                return nil
            }
            if !id.staged && change.isConflicted {
                return id
            }
            if id.staged ? change.isStaged : change.isUnstaged {
                return id
            }
            if change.isStaged {
                return ChangeEntryID(path: id.path, staged: true)
            }
            if change.isUnstaged {
                return ChangeEntryID(path: id.path, staged: false)
            }
            return nil
        }
        guard changeSelection.primary != nil || selectedChange != nil else { return }
        showPrimaryChange(alwaysReloadDiff: true)
    }

    @discardableResult
    private func startOperation(
        _ label: String,
        operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never>? {
        guard activeOperationID == nil, !isLoading else {
            showBusyError()
            return nil
        }

        let operationID = UUID()
        activeOperationID = operationID
        isLoading = true
        operationLabel = label
        return Task {
            await self.perform(operationID: operationID, operation: operation)
        }
    }

    private func perform(
        operationID: UUID,
        operation: @escaping @MainActor () async throws -> Void
    ) async {
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
                isLoading = false
                operationLabel = nil
                let pick = queuedPick
                queuedPick = nil
                pick?()
            }
        }
        do {
            try await operation()
        } catch is CancellationError {
            // A newer repository switch superseded this operation.
        } catch {
            show(error)
        }
    }

    private func showBusyError() {
        let currentOperation = operationLabel ?? "the current repository operation"
        errorMessage = "Wait for \(currentOperation) to finish."
    }

    private func prepareForRepositorySwitch() {
        historySearchTask?.cancel()
        olderMatches = []
        searchingHistory = false
        cancelHistoryPagination()
        repositoryPathTask?.cancel()
        repositoryPathTask = nil
        repositoryPathLoadID = nil
        repositoryPathItems = []
        isLoadingRepositoryPaths = false
        isShowingBranchPicker = false
        queuedPick = nil
        isShowingPathHistoryPicker = false
        isShowingCommitHashPicker = false
        commitReveal = nil
        detailTask?.cancel()
        detailTask = nil
        loadGeneration += 1
        branch = ""
        upstream = nil
        pushTarget = nil
        ahead = 0
        behind = 0
        changes = []
        references = []
        stashes = []
        worktrees = []
        commits = []
        diff = ""
        conflictDocument = nil
        selectedReference = nil
        selectedStash = nil
        historyScope = .currentBranch
        selectedCommit = nil
        selectedChange = nil
        changeSelection.clear()
        selectedSection = .history
        commitMessage = ""
        amend = false
        branchPendingForceDelete = nil
        pendingCheckout = nil
        worktreePendingForceDelete = nil
        pendingPushPlan = nil
        isConfirmingPush = false
        pendingBranchMove = nil
        operation = nil
        confirmation = nil
        rebasePlan = nil
        rewordRequest = nil
        cachedCommitHash = nil
        cachedCommitDetails = nil
        cachedVerifiedCommit = nil
    }

    private func isCurrentRepository(_ root: URL) -> Bool {
        repositoryURL?.standardizedFileURL == root.standardizedFileURL
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}


/// An action that waits for the user to agree.
struct GitConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String
    let isDestructive: Bool
    let action: @MainActor () -> Void
}

/// A commit, and its whole message, for the sheet that edits it.
struct RewordRequest: Identifiable {
    let commit: GitCommit
    let message: String

    var id: String { commit.hash }
}

// MARK: - Commit and branch actions

extension RepositoryStore {
    /// The current branch's name, or HEAD when it is detached.
    var headName: String {
        references.first(where: \.isCurrent)?.name ?? "HEAD"
    }

    /// The hash of HEAD's commit, when it is loaded.
    var headHash: String? {
        if let branch = references.first(where: \.isCurrent) {
            return branch.target
        }
        return commits.first { $0.decorations.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") } }?.hash
    }

    /// Whether the commit is in HEAD's history, from the loaded commits. Nil
    /// when HEAD isn't loaded, e.g. while another branch's history shows.
    func isInCurrentHistory(_ commit: GitCommit) -> Bool? {
        guard let head = headHash, let lineage = loadedLineage(of: head) else { return nil }
        return lineage.contains(commit.hash)
    }

    func isHead(_ commit: GitCommit) -> Bool {
        commit.hash == headHash
    }

    /// The loaded commits `tip` leads to, itself too. Nil when it isn't loaded.
    /// Every commit between a loaded tip and a loaded ancestor is loaded too:
    /// the history comes in topological order.
    private func loadedLineage(of tip: String) -> Set<String>? {
        if let known = lineages[tip] { return known }
        let byHash = Dictionary(commits.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        guard byHash[tip] != nil else { return nil }
        var seen = Set<String>()
        var next = [tip]
        while let hash = next.popLast() {
            guard seen.insert(hash).inserted, let commit = byHash[hash] else { continue }
            next += commit.parents
        }
        lineages[tip] = seen
        return seen
    }

    /// Says so when any of `hashes` is already on the upstream branch, since
    /// rewriting them means a force push.
    private func pushedWarning(rewriting hashes: Set<String>) -> String? {
        guard let upstream,
              let tip = references.first(where: { $0.kind == .remoteBranch && $0.name == upstream })?.target,
              let pushed = loadedLineage(of: tip),
              !pushed.isDisjoint(with: hashes) else {
            return nil
        }
        return "Some of these commits are already on \(upstream). After this, \(headName) has to be force pushed, "
            + "and anyone who pulled them has to fix their copy."
    }

    /// The commits rewritten from `commit` on: it and the ones after it on
    /// HEAD's line.
    private func pushedWarning(rewritingFrom commit: GitCommit) -> String? {
        pushedWarning(rewriting: [commit.hash])
    }

    /// Runs `action`, or asks first when there is something to warn about:
    /// `always`, a warning, or, when it `changesFiles`, agents working here.
    private func confirmIfNeeded(
        _ title: String,
        message: String = "",
        action actionTitle: String,
        destructive: Bool = false,
        always: Bool = false,
        warning: String? = nil,
        changesFiles: Bool = true,
        run: @escaping @MainActor () -> Void
    ) {
        var parts = [message, warning ?? ""].filter { !$0.isEmpty }
        if changesFiles, let root = repositoryURL, let agents = agentsWorking?(root), !agents.isEmpty {
            let who = agents.count == 1
                ? "\(agents[0]) is working in this worktree."
                : "\(agents.formatted(.list(type: .and))) are working in this worktree."
            parts.append("\(who) This changes files during that work, and agents aren't told.")
        }
        guard always || parts.count > (message.isEmpty ? 0 : 1) else {
            run()
            return
        }
        confirmation = GitConfirmation(
            title: title,
            message: parts.joined(separator: "\n\n"),
            actionTitle: actionTitle,
            isDestructive: destructive,
            action: run
        )
    }

    /// Runs a git command that may stop part way, on a conflict. That isn't
    /// an error: the bar over the changes says what to do, and the changes
    /// show, to resolve the conflicts.
    private func mutateStoppable(_ label: String, action: @escaping @MainActor (URL) async throws -> Void) {
        mutate(label) { root in
            do {
                try await action(root)
            } catch let error as GitOperationError {
                guard GitClient.operationInProgress(at: root) != nil else { throw error }
                self.selectedSection = .changes
            }
        }
    }

    func copyHash(_ commit: GitCommit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
    }

    func showNewBranchSheet(at commit: GitCommit, checkout: Bool) {
        showNewBranchSheet(from: .commit(commit), checkout: checkout)
    }

    /// Detaches HEAD at the commit.
    func checkout(_ commit: GitCommit) {
        checkout(.commit(commit))
    }

    func cherryPick(_ commit: GitCommit) {
        confirmIfNeeded("Cherry-Pick \(commit.shortHash)?", action: "Cherry-Pick") {
            self.mutateStoppable("Cherry-picking \(commit.shortHash)") { root in
                try await self.client.cherryPick(at: root, commit: commit)
            }
        }
    }

    func revert(_ commit: GitCommit) {
        confirmIfNeeded("Revert \(commit.shortHash)?", action: "Revert") {
            self.mutateStoppable("Reverting \(commit.shortHash)") { root in
                try await self.client.revert(at: root, commit: commit)
            }
        }
    }

    /// Moves the current branch to `revision`. A hard reset asks first: it
    /// throws away uncommitted changes.
    func reset(to revision: String, named name: String, mode: GitResetMode) {
        let message: String
        switch mode {
        case .soft:
            message = "\(headName) moves to \(name). The changes of the commits it leaves, and anything staged, "
                + "end up staged. Commits it leaves can be found in the reflog."
        case .mixed:
            message = "\(headName) moves to \(name). The changes of the commits it leaves, and anything staged, "
                + "end up unstaged in the files. Commits it leaves can be found in the reflog."
        case .hard:
            message = "\(headName) moves to \(name), and every file goes back to how it is there. "
                + "Uncommitted changes are lost for good; commits it leaves can be found in the reflog."
        }
        confirmIfNeeded(
            "Reset \(headName) to \(name)?",
            message: message,
            action: "Reset",
            destructive: mode == .hard,
            always: true,
            changesFiles: mode == .hard
        ) {
            self.mutate("Resetting \(self.headName) to \(name)") { root in
                try await self.client.reset(at: root, to: revision, mode: mode)
            }
        }
    }

    func reset(to commit: GitCommit, mode: GitResetMode) {
        reset(to: commit.hash, named: commit.shortHash, mode: mode)
    }

    func reset(to reference: GitReference, mode: GitResetMode) {
        reset(to: reference.fullName, named: reference.name, mode: mode)
    }

    /// Opens the sheet with the commit's whole message.
    func showReword(_ commit: GitCommit) {
        guard let root = repositoryURL else { return }
        _ = startOperation("Reading \(commit.shortHash)") {
            let message = try await self.client.message(at: root, of: commit.hash)
            guard self.isCurrentRepository(root) else { return }
            self.rewordRequest = RewordRequest(commit: commit, message: message)
        }
    }

    /// HEAD's commit only gets a new message; an older one is rewritten
    /// with the commits after it. The sheet's button was the user's yes; it
    /// asks again only with something to warn about.
    func reword(_ commit: GitCommit, message: String) {
        let warning = pushedWarning(rewritingFrom: commit)
        if isHead(commit) {
            confirmIfNeeded("Change the Message of \(commit.shortHash)?", action: "Change", warning: warning, changesFiles: false) {
                self.mutate("Changing the message of \(commit.shortHash)") { root in
                    try await self.client.rewordHead(at: root, message: message)
                }
            }
            return
        }
        rewrite(from: commit.hash, target: commit, to: .reword, message: message,
                title: "Change the Message of \(commit.shortHash)?", action: "Change", asks: false,
                label: "Changing the message of \(commit.shortHash)", warning: warning)
    }

    /// Folds the commit into its parent: squash keeps both messages, fixup
    /// only the parent's.
    func fold(_ commit: GitCommit, keepingMessage: Bool) {
        guard let parent = commit.parents.first else { return }
        let verb = keepingMessage ? "Squash" : "Fixup"
        let explanation = keepingMessage
            ? "“\(commit.subject)” becomes part of its parent \(String(parent.prefix(8))), which keeps both messages."
            : "“\(commit.subject)” becomes part of its parent \(String(parent.prefix(8))), which keeps only its own message."
        rewrite(from: parent, target: commit, to: keepingMessage ? .squash : .fixup,
                title: "\(verb) \(commit.shortHash) into Its Parent?",
                explanation: explanation + " The commits after it on \(headName) are rewritten.",
                action: verb, label: "\(keepingMessage ? "Squashing" : "Fixing up") \(commit.shortHash)",
                warning: pushedWarning(rewriting: [commit.hash, parent]))
    }

    /// Takes the commit out of the branch: the commits after it are
    /// rewritten without it.
    func delete(_ commit: GitCommit) {
        rewrite(from: commit.hash, target: commit, to: .drop,
                title: "Delete Commit \(commit.shortHash)?",
                explanation: "“\(commit.subject)” and its changes are taken out of \(headName). "
                    + "The commits after it are rewritten.",
                action: "Delete", destructive: true,
                label: "Deleting \(commit.shortHash)", warning: pushedWarning(rewritingFrom: commit))
    }

    /// Rewrites HEAD's commits from `hash` on, with `target` changed to
    /// `targetAction`. Asks first unless `asks` is false and there is
    /// nothing to warn about.
    private func rewrite(
        from hash: String,
        target: GitCommit,
        to targetAction: RebaseAction,
        message newMessage: String = "",
        title: String,
        explanation: String = "",
        action: String,
        destructive: Bool = false,
        asks: Bool = true,
        label: String,
        warning: String?
    ) {
        confirmIfNeeded(title, message: explanation, action: action, destructive: destructive, always: asks, warning: warning) {
            self.mutateStoppable(label) { root in
                var plan = try await self.client.rebasePlan(at: root, from: hash, warning: nil)
                guard plan.set(target.hash, to: targetAction, message: newMessage) else {
                    throw GitOperationError(
                        command: "git rebase",
                        message: "\(target.shortHash) isn’t in the history of \(self.headName), so it can’t be changed here."
                    )
                }
                if let problem = plan.problem {
                    throw GitOperationError(command: "git rebase", message: problem)
                }
                try await self.client.rewrite(at: root, plan: plan)
            }
        }
    }

    /// Opens the sheet that rewrites the commit and the ones after it.
    func showInteractiveRebase(from commit: GitCommit) {
        guard let root = repositoryURL else { return }
        let warning = pushedWarning(rewritingFrom: commit)
        _ = startOperation("Reading the commits") {
            let plan = try await self.client.rebasePlan(at: root, from: commit.hash, warning: warning)
            guard self.isCurrentRepository(root) else { return }
            self.rebasePlan = plan
        }
    }

    /// Opens the sheet that puts the current branch's commits on top of
    /// `reference`, rewriting them on the way.
    func showInteractiveRebase(onto reference: GitReference) {
        guard let root = repositoryURL else { return }
        let warning = pushedWarning(rebasingOnto: reference)
        _ = startOperation("Reading the commits") {
            let plan = try await self.client.rebasePlan(at: root, onto: reference, warning: warning)
            guard self.isCurrentRepository(root) else { return }
            self.rebasePlan = plan
        }
    }

    /// The commits a rebase onto `reference` moves: HEAD's, without the
    /// ones `reference` has.
    private func pushedWarning(rebasingOnto reference: GitReference) -> String? {
        guard let head = headHash, let ours = loadedLineage(of: head),
              let theirs = loadedLineage(of: reference.target) else {
            return nil
        }
        return pushedWarning(rewriting: ours.subtracting(theirs))
    }

    /// Runs the sheet's plan.
    func runRebase(_ plan: RebasePlan) {
        let count = plan.steps.count
        confirmIfNeeded("Rewrite \(count) Commit\(count == 1 ? "" : "s")?", action: "Rewrite") {
            self.mutateStoppable("Rewriting \(count) commit\(count == 1 ? "" : "s")") { root in
                try await self.client.rewrite(at: root, plan: plan)
            }
        }
    }

    func merge(_ reference: GitReference) {
        confirmIfNeeded(
            "Merge \(reference.name) into \(headName)?",
            message: "This makes a merge commit on \(headName), or moves it forward when it has nothing of its own. "
                + "Conflicts stop the merge for you to resolve, or abort.",
            action: "Merge",
            always: true
        ) {
            self.mutateStoppable("Merging \(reference.name)") { root in
                try await self.client.merge(at: root, reference: reference)
            }
        }
    }

    func rebase(onto reference: GitReference) {
        confirmIfNeeded(
            "Rebase \(headName) onto \(reference.name)?",
            message: "The commits of \(headName) that \(reference.name) doesn’t have are rewritten on top of it. "
                + "Conflicts stop the rebase for you to resolve, or abort.",
            action: "Rebase",
            always: true,
            warning: pushedWarning(rebasingOnto: reference)
        ) {
            self.mutateStoppable("Rebasing \(self.headName) onto \(reference.name)") { root in
                try await self.client.rebase(at: root, onto: reference)
            }
        }
    }

    func continueOperation() {
        guard let operation else { return }
        guard conflictedChanges.isEmpty else {
            errorMessage = "Resolve the conflicts first, then continue the \(operation.noun)."
            return
        }
        mutateStoppable("Continuing the \(operation.noun)") { root in
            try await self.client.continueOperation(at: root, operation)
        }
    }

    func skipOperation() {
        guard let operation, operation.canSkip else { return }
        confirmIfNeeded(
            "Skip This Commit?",
            message: "The commit the \(operation.noun) stopped at is left out, with your work on its conflicts.",
            action: "Skip",
            destructive: true,
            always: true
        ) {
            self.mutateStoppable("Skipping a commit") { root in
                try await self.client.skipOperation(at: root, operation)
            }
        }
    }

    func abortOperation() {
        guard let operation else { return }
        confirmIfNeeded(
            "Abort the \(operation.noun.capitalized)?",
            message: "Everything goes back to how it was before the \(operation.noun). "
                + "Your work on its conflicts is lost.",
            action: "Abort",
            destructive: true,
            always: true
        ) {
            self.mutate("Aborting the \(operation.noun)") { root in
                try await self.client.abortOperation(at: root, operation)
            }
        }
    }

    /// The worktree the local branch is checked out in, other than this one.
    func worktree(holding reference: GitReference) -> GitWorktree? {
        guard reference.kind == .localBranch else { return nil }
        return worktrees.first { $0.branchName == reference.name && !$0.isPrunable }
    }

    /// Checks the branch out in a new worktree and starts `agent` there. A
    /// branch that already has a worktree starts it in that one.
    func newWorktree(for reference: GitReference, agent: Agent) {
        if let existing = worktree(holding: reference) {
            startSession?(agent, URL(fileURLWithPath: existing.path, isDirectory: true))
            return
        }
        guard let root = repositoryURL else { return }
        _ = startOperation("Making a worktree for \(reference.name)") {
            let directory = root.path
            let branch = reference.name
            let result = await Task.detached { Result { try addWorktree(directory, branch) } }.value
            let made: NewWorktree
            switch result {
            case let .success(value):
                made = value
            case let .failure(error):
                throw GitOperationError(command: "git worktree add", message: AgentzCore.errorMessage(error))
            }
            self.worktreeMade?(made)
            self.startSession?(agent, URL(fileURLWithPath: made.path, isDirectory: true))
            try await self.reload(root: root, historyScope: self.historyScope)
        }
    }
}

extension RebasePlan {
    /// False when the commit isn't one of the plan's.
    @discardableResult
    mutating func set(_ hash: String, to action: RebaseAction, message: String = "") -> Bool {
        guard let index = steps.firstIndex(where: { $0.commit.hash == hash }) else { return false }
        steps[index].action = action
        if action == .reword {
            steps[index].message = message
        }
        return true
    }
}

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
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var canLoadMoreHistory = false
    @Published private(set) var isLoadingMoreHistory = false
    @Published private(set) var diff = ""
    @Published private(set) var conflictDocument: ConflictDocument?
    @Published private(set) var isLoading = false
    @Published private(set) var operationLabel: String?
    @Published var selectedSection: WorkspaceSection = .history
    /// The git tab lists the branches, remotes, tags, stashes and worktrees
    /// in place of the changes or the history. Picking one of them, or the
    /// changes or a history, ends it.
    @Published var showsReferences = false
    @Published private(set) var historyScope: CommitHistoryScope = .all
    @Published var selectedCommit: GitCommit?
    @Published private(set) var selectedChange: WorkingChange?
    @Published private(set) var selectedChangeIsStaged = false
    @Published private(set) var changeSelection = ChangeSelectionModel()
    @Published var selectedReference: GitReference?
    @Published var selectedStash: GitStash?
    @Published var searchText = ""
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
    @Published private(set) var worktreePendingForceDelete: GitWorktree?
    @Published private(set) var pendingPushPlan: GitPushPlan?
    @Published private(set) var pendingBranchMove: GitBranchMove?
    @Published var isConfirmingPush = false
    @Published var isShowingBranchPicker = false
    /// The sheet that names a new branch at HEAD.
    @Published var isShowingNewBranchSheet = false
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
        return commits.filter {
            $0.subject.localizedCaseInsensitiveContains(searchText)
                || $0.authorName.localizedCaseInsensitiveContains(searchText)
                || $0.hash.localizedCaseInsensitiveContains(searchText)
                || $0.decorations.contains { $0.localizedCaseInsensitiveContains(searchText) }
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
            self.showsReferences = false
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
            try await self.reload(root: root)
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

    func selectChanges() {
        cancelHistoryPagination()
        showsReferences = false
        selectedSection = .changes
        historyScope = .all
        selectedReference = nil
        selectedStash = nil
        if let change = changes.first {
            selectChange(change, staged: change.isStaged)
        }
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

    func selectReference(_ reference: GitReference?) {
        guard let root = repositoryURL else { return }
        cancelHistoryPagination()
        showsReferences = false
        _ = startOperation("Loading \(reference?.name ?? "history")") {
            self.selectedStash = nil
            self.selectedReference = reference
            self.selectedSection = .history
            self.historyScope = CommitHistoryScope(revision: reference?.fullName)
            try await self.reloadHistory(root: root, scope: self.historyScope)
        }
    }

    func selectLostAndDanglingCommits() {
        guard let root = repositoryURL else { return }
        cancelHistoryPagination()
        showsReferences = false
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
        showsReferences = false
        _ = startOperation("Loading history for \(path)") {
            self.selectedStash = nil
            self.selectedSection = .history
            self.historyScope = .path(path, revision: revision)
            try await self.reloadHistory(root: root, scope: self.historyScope)
        }
    }

    func selectStash(_ stash: GitStash) {
        guard let root = repositoryURL else { return }
        cancelHistoryPagination()
        showsReferences = false
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
            self.historyScope = .all
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
        performCheckout(pending.reference)
    }

    private func performCheckout(_ reference: GitReference) {
        mutate("Switching to \(reference.name)") { root in
            do {
                try await self.client.checkout(at: root, reference: reference)
            } catch let error as CheckoutOverwriteError {
                self.pendingCheckout = PendingCheckout(reference: reference, reason: .overwrites(error.files))
                return
            }
            self.selectedReference = nil
            self.historyScope = .all
        }
    }

    /// Puts all changes in a stash, untracked files too, then does the
    /// switch git refused. The stash stays, to apply wherever the user wants.
    func stashAndCheckout() {
        guard let pending = pendingCheckout, case .overwrites = pending.reason, !isLoading else { return }
        pendingCheckout = nil
        let reference = pending.reference
        let message = "Before switching to \(reference.name)"
        mutate("Stashing and switching to \(reference.name)") { root in
            try await self.client.stash(at: root, message: message, scope: .all)
            do {
                try await self.client.checkout(at: root, reference: reference)
            } catch {
                throw GitOperationError(
                    command: "git switch \(reference.name)",
                    message: "\(error.localizedDescription)\n\nYour changes are in the stash “\(message)”."
                )
            }
            self.selectedReference = nil
            self.historyScope = .all
        }
    }

    func cancelCheckout() {
        pendingCheckout = nil
    }

    func createBranch(named name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        mutate("Creating \(cleanName)") { root in
            try await self.client.createBranch(at: root, name: cleanName)
            self.selectedReference = nil
            self.historyScope = .all
        }
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
        historyScope = .all
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
            try await reload(root: root, historyScope: historyScope)
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
        let load = try await client.snapshotAndStateToken(
            at: root,
            historyScope: historyScope,
            historyLimit: historyPageSize
        )
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
        replaceHistory(snapshot.commits)

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

    private func replaceHistory(_ loadedCommits: [GitCommit]) {
        commits = loadedCommits
        historyNextOffset = loadedCommits.count
        canLoadMoreHistory = loadedCommits.count == historyPageSize
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
        cancelHistoryPagination()
        repositoryPathTask?.cancel()
        repositoryPathTask = nil
        repositoryPathLoadID = nil
        repositoryPathItems = []
        isLoadingRepositoryPaths = false
        isShowingBranchPicker = false
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
        historyScope = .all
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


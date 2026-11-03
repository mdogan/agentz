import AgentzCore
import AppKit
import SwiftUI

/// The column next to the git tab's history: the local and remote branches,
/// tags, stashes and worktrees, and the unreachable commits. Picking one
/// narrows the history to it; right-click one for what it can do.
struct GitSidebarView: View {
    @EnvironmentObject private var store: RepositoryStore
    @AppStorage("gitBranchesExpanded") private var branchesExpanded = true
    @AppStorage("gitRemotesExpanded") private var remotesExpanded = false
    @AppStorage("gitTagsExpanded") private var tagsExpanded = false
    @AppStorage("gitStashesExpanded") private var stashesExpanded = true
    @AppStorage("gitWorktreesExpanded") private var worktreesExpanded = true

    private var primaryBranch: GitReference? {
        GitReference.primaryLocalBranch(in: store.references)
    }

    private var currentBranch: GitReference? {
        store.references.first {
            $0.kind == .localBranch && $0.isCurrent && $0 != primaryBranch
        }
    }

    private var remainingLocalBranches: [GitReference] {
        store.references.filter {
            $0.kind == .localBranch && !$0.isCurrent && $0 != primaryBranch
        }
    }

    private func references(of kind: ReferenceKind) -> [GitReference] {
        store.references.filter { $0.kind == kind }
    }

    /// The branch clicked in this list, if a branch is what was clicked.
    private var selectedBranch: GitReference? {
        store.selectedReference.flatMap { $0.kind == .tag ? nil : $0 }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                SidebarRow(
                    title: "All Branches",
                    icon: "square.stack.3d.up",
                    isSelected: store.historyScope == .all && store.selectedStash == nil
                ) {
                    store.selectReference(nil)
                } badge: {
                    EmptyView()
                }
                .help("Show the commits of all branches")

                let locals = references(of: .localBranch)
                SidebarSectionHeader(title: "Branches", count: locals.count, isExpanded: $branchesExpanded) {
                    Button {
                        store.showNewBranchSheet(from: selectedBranch)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Look.shared.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(GitForkHoverButtonStyle(.icon))
                    .help("Create a branch that starts at \(selectedBranch?.name ?? "HEAD")")
                    .disabled(store.isLoading)
                }
                .modifier(BranchDropTarget(prefix: ""))
                if branchesExpanded {
                    if let primaryBranch {
                        ReferenceSidebarRow(
                            reference: primaryBranch,
                            title: primaryBranch.name,
                            icon: primaryBranch.kind.icon
                        )
                    }
                    if let currentBranch {
                        ReferenceSidebarRow(
                            reference: currentBranch,
                            title: currentBranch.name,
                            icon: currentBranch.kind.icon
                        )
                    }
                    ReferenceTreeRows(references: remainingLocalBranches)
                    if locals.isEmpty {
                        EmptySidebarRow(title: "No branches")
                    }
                }

                let remotes = references(of: .remoteBranch)
                SidebarSectionHeader(title: "Remotes", count: remotes.count, isExpanded: $remotesExpanded)
                if remotesExpanded {
                    if remotes.isEmpty {
                        EmptySidebarRow(title: "No remotes")
                    } else {
                        ReferenceTreeRows(references: remotes)
                    }
                }

                let tags = references(of: .tag)
                SidebarSectionHeader(title: "Tags", count: tags.count, isExpanded: $tagsExpanded)
                if tagsExpanded {
                    if tags.isEmpty {
                        EmptySidebarRow(title: "No tags")
                    } else {
                        ReferenceTreeRows(references: tags)
                    }
                }

                SidebarSectionHeader(title: "Stashes", count: store.stashes.count, isExpanded: $stashesExpanded)
                if stashesExpanded {
                    if store.stashes.isEmpty {
                        EmptySidebarRow(title: "No stashes")
                    } else {
                        ForEach(store.stashes) { stash in
                            StashSidebarRow(stash: stash)
                        }
                    }
                }

                SidebarSectionHeader(title: "Worktrees", count: store.worktrees.count, isExpanded: $worktreesExpanded)
                if worktreesExpanded {
                    if store.worktrees.isEmpty {
                        EmptySidebarRow(title: "No worktrees")
                    } else {
                        ForEach(store.worktrees) { worktree in
                            WorktreeSidebarRow(worktree: worktree)
                        }
                    }
                }

                Rectangle()
                    .fill(Look.shared.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                SidebarRow(
                    title: "Unreachable Commits",
                    icon: "lifepreserver",
                    isSelected: store.historyScope == .lostAndDangling
                ) {
                    store.selectLostAndDanglingCommits()
                } badge: {
                    EmptyView()
                }
                .help("Commits no branch, tag or stash leads to, e.g. after a reset or a dropped stash")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .confirmationDialog(
            branchMoveTitle,
            isPresented: branchMoveBinding,
            titleVisibility: .visible,
            presenting: store.pendingBranchMove
        ) { _ in
            Button("Move Branch") {
                store.confirmBranchMove()
            }
            .disabled(store.isLoading)
            Button("Cancel", role: .cancel) {
                store.cancelBranchMove()
            }
        } message: { move in
            Text(branchMoveMessage(for: move))
        }
    }

    private var branchMoveBinding: Binding<Bool> {
        Binding(
            get: { store.pendingBranchMove != nil },
            set: { isPresented in
                if !isPresented {
                    store.cancelBranchMove()
                }
            }
        )
    }

    private var branchMoveTitle: String {
        guard let move = store.pendingBranchMove else { return "Move Branch?" }
        let destination = move.destinationPrefix.isEmpty
            ? "the top level"
            : "\(move.destinationPrefix)/"
        return "Move “\(move.reference.name)” to \(destination)?"
    }

    private func branchMoveMessage(for move: GitBranchMove) -> String {
        var message = "This renames the local branch to “\(move.newName)” and keeps its commits."
        if let upstream = move.reference.upstream {
            message += " " + """
            It keeps tracking \(upstream.shortName); the branch on \(upstream.remote) \
            is not renamed.
            """
        }
        return message
    }
}

private struct WorktreeSidebarRow: View {
    private enum Action {
        case delete
        case prune
    }

    @EnvironmentObject private var store: RepositoryStore
    @State private var pendingAction: Action?
    @State private var isConfirmingAction = false

    let worktree: GitWorktree

    var body: some View {
        SidebarRow(
            title: worktree.displayName,
            icon: "rectangle.stack",
            isSelected: false,
            isEnabled: !worktree.isPrunable,
            isProminent: worktree.isCurrent
        ) {
            open(.claude)
        } badge: {
            Text(worktree.branchName ?? (worktree.isDetached ? "Detached" : ""))
                .lineLimit(1)
        }
        .help(worktree.path)
        .contextMenu {
            ForEach([Agent.claude, .codex, .shell, .git], id: \.self) { agent in
                Button(agent.newHere) {
                    open(agent)
                }
                .disabled(worktree.isPrunable || agent == .git && worktree.isCurrent)
            }

            if worktree.isPrunable {
                Divider()
                Button(role: .destructive) {
                    confirm(.prune)
                } label: {
                    Label("Prune Stale Worktrees", systemImage: "trash")
                }
                .disabled(store.isLoading)
            } else if !worktree.isCurrent {
                Divider()
                Button(role: .destructive) {
                    confirm(.delete)
                } label: {
                    Label("Delete Worktree", systemImage: "trash")
                }
                .disabled(
                    worktree.isBare
                        || worktree.isLocked
                        || store.isLoading
                )
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            if isConfirmingForceDelete {
                Button("Force Delete Worktree", role: .destructive) {
                    store.forceDelete(worktree)
                }
                .disabled(store.isLoading)
            } else if pendingAction == .delete {
                Button("Delete Worktree", role: .destructive) {
                    store.delete(worktree)
                }
                .disabled(store.isLoading)
            } else if pendingAction == .prune {
                Button("Prune Stale Worktrees", role: .destructive) {
                    store.pruneStaleWorktrees()
                }
                .disabled(store.isLoading)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var isConfirmingForceDelete: Bool {
        store.worktreePendingForceDelete == worktree
    }

    /// Keeps the manual confirmation and the follow-up force confirmation on a
    /// single dialog, so a refused removal reopens in place instead of asking
    /// the user to find the row again.
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { isConfirmingAction || isConfirmingForceDelete },
            set: { isPresented in
                guard !isPresented else { return }
                isConfirmingAction = false
                if isConfirmingForceDelete {
                    store.cancelWorktreeForceDelete()
                }
            }
        )
    }

    private var confirmationTitle: String {
        if isConfirmingForceDelete {
            return "Force Delete Worktree “\(worktree.displayName)”?"
        }
        switch pendingAction {
        case .delete:
            return "Delete Worktree “\(worktree.displayName)”?"
        case .prune:
            return "Prune Stale Worktrees?"
        case nil:
            return "Confirm Worktree Action"
        }
    }

    private var confirmationMessage: String {
        if isConfirmingForceDelete {
            return """
            This worktree contains modified or untracked files. Force deleting it runs \
            git worktree remove --force and permanently discards that uncommitted work.
            """
        }
        switch pendingAction {
        case .delete:
            return """
            This removes the worktree directory and its Git registration. Git will refuse \
            if it contains uncommitted changes.\(branchRetentionMessageSuffix)
            """
        case .prune:
            return """
            This removes the Git registration for every stale worktree in this repository. \
            It does not delete existing worktree directories, and Git preserves locked worktrees.
            """
        case nil:
            return ""
        }
    }

    /// Deleting a worktree never deletes the branch it holds, and freeing that
    /// branch is the usual reason for removing the worktree in the first place.
    private var branchRetentionMessageSuffix: String {
        guard let branchName = worktree.branchName else {
            return " Detached commits not referenced by a branch or tag may become unreachable."
        }
        return " The branch \(branchName) is kept and becomes available for checkout and deletion."
    }

    private func confirm(_ action: Action) {
        pendingAction = action
        isConfirmingAction = true
    }

    /// Starts a session of `agent` in the worktree; the panel then shows
    /// it, as the shown session's.
    private func open(_ agent: Agent) {
        guard !worktree.isPrunable else { return }
        store.startSession?(agent, URL(fileURLWithPath: worktree.path, isDirectory: true))
    }
}

private struct StashSidebarRow: View {
    private enum Action: Equatable {
        case apply
        case drop
    }

    @EnvironmentObject private var store: RepositoryStore
    @State private var pendingAction: Action?
    @State private var isConfirmingAction = false

    let stash: GitStash

    var body: some View {
        SidebarRow(
            title: stash.displayName,
            icon: "archivebox",
            isSelected: store.selectedStash == stash
        ) {
            store.selectStash(stash)
        } badge: {
            EmptyView()
        }
        .contextMenu {
            Button("Show Stash") {
                store.selectStash(stash)
            }

            Divider()

            Button {
                confirm(.apply)
            } label: {
                Label("Apply Stash", systemImage: "arrow.uturn.backward")
            }
            .disabled(store.isLoading)

            Button(role: .destructive) {
                confirm(.drop)
            } label: {
                Label("Drop Stash", systemImage: "trash")
            }
            .disabled(store.isLoading)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isConfirmingAction,
            titleVisibility: .visible
        ) {
            if pendingAction == .apply {
                Button("Apply Stash") {
                    store.apply(stash)
                }
            } else if pendingAction == .drop {
                Button("Drop Stash", role: .destructive) {
                    store.drop(stash)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .apply:
            "Apply “\(stash.displayName)”?"
        case .drop:
            "Drop “\(stash.displayName)”?"
        case nil:
            "Confirm Stash Action"
        }
    }

    private var confirmationMessage: String {
        switch pendingAction {
        case .apply:
            """
            This applies the stashed changes and restores their staged state. \
            The stash will remain available. Existing changes may cause conflicts.
            """
        case .drop:
            """
            This permanently removes the stash without applying its changes. \
            This action cannot be undone.
            """
        case nil:
            ""
        }
    }

    private func confirm(_ action: Action) {
        pendingAction = action
        isConfirmingAction = true
    }
}

/// A section's title, its count and a chevron. Click it to fold or
/// unfold the section.
private struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    /// A button of the section's own, next to the chevron.
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovered = false

    var body: some View {
        toggle.overlay(alignment: .trailing) {
            accessory()
                .padding(.top, 6)
                .padding(.trailing, 18)
        }
    }

    private var toggle: some View {
        let look = Look.shared
        return Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(look.secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(look.faint)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovered ? look.secondary : look.faint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isExpanded ? "Hide the \(title.lowercased())" : "Show the \(title.lowercased())")
    }
}

extension SidebarSectionHeader where Accessory == EmptyView {
    init(title: String, count: Int, isExpanded: Binding<Bool>) {
        self.init(title: title, count: count, isExpanded: isExpanded) { EmptyView() }
    }
}

/// A tree node paired with the depth it is rendered at. The tree is flattened
/// so every row — folder or reference — is an ordinary, fully clickable row.
private struct ReferenceTreeRow: Identifiable {
    let node: ReferenceTreeNode
    let depth: Int

    var id: String { node.id }
}

private struct ReferenceTreeRows: View {
    private static let indentStep: CGFloat = 13

    @State private var expandedPaths: Set<String> = []

    let references: [GitReference]

    var body: some View {
        ForEach(rows(for: ReferenceTreeNode.build(from: references), depth: 0)) { row in
            if row.node.children.isEmpty, let reference = row.node.reference {
                ReferenceSidebarRow(
                    reference: reference,
                    title: row.node.name,
                    icon: reference.kind.icon,
                    indent: indent(for: row.depth)
                )
            } else {
                ReferenceFolderRow(
                    node: row.node,
                    indent: indent(for: row.depth),
                    isExpanded: expandedPaths.contains(row.node.id)
                ) {
                    toggle(row.node)
                }
            }
        }
    }

    private func rows(for nodes: [ReferenceTreeNode], depth: Int) -> [ReferenceTreeRow] {
        nodes.flatMap { node -> [ReferenceTreeRow] in
            let row = ReferenceTreeRow(node: node, depth: depth)
            guard !node.children.isEmpty, expandedPaths.contains(node.id) else {
                return [row]
            }
            return [row] + rows(for: node.children, depth: depth + 1)
        }
    }

    private func indent(for depth: Int) -> CGFloat {
        CGFloat(depth) * Self.indentStep
    }

    private func toggle(_ node: ReferenceTreeNode) {
        if expandedPaths.contains(node.id) {
            expandedPaths.remove(node.id)
        } else {
            expandedPaths.insert(node.id)
        }
    }
}

/// A grouping row such as `origin` or `feature`. The whole row is the
/// disclosure control, so clicking the name toggles it like the chevron does.
private struct ReferenceFolderRow: View {
    let node: ReferenceTreeNode
    let indent: CGFloat
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Look.shared.faint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16)
                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Look.shared.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, indent)
            .contentShape(Rectangle())
        }
        .buttonStyle(GitForkHoverButtonStyle(.compactRow(isSelected: false)))
        .help(isExpanded ? "Collapse \(node.path)" : "Expand \(node.path)")
        .modifier(BranchDropTarget(prefix: node.kind == .localBranch ? node.path : nil))
    }
}

/// Accepts a dragged local branch and asks to move it under `prefix`, which
/// can be several levels deep. An empty prefix means the top level; `nil`
/// leaves the row inert, as it is for remote and tag folders.
private struct BranchDropTarget: ViewModifier {
    @EnvironmentObject private var store: RepositoryStore
    @State private var isTargeted = false

    let prefix: String?

    func body(content: Content) -> some View {
        if let prefix {
            content
                .dropDestination(for: String.self) { names, _ in
                    guard let name = names.first else { return false }
                    return store.requestBranchMove(named: name, toPrefix: prefix)
                } isTargeted: {
                    isTargeted = $0
                }
                .background {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(GitForkTheme.accent.opacity(0.16))
                    }
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(GitForkTheme.accent.opacity(0.6), lineWidth: 1)
                    }
                }
        } else {
            content
        }
    }
}

private struct ReferenceSidebarRow: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var isConfirmingDelete = false
    @State private var isRenaming = false
    @State private var isChoosingPrefix = false

    let reference: GitReference
    let title: String
    let icon: String
    var indent: CGFloat = 0

    var body: some View {
        SidebarRow(
            title: title,
            icon: icon,
            isSelected: store.selectedReference == reference,
            isProminent: reference.isCurrent,
            indent: indent,
            dragPayload: reference.kind == .localBranch ? reference.name : nil
        ) {
            store.selectReference(reference)
        } badge: {
            if reference.isCurrent {
                Text("current")
            }
        }
        .help(reference.name)
        .contextMenu {
            Button("Show History") {
                store.selectReference(reference)
            }
            Divider()
            Button(reference.kind == .tag ? "Checkout Detached" : "Checkout") {
                store.checkout(reference)
            }
            .disabled(store.isLoading)

            if reference.kind != .tag {
                Button {
                    store.showNewBranchSheet(from: reference)
                } label: {
                    Label("New Branch from “\(reference.name)”…", systemImage: "arrow.triangle.branch")
                }
                .disabled(store.isLoading)
            }

            if reference.kind == .localBranch {
                Button {
                    store.requestPushConfirmation(for: reference)
                } label: {
                    Label("Push to Remote…", systemImage: "arrow.up.to.line")
                }
                .disabled(store.isLoading)

                Button {
                    isRenaming = true
                } label: {
                    Label("Rename Branch…", systemImage: "pencil")
                }
                .disabled(store.isLoading)

                Menu {
                    ForEach(prefixMoves, id: \.newName) { move in
                        Button(move.destinationPrefix.isEmpty ? "Top Level" : move.destinationPrefix) {
                            store.requestBranchMove(
                                named: reference.name,
                                toPrefix: move.destinationPrefix
                            )
                        }
                        .disabled(move.conflictingBranch(in: store.references) != nil)
                    }
                    if !prefixMoves.isEmpty {
                        Divider()
                    }
                    Button("New Prefix…") {
                        isChoosingPrefix = true
                    }
                } label: {
                    Label("Move to Prefix", systemImage: "folder")
                }
                .disabled(store.isLoading)
            }

            if reference.kind != .remoteBranch || remoteBranchTarget != nil {
                Divider()
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label(deleteActionTitle, systemImage: "trash")
                }
                .disabled(reference.isCurrent || store.isLoading)
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let remoteBranchTarget {
                Button("Delete from \(remoteBranchTarget.remote)", role: .destructive) {
                    store.deleteRemoteBranch(reference)
                }
                .disabled(store.isLoading)
            } else if isConfirmingForceDelete {
                if let remoteBranch {
                    Button(
                        "Force Delete Branch and \(remoteBranch.shortName)",
                        role: .destructive
                    ) {
                        store.forceDelete(reference, includingRemote: true)
                    }
                    .disabled(store.isLoading)
                }
                Button(forceDeleteActionTitle, role: .destructive) {
                    store.forceDelete(reference)
                }
                .disabled(store.isLoading)
            } else {
                if let remoteBranch {
                    Button(
                        "Delete Branch and \(remoteBranch.shortName)",
                        role: .destructive
                    ) {
                        store.delete(reference, includingRemote: true)
                    }
                }
                Button(localOnlyDeleteActionTitle, role: .destructive) {
                    store.delete(reference)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
        .sheet(isPresented: $isRenaming) {
            RenameBranchSheet(reference: reference, isPresented: $isRenaming)
                .lookWindowStyle()
        }
        .sheet(isPresented: $isChoosingPrefix) {
            MoveBranchToPrefixSheet(reference: reference, isPresented: $isChoosingPrefix)
                .lookWindowStyle()
        }
    }

    /// The top level, when the branch has a prefix, followed by every other
    /// prefix already in use. The branch's own prefix is left out.
    private var prefixMoves: [GitBranchMove] {
        ([""] + GitBranchMove.prefixes(in: store.references)).compactMap {
            GitBranchMove(reference: reference, toPrefix: $0)
        }
    }

    /// The remote-tracking branch this row can offer to delete alongside the
    /// local branch, when one still exists.
    private var remoteBranch: GitUpstream? {
        store.deletableRemoteBranch(for: reference)
    }

    /// Set only on `Remotes` rows, where deletion targets the branch on the
    /// remote itself rather than anything local.
    private var remoteBranchTarget: GitUpstream? {
        reference.remoteBranchTarget
    }

    private var deleteActionTitle: String {
        switch reference.kind {
        case .tag: "Delete Tag"
        case .remoteBranch: "Delete Remote Branch"
        case .localBranch: "Delete Branch"
        }
    }

    private var localOnlyDeleteActionTitle: String {
        remoteBranch == nil ? deleteActionTitle : "Delete Local Branch Only"
    }

    private var forceDeleteActionTitle: String {
        remoteBranch == nil ? "Force Delete Branch" : "Force Delete Local Branch Only"
    }

    private var isConfirmingForceDelete: Bool {
        store.branchPendingForceDelete == reference
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { isConfirmingDelete || isConfirmingForceDelete },
            set: { isPresented in
                guard !isPresented else { return }
                isConfirmingDelete = false
                if isConfirmingForceDelete {
                    store.cancelForceDelete()
                }
            }
        )
    }

    private var deleteConfirmationTitle: String {
        if isConfirmingForceDelete {
            return "Force Delete Branch “\(reference.name)”?"
        }
        return "\(deleteActionTitle) “\(reference.name)”?"
    }

    private var deleteConfirmationMessage: String {
        if let remoteBranchTarget {
            return """
            This deletes the branch from \(remoteBranchTarget.remote) for everyone \
            using that remote.\(trackingBranchMessageSuffix)
            """
        }
        if isConfirmingForceDelete {
            return """
            Git reports that this branch contains commits that are not fully merged. \
            Force deleting it runs git branch -D and may permanently discard those commits.\
            \(remoteBranchMessageSuffix)
            """
        }
        if reference.kind == .tag {
            return "This deletes the local tag. It does not delete the tag from any remote."
        }
        return """
        This deletes the local branch. Git will refuse if it contains unmerged commits.\
        \(remoteBranchMessageSuffix)
        """
    }

    private var remoteBranchMessageSuffix: String {
        guard let remoteBranch else { return "" }
        return " " + """
        This branch tracks \(remoteBranch.shortName), which can be deleted from \
        \(remoteBranch.remote) at the same time.
        """
    }

    /// Names the local branches left with an upstream that no longer resolves
    /// once the remote branch is gone.
    private var trackingBranchMessageSuffix: String {
        let tracking = store.localBranchesTracking(reference).map(\.name)
        guard !tracking.isEmpty else { return "" }
        let names = tracking.map { "“\($0)”" }.formatted(.list(type: .and))
        if tracking.count == 1 {
            return " The local branch \(names) keeps its commits but loses its upstream."
        }
        return " The local branches \(names) keep their commits but lose their upstream."
    }
}

private struct EmptySidebarRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(Look.shared.faint)
            .padding(.leading, 28)
            .padding(.vertical, 3)
    }
}

private struct SidebarRow<Badge: View>: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let isEnabled: Bool
    let isProminent: Bool
    let indent: CGFloat
    /// Makes the row draggable, carrying this string, such as a local branch
    /// name dropped on a `BranchDropTarget`.
    let dragPayload: String?
    let action: () -> Void
    @ViewBuilder let badge: () -> Badge

    init(
        title: String,
        icon: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        isProminent: Bool = false,
        indent: CGFloat = 0,
        dragPayload: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.isProminent = isProminent
        self.indent = indent
        self.dragPayload = dragPayload
        self.action = action
        self.badge = badge
    }

    var body: some View {
        clickableRow
            .disabled(!isEnabled)
            .help("Show \(title)")
    }

    /// A `Button` tracks the mouse from press to release and never lets a drag
    /// begin, so a draggable row handles its click with a tap gesture instead.
    /// The tap only fires when the pointer does not move, which leaves any
    /// movement free to start the drag.
    @ViewBuilder
    private var clickableRow: some View {
        if let dragPayload {
            GitForkHoverButtonBody(label: label, isPressed: false, variant: variant)
                .onTapGesture(perform: action)
                .draggable(dragPayload) {
                    Label(dragPayload, systemImage: icon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            Button(action: action) {
                label
            }
            .buttonStyle(GitForkHoverButtonStyle(variant))
        }
    }

    private var variant: GitForkHoverButtonVariant {
        .compactRow(isSelected: isSelected)
    }

    private var label: some View {
        let look = Look.shared
        return HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isProminent ? look.accent : look.secondary)
            Text(title)
                .font(.system(size: 12.5, weight: isProminent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            badge()
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(look.secondary)
        }
        .padding(.leading, indent)
        .contentShape(Rectangle())
    }
}

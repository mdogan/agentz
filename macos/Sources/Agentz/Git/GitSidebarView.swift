import AgentzCore
import SwiftUI

struct GitSidebarView: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var branchesExpanded = true
    @State private var remotesExpanded = false
    @State private var tagsExpanded = false
    @State private var stashesExpanded = false
    @State private var worktreesExpanded = false

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

    var body: some View {
        List {
            Section {
                SidebarRow(
                    title: "Unreachable Commits",
                    icon: "lifepreserver",
                    isSelected: store.selectedSection == .history
                        && store.selectedStash == nil
                        && store.historyScope == .lostAndDangling,
                    size: .regular
                ) {
                    store.selectLostAndDanglingCommits()
                } badge: {
                    EmptyView()
                }
            }

            Section(isExpanded: $branchesExpanded) {
                if let primaryBranch {
                    ReferenceSidebarRow(
                        reference: primaryBranch,
                        title: primaryBranch.name,
                        icon: primaryBranch.isCurrent
                            ? "checkmark.circle.fill"
                            : primaryBranch.kind.icon
                    )
                    .fontWeight(.bold)
                }

                if let currentBranch {
                    ReferenceSidebarRow(
                        reference: currentBranch,
                        title: currentBranch.name,
                        icon: "checkmark.circle.fill"
                    )
                    .fontWeight(.semibold)
                }

                ReferenceTreeRows(references: remainingLocalBranches)

                if primaryBranch == nil && currentBranch == nil && remainingLocalBranches.isEmpty {
                    EmptySidebarRow(title: "No Branches")
                }
            } header: {
                SidebarSectionHeader(title: "Branches", isExpanded: $branchesExpanded)
                    .modifier(BranchDropTarget(prefix: ""))
            }

            Section(isExpanded: $remotesExpanded) {
                if references(of: .remoteBranch).isEmpty {
                    EmptySidebarRow(title: "No Remotes")
                } else {
                    ReferenceTreeRows(references: references(of: .remoteBranch))
                }
            } header: {
                SidebarSectionHeader(title: "Remotes", isExpanded: $remotesExpanded)
            }

            Section(isExpanded: $tagsExpanded) {
                if references(of: .tag).isEmpty {
                    EmptySidebarRow(title: "No Tags")
                } else {
                    ReferenceTreeRows(references: references(of: .tag))
                }
            } header: {
                SidebarSectionHeader(title: "Tags", isExpanded: $tagsExpanded)
            }

            Section(isExpanded: $stashesExpanded) {
                if store.stashes.isEmpty {
                    EmptySidebarRow(title: "No Stashes")
                } else {
                    ForEach(store.stashes) { stash in
                        StashSidebarRow(stash: stash)
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Stashes", isExpanded: $stashesExpanded)
            }

            Section(isExpanded: $worktreesExpanded) {
                if store.worktrees.isEmpty {
                    EmptySidebarRow(title: "No Worktrees")
                } else {
                    ForEach(store.worktrees) { worktree in
                        WorktreeSidebarRow(worktree: worktree)
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Worktrees", isExpanded: $worktreesExpanded)
            }
        }
        .listStyle(.sidebar)
        .lookListBackground(Look.shared.sidebar)
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
            icon: worktree.isCurrent
                ? "checkmark.circle.fill"
                : "rectangle.stack",
            isSelected: false,
            isEnabled: !worktree.isPrunable
        ) {
            open(.claude)
        } badge: {
            Text(worktree.branchName ?? (worktree.isDetached ? "Detached" : ""))
                .lineLimit(1)
        }
        .help(worktree.path)
        .contextMenu {
            ForEach([Agent.claude, .codex, .shell], id: \.self) { agent in
                Button(agent.newHere) {
                    open(agent)
                }
                .disabled(worktree.isPrunable)
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

private struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
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
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: isExpanded)
                    .frame(width: 16)
                Text(node.name)
                    .lineLimit(1)
                Spacer()
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.leading, indent)
            .contentShape(Rectangle())
        }
        .buttonStyle(GitForkHoverButtonStyle(.compactRow(isSelected: false)))
        .help(isExpanded ? "Collapse \(node.path)" : "Expand \(node.path)")
        .modifier(BranchDropTarget(prefix: node.kind == .localBranch ? node.path : nil))
        .listRowBackground(Color.clear)
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
                Text("CURRENT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GitForkTheme.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(GitForkTheme.green.opacity(0.13), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(GitForkTheme.green.opacity(0.35), lineWidth: 1)
                    }
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
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.leading, 26)
    }
}

private enum SidebarRowSize {
    case regular
    case compact
}

private struct SidebarRow<Badge: View>: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let isEnabled: Bool
    let isProminent: Bool
    let size: SidebarRowSize
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
        size: SidebarRowSize = .compact,
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
        self.size = size
        self.indent = indent
        self.dragPayload = dragPayload
        self.action = action
        self.badge = badge
    }

    var body: some View {
        clickableRow
            .disabled(!isEnabled)
            .background {
                if isProminent && !isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(GitForkTheme.green.opacity(0.10))
                }
            }
            .overlay {
                if isProminent && !isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(GitForkTheme.green.opacity(0.32), lineWidth: 1)
                }
            }
            .overlay(alignment: .leading) {
                if isProminent {
                    Capsule()
                        .fill(GitForkTheme.green)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
            .help("Show \(title)")
            .listRowBackground(Color.clear)
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
        size == .regular
            ? .row(isSelected: isSelected)
            : .compactRow(isSelected: isSelected)
    }

    private var label: some View {
        HStack(spacing: size == .regular ? 9 : 7) {
            Image(systemName: icon)
                .frame(width: size == .regular ? 20 : 16)
                .foregroundStyle(
                    isProminent
                        ? GitForkTheme.green
                        : isSelected ? GitForkTheme.accent : .secondary
                )
            Text(title)
                .lineLimit(1)
            Spacer()
            badge()
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(size == .regular ? .title3 : .body)
        .padding(.leading, indent)
        .contentShape(Rectangle())
    }
}

import AppKit
import SwiftUI

struct GitChangesView: View {
    @EnvironmentObject private var store: RepositoryStore
    @Binding var showingStashSheet: Bool
    @Binding var stashScope: StashScope
    /// With the menu that stashes changes. The Changes panel leaves it to
    /// the git tab.
    var showsStash = true
    @State private var showingCommitSheet = false

    var body: some View {
        let look = Look.shared
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(changeCountLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(look.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if showsStash {
                    stashMenu
                }

                Button {
                    showingCommitSheet = true
                } label: {
                    Text(store.signCommit ? "Sign & Commit…" : "Commit…")
                }
                .buttonStyle(GitPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .help(
                    store.conflictedChanges.isEmpty
                        ? "Write a commit message for the staged changes (⌘↩)"
                        : "Resolve all conflicts before committing"
                )
                .disabled(store.isLoading || !store.conflictedChanges.isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 34)

            Rectangle().fill(look.divider).frame(height: 1)

            ChangeList()
                .frame(maxHeight: .infinity)
        }
        .sheet(isPresented: $showingCommitSheet) {
            CommitSheet(isPresented: $showingCommitSheet)
                .lookWindowStyle()
        }
    }

    private var stashMenu: some View {
        Menu {
            Button {
                showStashSheet(for: .staged)
            } label: {
                Label("Staged Changes", systemImage: "checkmark.circle")
            }
            .disabled(
                store.stagedChanges.isEmpty
                    || hasPartiallyStagedFiles
            )

            Button {
                showStashSheet(for: .unstaged)
            } label: {
                Label("Unstaged Changes", systemImage: "pencil.circle")
            }
            .disabled(store.unstagedChanges.isEmpty)

            Divider()

            Button {
                showStashSheet(for: .all)
            } label: {
                Label("All Changes", systemImage: "tray.full")
            }
        } label: {
            Image(systemName: "archivebox")
                .font(.system(size: 13))
                .foregroundStyle(Look.shared.secondary)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.button)
        .buttonStyle(GitForkHoverButtonStyle(.icon))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            store.conflictedChanges.isEmpty
                ? "Stash changes: put them away and take them out of the working tree"
                : "Resolve all conflicts before stashing changes"
        )
        .disabled(
            store.changes.isEmpty
                || store.isLoading
                || !store.conflictedChanges.isEmpty
        )
    }

    private var changeCountLabel: String {
        let count = store.changes.count
        return count == 0 ? "No changes" : "\(count) changed file\(count == 1 ? "" : "s")"
    }

    private var hasPartiallyStagedFiles: Bool {
        store.changes.contains { $0.isStaged && $0.isUnstaged }
    }

    private func showStashSheet(for scope: StashScope) {
        stashScope = scope
        showingStashSheet = true
    }
}

private struct ChangeList: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var pendingDiscard: [ChangeEntry] = []
    @State private var pendingConflictResolution: ConflictResolutionRequest?
    @FocusState private var isListFocused: Bool
    /// Folders the user folded, as `ChangeTreeRow.folder` ids.
    @State private var collapsedFolders: Set<String> = []

    var body: some View {
        let entries = store.changeEntries
        let stagedEntries = entries.stagedSide
        let conflictEntries = entries.conflicted
        let unstagedEntries = entries.unstagedSide
        VStack(spacing: 0) {
            if store.changeSelection.count > 1 {
                SelectionActionBar(
                    entries: store.selectedChangeEntries,
                    requestDiscard: requestDiscard,
                    requestConflictResolution: requestConflictResolution
                )
                Divider()
            }

            List(selection: primarySelection) {
                if !stagedEntries.isEmpty {
                    ChangeSectionHeader(
                        title: "Staged",
                        count: stagedEntries.count,
                        tint: nil,
                        actionTitle: "Unstage All",
                        action: store.unstageAll
                    )
                    treeRows(stagedEntries, section: "staged")
                }

                if !conflictEntries.isEmpty {
                    ChangeSectionHeader(
                        title: "Conflicts",
                        count: conflictEntries.count,
                        tint: GitForkTheme.orange,
                        actionTitle: nil,
                        action: nil
                    )
                    treeRows(conflictEntries, section: "conflicts")
                }

                if !unstagedEntries.isEmpty {
                    ChangeSectionHeader(
                        title: "Unstaged",
                        count: unstagedEntries.count,
                        tint: nil,
                        actionTitle: "Stage All",
                        action: store.stageAll
                    )
                    treeRows(unstagedEntries, section: "unstaged")
                }
            }
            .listStyle(.plain)
            .lookListBackground(Look.shared.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
            .focused($isListFocused)
            .onKeyPress(characters: ChangeSelectionKey.returnCharacters) { _ in
                performKeyboardAction(for: .returnKey)
            }
            .onKeyPress(.space) {
                openSideBySideDiff()
            }
            .onDeleteCommand {
                _ = performKeyboardAction(for: .deleteKey)
            }
            .overlay {
                if store.changes.isEmpty {
                    GitPlaceholder("Nothing to commit. The working tree is clean.")
                }
            }
        }
        .alert(
            DiscardPrompt.title(for: pendingDiscard),
            isPresented: Binding(
                get: { !pendingDiscard.isEmpty },
                set: { if !$0 { pendingDiscard = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDiscard = []
            }
            Button("Discard", role: .destructive) {
                store.discard(pendingDiscard)
                pendingDiscard = []
            }
        } message: {
            Text(DiscardPrompt.message(for: pendingDiscard))
        }
        .alert(
            ConflictResolutionPrompt.title(for: pendingConflictResolution),
            isPresented: Binding(
                get: { pendingConflictResolution != nil },
                set: { if !$0 { pendingConflictResolution = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingConflictResolution = nil
            }
            Button(
                ConflictResolutionPrompt.actionTitle(for: pendingConflictResolution),
                role: .destructive
            ) {
                if let request = pendingConflictResolution {
                    store.resolveConflicts(request.entries, using: request.side)
                }
                pendingConflictResolution = nil
            }
        } message: {
            Text(ConflictResolutionPrompt.message(for: pendingConflictResolution))
        }
    }

    /// One section's files as a folder tree.
    @ViewBuilder
    private func treeRows(_ entries: [ChangeEntry], section: String) -> some View {
        ForEach(ChangeTree.rows(entries, section: section, collapsed: collapsedFolders)) { row in
            switch row {
            case let .folder(id, name, depth, count, isCollapsed):
                ChangeFolderRow(
                    name: name,
                    depth: depth,
                    count: count,
                    isCollapsed: isCollapsed
                ) {
                    if isCollapsed {
                        collapsedFolders.remove(id)
                    } else {
                        collapsedFolders.insert(id)
                    }
                    focusList()
                }
            case let .file(entry, name, depth):
                ChangeRow(
                    entry: entry,
                    displayName: name,
                    depth: depth,
                    requestDiscard: requestDiscard,
                    requestConflictResolution: requestConflictResolution,
                    focusList: focusList
                )
                .tag(entry.id)
            }
        }
    }

    private var primarySelection: Binding<ChangeEntryID?> {
        Binding(
            get: { store.changeSelection.primary },
            set: store.selectChangeEntry
        )
    }

    private func requestDiscard(_ entries: [ChangeEntry]) {
        let targets = entries.unstagedSide
        guard !targets.isEmpty else { return }
        pendingDiscard = targets
    }

    private func requestConflictResolution(
        _ entries: [ChangeEntry],
        using side: ConflictResolutionSide
    ) {
        let conflicts = entries.conflicted
        guard !conflicts.isEmpty else { return }
        pendingConflictResolution = ConflictResolutionRequest(
            entries: conflicts,
            side: side
        )
    }

    private func focusList() {
        isListFocused = true
    }

    private func openSideBySideDiff() -> KeyPress.Result {
        guard let repositoryURL = store.repositoryURL,
              let change = store.selectedChange,
              !change.isConflicted,
              !store.diff.isEmpty else {
            return .ignored
        }
        GitWindows.openSideBySideDiff(SideBySideDiffWindowState(
                repositoryURL: repositoryURL,
                change: change,
                staged: store.selectedChangeIsStaged,
                diff: store.diff
            )
        )
        return .handled
    }

    private func performKeyboardAction(
        for key: ChangeSelectionKey
    ) -> KeyPress.Result {
        guard let action = store.changeSelection.keyboardAction(for: key) else {
            return .ignored
        }
        guard !store.isLoading else { return .handled }

        switch action {
        case .stage:
            if store.selectedChange?.isConflicted == true {
                store.markConflictsResolved(store.selectedChangeEntries)
            } else {
                store.stage(store.selectedChangeEntries)
            }
        case .unstage:
            store.unstage(store.selectedChangeEntries)
        }
        return .handled
    }
}

/// Batch actions for the current multi-selection, shown above the list so the
/// selection has a visible destination beyond the context menu.
private struct SelectionActionBar: View {
    @EnvironmentObject private var store: RepositoryStore
    let entries: [ChangeEntry]
    let requestDiscard: ([ChangeEntry]) -> Void
    let requestConflictResolution: ([ChangeEntry], ConflictResolutionSide) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("\(entries.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Look.shared.secondary)

            Spacer()

            if !entries.conflicted.isEmpty {
                Menu {
                    Button(role: .destructive) {
                        requestConflictResolution(entries, .ours)
                    } label: {
                        Label("Use Ours…", systemImage: "arrow.left")
                    }

                    Button(role: .destructive) {
                        requestConflictResolution(entries, .theirs)
                    } label: {
                        Label("Use Theirs…", systemImage: "arrow.right")
                    }

                    Divider()

                    Button {
                        store.markConflictsResolved(entries)
                    } label: {
                        Label("Mark Resolved", systemImage: "checkmark.circle")
                    }
                } label: {
                    Label("Resolve", systemImage: "checkmark.shield")
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 11.5))
                .fixedSize()
                .help("Resolve the selected conflicts")
                .disabled(store.isLoading)
            }

            if !entries.unstagedSide.isEmpty {
                Button {
                    store.stage(entries)
                } label: {
                    Label("Stage", systemImage: "plus")
                }
                .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
                .font(.system(size: 11.5))
                .help("Stage \(ChangeActionTitle.fileCount(entries.unstagedSide.count))")
                .disabled(store.isLoading)
            }

            if !entries.stagedSide.isEmpty {
                Button {
                    store.unstage(entries)
                } label: {
                    Label("Unstage", systemImage: "minus")
                }
                .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
                .font(.system(size: 11.5))
                .help("Unstage \(ChangeActionTitle.fileCount(entries.stagedSide.count))")
                .disabled(store.isLoading)
            }

            if !entries.unstagedSide.isEmpty {
                Button(role: .destructive) {
                    requestDiscard(entries)
                } label: {
                    Label("Discard…", systemImage: "trash")
                }
                .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
                .font(.system(size: 11.5))
                .foregroundStyle(GitForkTheme.red)
                .help(
                    "Permanently discard the working-tree changes in "
                        + ChangeActionTitle.fileCount(entries.unstagedSide.count)
                        + " after confirmation"
                )
                .disabled(store.isLoading)
            }

            Button {
                store.clearChangeSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Look.shared.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(GitForkHoverButtonStyle(.icon))
            .help("Clear the selection")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(Look.shared.hover)
    }
}

/// A section's name and count, with what it can do for all its files.
private struct ChangeSectionHeader: View {
    let title: String
    let count: Int
    /// The title's color, when it is not the usual gray.
    let tint: Color?
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        let look = Look.shared
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? look.secondary)
            Text("\(count)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(look.faint)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(GitForkHoverButtonStyle(.text))
                    .foregroundStyle(look.accent)
                    .help(actionTitle)
                    .disabled(count == 0)
            }
        }
        .textCase(nil)
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.top, 6)
        .padding(.bottom, 2)
        // A row, not a section header: those float over the list on a
        // background of their own.
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// A folder line in the change tree. Click to fold or unfold it.
private struct ChangeFolderRow: View {
    let name: String
    let depth: Int
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Look.shared.faint)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
                Image(systemName: "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Look.shared.secondary)
                Text(name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Look.shared.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(1)
                Text("\(count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Look.shared.faint)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GitForkHoverButtonStyle(.compactRow(isSelected: false)))
        .padding(.leading, CGFloat(depth) * ChangeRow.indentStep)
        .help(isCollapsed ? "Show the files in \(name)" : "Hide the files in \(name)")
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct ChangeRow: View {
    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.openChange) private var openChange
    static let indentStep: CGFloat = 12
    let entry: ChangeEntry
    /// The file name shown in the tree. The full path stays in the tooltip.
    let displayName: String
    let depth: Int
    let requestDiscard: ([ChangeEntry]) -> Void
    let requestConflictResolution: ([ChangeEntry], ConflictResolutionSide) -> Void
    let focusList: () -> Void

    @State private var hovered = false

    private var change: WorkingChange { entry.change }
    private var staged: Bool { entry.staged }
    private var isSelected: Bool { store.isSelected(entry) }

    /// A menu opened on a selected row acts on the whole selection; one opened
    /// on an unselected row acts on that row alone.
    private var actionTargets: [ChangeEntry] {
        isSelected ? store.selectedChangeEntries : [entry]
    }

    var body: some View {
        let statusSymbol = change.statusSymbol(staged: staged)
        let deleted = statusSymbol == "D"
        let look = Look.shared
        Button(action: handleClick) {
            HStack(spacing: 6) {
                Text(statusSymbol)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.statusColor(statusSymbol))
                    .frame(width: 12)

                Text(displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(deleted ? look.secondary : look.text)
                    .strikethrough(deleted, color: look.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                HStack(spacing: 0) {
                    if change.isConflicted {
                        Menu {
                            Button(role: .destructive) {
                                requestConflictResolution(actionTargets, .ours)
                            } label: {
                                Label("Use Ours…", systemImage: "arrow.left")
                            }

                            Button(role: .destructive) {
                                requestConflictResolution(actionTargets, .theirs)
                            } label: {
                                Label("Use Theirs…", systemImage: "arrow.right")
                            }

                            Divider()

                            Button {
                                store.markConflictsResolved(actionTargets)
                            } label: {
                                Label("Mark Resolved", systemImage: "checkmark.circle")
                            }
                        } label: {
                            rowIcon("checkmark.shield")
                        }
                        .menuStyle(.button)
                        .buttonStyle(GitForkHoverButtonStyle(.icon))
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Resolve this conflict")
                        .disabled(store.isLoading)
                    }
                    if let openChange {
                        Button {
                            openChange(entry.id)
                        } label: {
                            rowIcon("arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(GitForkHoverButtonStyle(.icon))
                        .help("Show its diff in the git tab (or double-click the file)")
                    }
                    if !change.isConflicted {
                        Button {
                            staged ? store.unstage(change) : store.stage(change)
                        } label: {
                            rowIcon(staged ? "minus" : "plus")
                        }
                        .buttonStyle(GitForkHoverButtonStyle(.icon))
                        .help(staged ? "Unstage (⌫)" : "Stage (↩)")
                        .disabled(store.isLoading)
                    }
                }
                // They keep their room while hidden, so the name does not jump.
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
            .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .buttonStyle(GitForkHoverButtonStyle(.compactRow(isSelected: isSelected)))
        .help(
            "View \(change.isConflicted ? "conflict" : staged ? "staged" : "working tree") diff for \(change.path)"
                + (change.isConflicted ? "" : " · Space for side by side")
                + (change.isConflicted ? " · Return to mark resolved" : "")
                + " · Shift-click for a range, Command-click to add or remove"
        )
        .contextMenu {
            ChangeActionsMenu(
                entries: actionTargets,
                requestDiscard: requestDiscard,
                requestConflictResolution: requestConflictResolution
            )
        }
        .padding(.leading, CGFloat(depth) * Self.indentStep)
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(SystemSelectionHighlightRemover())
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Look.shared.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }

    /// Standard macOS list behavior: Shift extends from the anchor, Command
    /// toggles one row, a plain click replaces the selection.
    private func handleClick() {
        let modifiers = NSEvent.modifierFlags
        if let openChange, NSApp.currentEvent?.clickCount == 2, modifiers.isDisjoint(with: [.shift, .command]) {
            openChange(entry.id)
            return
        }
        if modifiers.contains(.shift) {
            store.extendSelection(to: entry)
        } else if modifiers.contains(.command) {
            store.toggleSelection(of: entry)
        } else {
            store.selectChange(change, staged: staged)
        }
        // The full-row button otherwise keeps keyboard focus, preventing the
        // enclosing List from handling arrows, Return, Space, and Delete.
        focusList()
    }
}

private struct ChangeActionsMenu: View {
    @EnvironmentObject private var store: RepositoryStore
    let entries: [ChangeEntry]
    let requestDiscard: ([ChangeEntry]) -> Void
    let requestConflictResolution: ([ChangeEntry], ConflictResolutionSide) -> Void

    var body: some View {
        let stageable = entries.unstagedSide
        let unstageable = entries.stagedSide
        let conflicts = entries.conflicted

        if !conflicts.isEmpty {
            Button(role: .destructive) {
                requestConflictResolution(conflicts, .ours)
            } label: {
                Label("Use Ours…", systemImage: "arrow.left")
            }

            Button(role: .destructive) {
                requestConflictResolution(conflicts, .theirs)
            } label: {
                Label("Use Theirs…", systemImage: "arrow.right")
            }

            Button {
                store.markConflictsResolved(conflicts)
            } label: {
                Label("Mark Resolved", systemImage: "checkmark.circle")
            }
            .disabled(store.isLoading)

            if !stageable.isEmpty || !unstageable.isEmpty {
                Divider()
            }
        }

        if !stageable.isEmpty {
            Button {
                store.stage(entries)
            } label: {
                Label(ChangeActionTitle.stage(stageable.count), systemImage: "plus")
            }
            .disabled(store.isLoading)
        }

        if !unstageable.isEmpty {
            Button {
                store.unstage(entries)
            } label: {
                Label(ChangeActionTitle.unstage(unstageable.count), systemImage: "minus")
            }
            .disabled(store.isLoading)
        }

        if !stageable.isEmpty {
            Divider()

            Button(role: .destructive) {
                requestDiscard(entries)
            } label: {
                Label(ChangeActionTitle.discard(stageable.count), systemImage: "trash")
            }
            .disabled(store.isLoading)
        }
    }
}

private enum ChangeActionTitle {
    static func fileCount(_ count: Int) -> String {
        "\(count) file\(count == 1 ? "" : "s")"
    }

    static func stage(_ count: Int) -> String {
        count == 1 ? "Stage File" : "Stage \(count) Files"
    }

    static func unstage(_ count: Int) -> String {
        count == 1 ? "Unstage File" : "Unstage \(count) Files"
    }

    static func discard(_ count: Int) -> String {
        count == 1 ? "Discard Changes…" : "Discard Changes in \(count) Files…"
    }
}

private struct ConflictResolutionRequest {
    let entries: [ChangeEntry]
    let side: ConflictResolutionSide
}

private enum ConflictResolutionPrompt {
    static func title(for request: ConflictResolutionRequest?) -> String {
        guard let request else { return "Resolve Conflicts?" }
        return request.entries.count == 1
            ? "Use \(request.side.title) for This File?"
            : "Use \(request.side.title) for \(request.entries.count) Files?"
    }

    static func actionTitle(for request: ConflictResolutionRequest?) -> String {
        request.map { "Use \($0.side.title)" } ?? "Resolve"
    }

    static func message(for request: ConflictResolutionRequest?) -> String {
        guard let request else { return "" }
        let subject = request.entries.count == 1
            ? request.entries[0].change.path
            : "the selected \(request.entries.count) conflicted files"
        return "This replaces the current working-tree contents of \(subject) "
            + "with Git’s \(request.side.title.lowercased()) version and marks "
            + "the conflict resolved. Any manual edits in those files will be lost."
    }
}

/// Confirmation copy for discarding working-tree changes. Untracked files are
/// deleted rather than reverted, so the prompt names them separately.
private enum DiscardPrompt {
    static func title(for entries: [ChangeEntry]) -> String {
        entries.count == 1
            ? "Discard All Changes in This File?"
            : "Discard Changes in \(entries.count) Files?"
    }

    static func message(for entries: [ChangeEntry]) -> String {
        let untracked = entries.filter(\.change.isUntracked).count
        if entries.count == 1, let only = entries.first {
            return only.change.isUntracked
                ? "\(only.change.path) is untracked and will be permanently deleted. "
                    + "This cannot be undone."
                : "All unstaged changes in \(only.change.path) will be permanently discarded. "
                    + "This cannot be undone."
        }

        var message = "All unstaged changes in \(entries.count) files will be "
            + "permanently discarded."
        if untracked > 0 {
            message += " \(untracked) untracked file\(untracked == 1 ? " is" : "s are") "
                + "among them and will be permanently deleted."
        }
        return message + " This cannot be undone."
    }
}

private struct CommitSheet: View {
    @EnvironmentObject private var store: RepositoryStore
    @Binding var isPresented: Bool
    @State private var isConfirmingAmend = false
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Commit")
                    .font(.headline)
                Text(stagedSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(Look.shared.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Toggle("Sign", isOn: $store.signCommit)
                    .toggleStyle(.checkbox)
                    .help("Sign commits with the configured OpenPGP key")

                Toggle("Amend", isOn: $store.amend)
                    .toggleStyle(.checkbox)
                    .help("Replace the latest commit")
                    .disabled(store.isLoading)
            }

            TextEditor(text: $store.commitMessage)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .focused($isMessageFocused)
                .frame(minHeight: 170)
                .padding(7)
                .background(Look.shared.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Look.shared.divider)
                )
                .overlay(alignment: .topLeading) {
                    if store.commitMessage.isEmpty {
                        Text("Commit message")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .help("Close without committing; the message is kept")

                Button {
                    if store.amend {
                        isConfirmingAmend = true
                    } else {
                        commit()
                    }
                } label: {
                    Text(commitButtonTitle)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help(commitButtonHelp)
                .disabled(
                    (!store.amend && store.stagedChanges.isEmpty)
                        || store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.isLoading
                )
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { isMessageFocused = true }
        .alert("Amend the Latest Commit?", isPresented: $isConfirmingAmend) {
            Button("Cancel", role: .cancel) {}
            Button("Amend Commit", role: .destructive) {
                commit()
            }
        } message: {
            Text(
                "This replaces the latest commit and rewrites local history. "
                    + "If that commit was already pushed, the remote will no longer match."
            )
        }
    }

    private func commit() {
        store.createCommit()
        isPresented = false
    }

    private var stagedSummary: String {
        let count = store.stagedChanges.count
        return "\(count) staged file\(count == 1 ? "" : "s") on \(store.branch)"
    }

    private var commitButtonTitle: String {
        if store.amend {
            return store.signCommit ? "Amend & Sign" : "Amend Commit"
        }
        return store.signCommit ? "Sign & Commit" : "Commit"
    }

    private var commitButtonHelp: String {
        if store.signCommit {
            return store.amend
                ? "Replace and OpenPGP-sign the latest commit"
                : "Create an OpenPGP-signed commit using Git's configured key"
        }
        return store.amend ? "Replace the latest commit" : "Commit the staged changes"
    }
}

private struct OpenChangeKey: EnvironmentKey {
    static var defaultValue: ((ChangeEntryID) -> Void)? { nil }
}

extension EnvironmentValues {
    /// What a double-click on a changed file does: the Changes panel opens
    /// the file in the git tab. Nil does nothing more than a click.
    var openChange: ((ChangeEntryID) -> Void)? {
        get { self[OpenChangeKey.self] }
        set { self[OpenChangeKey.self] = newValue }
    }
}

import AgentzCore
import AppKit
import SwiftUI

/// The menu of a commit in the history: branches and checkout, applying it
/// elsewhere, and rewriting the current branch from it.
struct CommitMenu: View {
    @EnvironmentObject private var store: RepositoryStore
    let commit: GitCommit

    var body: some View {
        // Unknown (HEAD isn't loaded) counts as yes: git checks again.
        let inHistory = store.isInCurrentHistory(commit) != false
        let isHead = store.isHead(commit)
        let busy = store.isLoading || store.operation != nil
        let head = store.headName
        // Rewriting from a merge would flatten it.
        let canRewrite = inHistory && !busy && commit.parents.count <= 1

        Button("Copy Hash") {
            store.copyHash(commit)
        }

        Divider()

        Button("New Branch Here…") {
            store.showNewBranchSheet(at: commit, checkout: false)
        }
        .disabled(store.isLoading)
        Button("New Branch Here and Check Out…") {
            store.showNewBranchSheet(at: commit, checkout: true)
        }
        .disabled(busy)
        Button("Check Out This Commit") {
            store.checkout(commit)
        }
        .disabled(busy || isHead)

        Divider()

        Button("Cherry-Pick onto “\(head)”") {
            store.cherryPick(commit)
        }
        .disabled(busy || store.isInCurrentHistory(commit) == true)
        Button("Revert Commit") {
            store.revert(commit)
        }
        .disabled(busy)
        Menu("Reset “\(head)” to Here") {
            ForEach(GitResetMode.allCases, id: \.self) { mode in
                Button(mode.title) {
                    store.reset(to: commit, mode: mode)
                }
            }
        }
        .disabled(busy || isHead)

        Divider()

        Button("Edit Message…") {
            store.showReword(commit)
        }
        .disabled(!canRewrite)
        Button("Squash into Parent") {
            store.fold(commit, keepingMessage: true)
        }
        .disabled(!canRewrite || commit.parents.isEmpty)
        Button("Fixup into Parent") {
            store.fold(commit, keepingMessage: false)
        }
        .disabled(!canRewrite || commit.parents.isEmpty)
        Button("Interactive Rebase from Here…") {
            store.showInteractiveRebase(from: commit)
        }
        .disabled(!inHistory || busy)

        Divider()

        Button("Delete Commit…", role: .destructive) {
            store.delete(commit)
        }
        .disabled(!canRewrite)
    }
}

/// The branch menu's items that act on the current branch with another
/// one, and the one that opens the branch in a worktree.
struct BranchActionItems: View {
    @EnvironmentObject private var store: RepositoryStore
    let reference: GitReference

    var body: some View {
        let busy = store.isLoading || store.operation != nil
        let head = store.headName

        if !reference.isCurrent {
            Divider()
            Button("Merge “\(reference.name)” into “\(head)”") {
                store.merge(reference)
            }
            .disabled(busy)
            Button("Rebase “\(head)” onto “\(reference.name)”") {
                store.rebase(onto: reference)
            }
            .disabled(busy)
            Button("Interactive Rebase “\(head)” onto “\(reference.name)”…") {
                store.showInteractiveRebase(onto: reference)
            }
            .disabled(busy)
            Menu("Reset “\(head)” to Here") {
                ForEach(GitResetMode.allCases, id: \.self) { mode in
                    Button(mode.title) {
                        store.reset(to: reference, mode: mode)
                    }
                }
            }
            .disabled(busy)
        }

        if reference.kind != .tag && !reference.isCurrent {
            Divider()
            let existing = store.worktree(holding: reference)
            Menu(existing == nil ? "New Worktree" : "Open Its Worktree") {
                ForEach([Agent.claude, .codex, .shell, .git], id: \.self) { agent in
                    Button(Self.title(of: agent)) {
                        store.newWorktree(for: reference, agent: agent)
                    }
                }
            }
            .disabled(store.isLoading)
        }
    }

    private static func title(of agent: Agent) -> String {
        switch agent {
        case .shell, .git: agent.displayName
        default: "\(agent.displayName) Session"
        }
    }
}

/// Shows while a rebase, merge, cherry-pick or revert waits, mostly on a
/// conflict, with the ways on.
struct GitOperationBar: View {
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        if let operation = store.operation {
            let look = Look.shared
            let conflicts = store.conflictedChanges.count
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(GitForkTheme.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("The \(operation.noun) stopped")
                            .font(.system(size: 12, weight: .medium))
                        Text(detail(conflicts: conflicts))
                            .font(.system(size: 11))
                            .foregroundStyle(look.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button("Abort") {
                        store.abortOperation()
                    }
                    .buttonStyle(GitForkHoverButtonStyle(.text))
                    .help("Stop the \(operation.noun) and go back to how things were before it")
                    if operation.canSkip {
                        Button("Skip") {
                            store.skipOperation()
                        }
                        .buttonStyle(GitForkHoverButtonStyle(.text))
                        .help("Leave out the commit it stopped at and go on")
                    }
                    Button("Continue") {
                        store.continueOperation()
                    }
                    .buttonStyle(GitPrimaryButtonStyle())
                    .disabled(conflicts > 0)
                    .help(conflicts > 0 ? "Resolve the conflicts first" : "Go on with the \(operation.noun)")
                }
                .font(.system(size: 12))
                .disabled(store.isLoading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                Rectangle().fill(look.divider).frame(height: 1)
            }
        }
    }

    private func detail(conflicts: Int) -> String {
        if conflicts > 0 {
            return "\(conflicts) file\(conflicts == 1 ? " has" : "s have") conflicts. Resolve them in Changes, then continue."
        }
        return "Nothing is in conflict. Continue, or see why it stopped in the git command log."
    }
}

/// Git's interactive rebase as a list: each commit picked, reworded,
/// folded into the one before it, or dropped, in the order dragged.
struct RebaseSheet: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var plan: RebasePlan
    let close: () -> Void

    init(plan: RebasePlan, close: @escaping () -> Void) {
        _plan = State(initialValue: plan)
        self.close = close
    }

    var body: some View {
        let look = Look.shared
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Interactive Rebase")
                    .font(.headline)
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(look.secondary)
            }

            if plan.steps.isEmpty {
                GitPlaceholder("No commits to move: \(store.headName) has nothing that isn’t there already.")
                    .frame(height: 120)
            } else {
                List {
                    ForEach($plan.steps) { $step in
                        RebaseStepRow(step: $step)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { plan.steps.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .lookListBackground(look.fieldBackground)
                .frame(minHeight: 220, idealHeight: CGFloat(min(plan.steps.count, 12)) * 34 + 16, maxHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(look.divider))
            }

            if let warning = plan.warning {
                Text(warning)
                    .font(.system(size: 12))
                    .foregroundStyle(GitForkTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = plan.problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(GitForkTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Uncommitted changes are put away first and come back after.")
                    .font(.system(size: 11))
                    .foregroundStyle(look.faint)
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Rewrite") {
                    store.runRebase(plan)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private var canRun: Bool {
        !plan.steps.isEmpty && plan.problem == nil && (plan.changesSomething || plan.movesOntoBranch)
            && !store.isLoading
    }

    private var summary: String {
        let count = plan.steps.count
        return "\(count) commit\(count == 1 ? "" : "s") of \(store.headName), \(plan.baseTitle). "
            + "Newest first; drag a commit to move it."
    }
}

private struct RebaseStepRow: View {
    @Binding var step: RebaseStep

    var body: some View {
        let look = Look.shared
        let dropped = step.action == .drop
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Picker("Action", selection: $step.action) {
                ForEach(RebaseAction.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 92)
            .help(step.action.help)

            Text(step.commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(look.faint)

            VStack(alignment: .leading, spacing: 4) {
                if step.action == .reword {
                    TextField("Message", text: $step.message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .lineLimit(1...6)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Look.shared.sidebar, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(step.commit.subject)
                        .font(.system(size: 12.5))
                        .strikethrough(dropped)
                        .foregroundStyle(dropped ? look.faint : step.action.foldsIntoPrevious ? look.secondary : look.text)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(step.commit.authorName)
                .font(.system(size: 11))
                .foregroundStyle(look.faint)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

/// Edits a commit's message.
struct RewordSheet: View {
    @EnvironmentObject private var store: RepositoryStore
    let request: RewordRequest
    let close: () -> Void
    @State private var message: String
    @FocusState private var isFocused: Bool

    init(request: RewordRequest, close: @escaping () -> Void) {
        self.request = request
        self.close = close
        _message = State(initialValue: request.message)
    }

    var body: some View {
        let look = Look.shared
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edit Message")
                    .font(.headline)
                Text(request.commit.shortHash)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(look.secondary)
            }

            TextEditor(text: $message)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 170)
                .padding(7)
                .background(look.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(look.divider))

            HStack {
                if !store.isHead(request.commit) {
                    Text("The commits after it are rewritten too.")
                        .font(.system(size: 11))
                        .foregroundStyle(look.faint)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Change Message") {
                    store.reword(request.commit, message: message)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { isFocused = true }
    }

    private var canSave: Bool {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean != request.message && !store.isLoading
    }
}

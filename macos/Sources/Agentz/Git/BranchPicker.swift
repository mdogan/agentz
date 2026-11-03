import AppKit
import SwiftUI

enum BranchPickerSearch {
    static func filter(
        _ references: [GitReference],
        query: String
    ) -> [GitReference] {
        let branches = references.filter {
            $0.kind == .localBranch || $0.kind == .remoteBranch
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return branches }

        return branches.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }
}

enum BranchPickerNavigation {
    static func reconcile(
        selection: GitReference?,
        branches: [GitReference],
        preferredBranch: GitReference?
    ) -> GitReference? {
        if let selection,
           let branch = branches.first(where: { $0.fullName == selection.fullName }) {
            return branch
        }
        if let preferredBranch,
           let branch = branches.first(where: { $0.fullName == preferredBranch.fullName }) {
            return branch
        }
        return branches.first(where: { $0.isCurrent }) ?? branches.first
    }

    static func move(
        selection: GitReference?,
        offset: Int,
        branches: [GitReference]
    ) -> GitReference? {
        guard !branches.isEmpty else { return nil }
        guard let selection,
              let index = branches.firstIndex(where: {
                  $0.fullName == selection.fullName
              }) else {
            return offset < 0 ? branches.last : branches.first
        }

        let count = branches.count
        let nextIndex = (index + offset % count + count) % count
        return branches[nextIndex]
    }
}

/// Picks a branch to switch to. Where commits can be shown, it can also
/// show the picked branch's commits instead.
struct BranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RepositoryStore
    let showsCommits: Bool
    /// It acted and closes: Return can reach both the field and the button.
    @State private var isDone = false
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var selectedBranch: GitReference?
    /// The branch a new one starts at, while the sheet that names it shows.
    @State private var newBranchStart: GitReference?

    private var branches: [GitReference] {
        BranchPickerSearch.filter(store.references, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switch Branch")
                            .font(.headline)
                        Text("Pick a local or remote branch to switch to.")
                            .font(.system(size: 12))
                            .foregroundStyle(Look.shared.secondary)
                    }
                }

                TextField("Search branches", text: $searchText)
                    .focused($isSearchFocused)
                    .onSubmit {
                        switchToSelectedBranch()
                    }
                    .onKeyPress(
                        keys: [.escape, .upArrow, .downArrow]
                    ) { press in
                        if press.key == .escape {
                            dismiss()
                        } else if press.key == .upArrow {
                            moveSelection(by: -1)
                        } else {
                            moveSelection(by: 1)
                        }
                        return .handled
                    }
                    .lookField(isFocused: isSearchFocused, systemImage: "magnifyingglass")
            }
            .padding(20)

            Divider()

            Group {
                if branches.isEmpty {
                    GitPlaceholder(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "This repository has no branches to choose from."
                            : "No branch name contains “\(searchText)”."
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(branches) { branch in
                                    let isSelected = selectedBranch?.fullName == branch.fullName

                                    Button {
                                        selectedBranch = branch
                                        if NSApp.currentEvent?.clickCount == 2 {
                                            switchToSelectedBranch()
                                        }
                                    } label: {
                                        BranchPickerRow(
                                            branch: branch,
                                            isSelected: isSelected
                                        )
                                    }
                                    .buttonStyle(
                                        GitForkHoverButtonStyle(
                                            .row(isSelected: isSelected)
                                        )
                                    )
                                    .help("Double-click to switch to \(branch.name)")
                                    .accessibilityAddTraits(
                                        isSelected ? .isSelected : []
                                    )
                                    .id(branch.fullName)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: selectedBranch) { _, branch in
                            guard let branch else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(branch.fullName)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Button("New Branch…") {
                    newBranchStart = selectedBranch
                }
                .help(selectedBranch.map { "Create a branch that starts at \($0.name)" } ?? "Pick a branch to start from")
                .disabled(selectedBranch == nil || store.isLoading)

                Spacer()

                HStack(spacing: 10) {
                    Text("↑↓ Navigate")
                    if showsCommits {
                        Text("⌘↩ Commits")
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if showsCommits {
                    Button("Show Commits") {
                        showSelectedBranch()
                    }
                    .help("Show the commits of the picked branch, without switching to it (⌘↩)")
                    .disabled(selectedBranch == nil)
                    // A button with this key looks like the main one, so a
                    // hidden one has it: Switch is the main one.
                    .background {
                        Button("", action: showSelectedBranch)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(selectedBranch == nil)
                            .opacity(0)
                    }
                }

                Button("Switch") {
                    switchToSelectedBranch()
                }
                .keyboardShortcut(.defaultAction)
                .help(
                    selectedBranch?.isCurrent == true
                        ? "This is the current branch"
                        : "Switch to the picked branch"
                )
                .disabled(selectedBranch == nil || selectedBranch?.isCurrent == true)
            }
            .padding(16)
        }
        .frame(width: 600, height: 420)
        .sheet(item: $newBranchStart) { start in
            BranchSheet(
                start: start,
                isPresented: Binding(
                    get: { newBranchStart != nil },
                    set: { if !$0 { newBranchStart = nil } }
                ),
                onCreate: {
                    isDone = true
                    dismiss()
                }
            )
            .environmentObject(store)
            .lookWindowStyle()
        }
        .onAppear {
            reconcileSelection()
            isSearchFocused = true
        }
        .onChange(of: searchText) {
            reconcileSelection()
        }
        .onChange(of: store.references) {
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        selectedBranch = BranchPickerNavigation.reconcile(
            selection: selectedBranch,
            branches: branches,
            preferredBranch: store.selectedReference
        )
    }

    private func moveSelection(by offset: Int) {
        selectedBranch = BranchPickerNavigation.move(
            selection: selectedBranch,
            offset: offset,
            branches: branches
        )
    }

    private func showSelectedBranch() {
        guard let selectedBranch, !isDone else { return }
        isDone = true
        dismiss()
        store.selectReference(selectedBranch)
    }

    /// On the current branch there is nothing to do, so it only closes.
    private func switchToSelectedBranch() {
        guard let selectedBranch, !isDone else { return }
        isDone = true
        dismiss()
        store.checkout(selectedBranch)
    }
}

private struct BranchPickerRow: View {
    let branch: GitReference
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: branch.kind.icon)
                .font(.system(size: 12))
                .foregroundStyle(branch.isCurrent ? GitForkTheme.accent : Look.shared.secondary)
                .frame(width: 16)

            Text(branch.name)
                .font(.system(size: 12.5, weight: branch.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(branch.kind == .localBranch ? "Local" : "Remote")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if branch.isCurrent {
                Text("Current")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GitForkTheme.accent)
            }

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11))
                    .foregroundStyle(GitForkTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

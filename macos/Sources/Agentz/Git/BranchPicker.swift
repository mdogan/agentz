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

struct BranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RepositoryStore
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var selectedBranch: GitReference?

    private var branches: [GitReference] {
        BranchPickerSearch.filter(store.references, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title2)
                        .foregroundStyle(GitForkTheme.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Select Branch")
                            .font(.title2.weight(.semibold))
                        Text("Choose a local or remote branch to see its commits.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Search branches", text: $searchText)
                    .focused($isSearchFocused)
                    .onSubmit {
                        showSelectedBranch()
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
                    ContentUnavailableView(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No Branches"
                            : "No Matching Branches",
                        systemImage: "arrow.triangle.branch",
                        description: Text(
                            searchText.isEmpty
                                ? "This repository has no branches to choose from."
                                : "No branch name contains “\(searchText)”."
                        )
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(branches) { branch in
                                    let isSelected = selectedBranch?.fullName == branch.fullName

                                    Button {
                                        show(branch)
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
                                    .help("Show commits on \(branch.name)")
                                    .accessibilityAddTraits(
                                        isSelected ? .isSelected : []
                                    )
                                    .id(branch.fullName)
                                }
                            }
                            .padding(12)
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
                Spacer()

                HStack(spacing: 12) {
                    Text("↑↓ Navigate")
                    Text("↩ Show Commits")
                    Text("esc Close")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Show Commits") {
                    showSelectedBranch()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBranch == nil)
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
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
        guard let selectedBranch else { return }
        show(selectedBranch)
    }

    private func show(_ branch: GitReference) {
        dismiss()
        store.selectReference(branch)
    }
}

private struct BranchPickerRow: View {
    let branch: GitReference
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : branch.kind.icon)
                .font(.title3)
                .foregroundStyle(branch.isCurrent ? GitForkTheme.green : GitForkTheme.accent)
                .frame(width: 24)

            Text(branch.name)
                .font(.body.weight(branch.isCurrent ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(branch.kind == .localBranch ? "Local" : "Remote")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if branch.isCurrent {
                Text("Current")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(GitForkTheme.green)
            }

            if isSelected {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(GitForkTheme.accent)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

import Foundation
import SwiftUI

enum CommitHashQuery {
    static let minimumLength = 4
    static let maximumLength = 64

    /// Accepts what Git accepts as an object name: an abbreviated or full
    /// hexadecimal hash, in either case.
    static func normalized(_ input: String) -> String? {
        let trimmed = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard trimmed.count >= minimumLength,
              trimmed.count <= maximumLength,
              trimmed.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        return trimmed
    }
}

enum CommitHashPickerSearch {
    static let matchLimit = 25

    /// Loaded commits whose hash starts with the query, so a prefix the user
    /// half-remembers still shows what it points at.
    static func matches(
        _ commits: [GitCommit],
        query: String,
        limit: Int = matchLimit
    ) -> [GitCommit] {
        let query = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return Array(commits.prefix(limit)) }
        guard query.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return [] }
        return Array(
            commits
                .filter { $0.hash.lowercased().hasPrefix(query) }
                .prefix(limit)
        )
    }
}

enum CommitHashPickerNavigation {
    static func reconcile(
        selection: GitCommit?,
        commits: [GitCommit]
    ) -> GitCommit? {
        if let selection, commits.contains(where: { $0.hash == selection.hash }) {
            return selection
        }
        return commits.first
    }

    static func move(
        selection: GitCommit?,
        offset: Int,
        commits: [GitCommit]
    ) -> GitCommit? {
        guard !commits.isEmpty else { return nil }
        guard let selection,
              let index = commits.firstIndex(where: { $0.hash == selection.hash }) else {
            return offset < 0 ? commits.last : commits.first
        }

        let count = commits.count
        let nextIndex = (index + offset % count + count) % count
        return commits[nextIndex]
    }
}

/// What the repository knows about a hash that none of the loaded commits
/// match — an older commit, an unreachable one, or nothing at all.
enum CommitHashLookup {
    case idle
    case searching
    case found(GitCommit)
    case missing(String)
}

struct CommitHashPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RepositoryStore
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var selectedCommit: GitCommit?
    @State private var lookup: CommitHashLookup = .idle

    private var commits: [GitCommit] {
        CommitHashPickerSearch.matches(store.commits, query: searchText)
    }

    private var typedHash: String? {
        CommitHashQuery.normalized(searchText)
    }

    /// The hash Return opens: the highlighted row, the commit the repository
    /// lookup turned up, or the hash as typed while that lookup runs.
    private var openTarget: String? {
        if let selectedCommit {
            return selectedCommit.hash
        }
        switch lookup {
        case let .found(commit):
            return commit.hash
        case .missing:
            return nil
        case .idle, .searching:
            return typedHash
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "number.circle")
                        .font(.title2)
                        .foregroundStyle(GitForkTheme.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Commit")
                            .font(.title2.weight(.semibold))
                        Text("Enter a short or full commit hash.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Commit hash", text: $searchText)
                    .font(.body.monospaced())
                    .focused($isSearchFocused)
                    .onSubmit {
                        openSelectedCommit()
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
                if commits.isEmpty {
                    if typedHash == nil {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No Loaded Commits" : "Not a Commit Hash",
                            systemImage: searchText.isEmpty ? "clock" : "number",
                            description: Text(emptyDescription)
                        )
                    } else {
                        lookupResult
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(commits) { commit in
                                    let isSelected = selectedCommit?.hash == commit.hash

                                    Button {
                                        open(hash: commit.hash)
                                    } label: {
                                        CommitHashPickerRow(
                                            commit: commit,
                                            isSelected: isSelected
                                        )
                                    }
                                    .buttonStyle(
                                        GitForkHoverButtonStyle(
                                            .row(isSelected: isSelected)
                                        )
                                    )
                                    .help("Open \(commit.shortHash) — \(commit.subject)")
                                    .accessibilityAddTraits(
                                        isSelected ? .isSelected : []
                                    )
                                    .id(commit.id)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: selectedCommit) { _, commit in
                            guard let commit else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(commit.id)
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
                    Text("↩ Open")
                    Text("esc Close")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Open Commit") {
                    openSelectedCommit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(openTarget == nil)
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
        .onChange(of: store.commits) {
            reconcileSelection()
        }
        .task(id: searchText) {
            await lookUpTypedHash()
        }
    }

    /// Answers the question the loaded list cannot: does this hash exist in the
    /// repository at all?
    @ViewBuilder
    private var lookupResult: some View {
        switch lookup {
        case .idle, .searching:
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking up \(typedHash ?? searchText)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .found(commit):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        open(hash: commit.hash)
                    } label: {
                        CommitHashPickerRow(commit: commit, isSelected: true)
                    }
                    .buttonStyle(GitForkHoverButtonStyle(.row(isSelected: true)))
                    .help("Open \(commit.shortHash) — \(commit.subject)")

                    Label(
                        """
                        Older than the loaded history. Opening it shows this \
                        commit and its ancestors.
                        """,
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(12)
            }
        case let .missing(message):
            ContentUnavailableView(
                "No Matching Commit",
                systemImage: "questionmark.circle",
                description: Text(message)
            )
        }
    }

    private var emptyDescription: String {
        if searchText.isEmpty {
            return "This repository has no loaded commits to choose from."
        }
        return """
        Type at least \(CommitHashQuery.minimumLength) hexadecimal characters \
        of a commit hash.
        """
    }

    /// Looks a typed hash up in the repository once the loaded list runs out of
    /// matches, after a short pause so a hash being typed is not searched
    /// character by character.
    private func lookUpTypedHash() async {
        guard commits.isEmpty, let typedHash else {
            lookup = .idle
            return
        }

        lookup = .searching
        do {
            try await Task.sleep(for: .milliseconds(200))
            lookup = .found(try await store.lookUpCommit(hash: typedHash))
        } catch is CancellationError {
            // A newer query superseded this lookup.
        } catch {
            lookup = .missing(error.localizedDescription)
        }
    }

    private func reconcileSelection() {
        selectedCommit = CommitHashPickerNavigation.reconcile(
            selection: selectedCommit,
            commits: commits
        )
    }

    private func moveSelection(by offset: Int) {
        selectedCommit = CommitHashPickerNavigation.move(
            selection: selectedCommit,
            offset: offset,
            commits: commits
        )
    }

    private func openSelectedCommit() {
        guard let openTarget else { return }
        open(hash: openTarget)
    }

    private func open(hash: String) {
        dismiss()
        store.openCommit(hash: hash)
    }
}

private struct CommitHashPickerRow: View {
    let commit: GitCommit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(commit.shortHash)
                .font(.body.monospaced())
                .foregroundStyle(GitForkTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(commit.authorName)
                    Text("·")
                    Text(commit.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

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

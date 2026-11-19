import AgentzCore
import AppKit
import SwiftUI

struct HistoryView: View {
    @Environment(\.compactGitDetail) private var openDetail
    @EnvironmentObject private var store: RepositoryStore
    /// The pane has room for the branches next to the history.
    let canShowReferences: Bool

    var body: some View {
        let commits = store.filteredCommits
        let showsGraph = showsGraph(for: store.historyScope)
        let graph = showsGraph
            ? (store.searchText.isEmpty
                ? CommitGraphLayout(commits: commits)
                : CommitGraphLayout(
                    commits: commits,
                    connectingThrough: store.commits
                ))
            : nil
        let look = Look.shared
        let remoteBranches = Set(store.references.filter { $0.kind == .remoteBranch }.map(\.name))
        VStack(spacing: 0) {
            HistoryHeader(canShowReferences: canShowReferences)

            Rectangle().fill(look.divider).frame(height: 1)

            if commits.isEmpty {
                if store.searchingHistory { ProgressView("Searching history…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { GitPlaceholder(emptyDescription) }
            } else {
                ScrollViewReader { proxy in
                    List(selection: commitSelection) {
                        ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                            CommitRow(
                                commit: commit,
                                remoteBranches: remoteBranches,
                                graphRow: graph?.rows[index],
                                graphColumnCount: graph?.columnCount ?? 0,
                                showsGraph: showsGraph
                            )
                            .modifier(OpenDetailOnTap(openDetail: openDetail) {
                                store.selectCommit(commit)
                            })
                            .tag(commit.hash)
                            .contextMenu {
                                CommitMenu(commit: commit)
                            }
                            .listRowInsets(
                                EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                LookListRowBackground(isSelected: commit.id == store.selectedCommit?.id)
                            )
                        }

                        if store.searchText.isEmpty && (store.canLoadMoreHistory || store.isLoadingMoreHistory) {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Loading more commits…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(look.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .listRowSeparator(.hidden)
                            .onAppear {
                                store.loadMoreHistory()
                            }
                        }
                    }
                    .onKeyPress(.rightArrow) {
                        guard let openDetail, store.selectedCommit != nil else { return .ignored }
                        openDetail.wrappedValue = true
                        return .handled
                    }
                    .listStyle(.plain)
                    .lookListBackground(look.sidebar)
                    .onChange(of: store.commitReveal) { _, reveal in
                        guard let reveal else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(reveal.hash, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var commitSelection: Binding<String?> {
        Binding(
            get: { store.selectedCommit?.hash },
            set: { hash in
                if let hash, let selected = store.filteredCommits.first(where: { $0.hash == hash }) {
                    store.selectCommit(selected)
                } else if hash == nil {
                    store.selectCommit(nil)
                }
            }
        )
    }

    private var emptyDescription: String {
        if !store.searchText.isEmpty {
            return "No commits match “\(store.searchText)”."
        }
        switch store.historyScope {
        case let .path(path, _):
            return "No commits on \(store.pathHistoryReferenceName) affect “\(path)”."
        case let .commit(hash):
            return "Commit \(String(hash.prefix(8))) is no longer in this repository."
        case .lostAndDangling:
            return "No commits are unreachable from this repository’s current references."
        case .all, .revision:
            return "This repository has no commits yet."
        }
    }

    private func showsGraph(for scope: CommitHistoryScope) -> Bool {
        switch scope {
        case .path, .lostAndDangling:
            return false
        case .all, .revision, .commit:
            return true
        }
    }
}

/// In a narrow pane, a click on a commit also opens its detail. The tap
/// gesture is only attached there: on macOS any tap gesture on a `List` row,
/// even a simultaneous one, takes the click from the List and stops it from
/// selecting the row.
private struct OpenDetailOnTap: ViewModifier {
    let openDetail: Binding<Bool>?
    let select: () -> Void

    func body(content: Content) -> some View {
        if let openDetail {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    select()
                    openDetail.wrappedValue = true
                }
        } else {
            content
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit
    /// The names of the remote branches, such as `origin/main`.
    let remoteBranches: Set<String>
    let graphRow: CommitGraphRow?
    let graphColumnCount: Int
    let showsGraph: Bool

    var body: some View {
        let look = Look.shared
        HStack(spacing: 8) {
            if showsGraph {
                Color.clear
                    .frame(width: graphWidth)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(commit.subject)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .layoutPriority(1)

                    CommitSignatureBadge(signature: commit.signature, compact: true)

                    ForEach(labels.prefix(2), id: \.self) { decoration in
                        Text(shortened(cleanDecoration(decoration)))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(labelColor(decoration))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(labelColor(decoration).opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                            .help(decoration)
                    }
                }

                HStack(spacing: 4) {
                    IdentityAvatar(name: commit.authorName, initials: commit.initials, size: 13)
                    Text(commit.authorName)
                        .lineLimit(1)
                    Text("· \(age(now: Date(), commit.date))")
                        .lineLimit(1)
                        .fixedSize()
                    if commit.parents.count > 1 {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(GitForkTheme.purple)
                            .help("A merge of \(commit.parents.count) parents")
                    }
                    Spacer(minLength: 6)
                    Text(commit.shortHash)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(look.faint)
                        .fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(look.secondary)
            }
            .padding(.vertical, 5)
        }
        .overlay(alignment: .leading) {
            if showsGraph, let graphRow {
                CommitGraph(
                    row: graphRow,
                    columnCount: graphColumnCount
                )
                .frame(width: graphWidth)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .help(parentDescription)
        .accessibilityElement(children: .combine)
        .accessibilityValue(parentDescription)
    }

    private var graphWidth: CGFloat {
        min(
            max(14, CGFloat(graphColumnCount - 1) * 12 + 14),
            120
        )
    }

    private var parentDescription: String {
        guard !commit.parents.isEmpty else {
            return "Root commit · no parents"
        }
        let hashes = commit.parents
            .map { String($0.prefix(8)) }
            .joined(separator: ", ")
        let label = commit.parents.count == 1 ? "Parent" : "Parents"
        return "\(label): \(hashes)"
    }

    /// The commit's branches and tags, without a remote branch when the
    /// local branch of the same name is here too: `origin/main` and `main`
    /// show as `main`.
    private var labels: [String] {
        let names = Set(commit.decorations.map(cleanDecoration))
        return commit.decorations.filter { decoration in
            guard remoteBranches.contains(decoration),
                  let slash = decoration.firstIndex(of: "/") else { return true }
            return !names.contains(String(decoration[decoration.index(after: slash)...]))
        }
    }

    /// A long branch name, cut in the middle, so the subject keeps room.
    private func shortened(_ name: String) -> String {
        guard name.count > 18 else { return name }
        return name.prefix(8) + "…" + name.suffix(8)
    }

    private func cleanDecoration(_ value: String) -> String {
        value
            .replacingOccurrences(of: "HEAD -> ", with: "")
            .replacingOccurrences(of: "tag: ", with: "")
    }

    private func labelColor(_ value: String) -> Color {
        if value.contains("tag:") { return GitForkTheme.purple }
        if value.contains("HEAD") { return GitForkTheme.accent }
        if value.contains("/") { return GitForkTheme.blue }
        return GitForkTheme.green
    }

}

private struct CommitGraph: View {
    let row: CommitGraphRow
    let columnCount: Int

    private let colors: [Color] = [
        GitForkTheme.accent,
        GitForkTheme.purple,
        GitForkTheme.green,
        GitForkTheme.orange,
        Color(red: 0.20, green: 0.68, blue: 0.66),
        Color(red: 0.90, green: 0.42, blue: 0.68),
        Color(red: 0.42, green: 0.48, blue: 0.90),
        Color(red: 0.89, green: 0.68, blue: 0.24)
    ]

    var body: some View {
        Canvas { context, size in
            for segment in row.segments {
                let start = point(for: segment.start, in: size)
                let end = point(for: segment.end, in: size)
                var path = Path()
                path.move(to: start)

                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let middleY = (start.y + end.y) / 2
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: middleY),
                        control2: CGPoint(x: end.x, y: middleY)
                    )
                }

                context.stroke(
                    path,
                    with: .color(color(segment.color).opacity(0.82)),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            let nodePoint = point(
                for: .node(row.nodeColumn),
                in: size
            )
            let node = Path(
                ellipseIn: CGRect(
                    x: nodePoint.x - 4,
                    y: nodePoint.y - 4,
                    width: 8,
                    height: 8
                )
            )
            context.fill(node, with: .color(color(row.nodeColor)))
            context.stroke(
                node,
                with: .color(Look.shared.sidebar),
                lineWidth: 1.5
            )
        }
    }

    private func point(
        for anchor: CommitGraphAnchor,
        in size: CGSize
    ) -> CGPoint {
        let horizontalInset: CGFloat = 7
        let availableWidth = max(0, size.width - horizontalInset * 2)
        let spacing = columnCount > 1
            ? availableWidth / CGFloat(columnCount - 1)
            : 0
        let x = columnCount > 1
            ? horizontalInset + CGFloat(anchor.column) * spacing
            : size.width / 2
        let y: CGFloat
        switch anchor {
        case .top:
            y = 0
        case .node:
            y = size.height / 2
        case .bottom:
            y = size.height
        }
        return CGPoint(x: x, y: y)
    }

    private func color(_ index: Int) -> Color {
        colors[index % colors.count]
    }
}

/// The top of the history: the button that shows or hides the branches, a
/// search over the selected history, and, when the branches can't say what
/// the commits are limited to, a menu that does.
private struct HistoryHeader: View {
    @EnvironmentObject private var store: RepositoryStore
    let canShowReferences: Bool
    @AppStorage("gitReferencesShown") private var referencesShown = true
    @FocusState private var searchFocused: Bool

    /// The branches list what shows, unless it is a commit or a file's
    /// history. All branches always says so: it isn't the usual view.
    private var showsMenu: Bool {
        guard referencesShown, canShowReferences, !showsAll else { return true }
        switch store.historyScope {
        case .commit, .path: return true
        case .all, .revision, .lostAndDangling: return false
        }
    }

    var body: some View {
        let look = Look.shared
        let scope = scope
        HStack(spacing: 6) {
            ToolbarIconButton(
                "Branches",
                systemImage: "sidebar.left",
                help: !canShowReferences
                    ? "The window is too narrow for the branches"
                    : referencesShown ? "Hide the branches" : "Show the branches, remotes, tags, stashes and worktrees"
            ) {
                referencesShown.toggle()
            }
            .disabled(!canShowReferences)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(look.secondary)
                TextField(placeholder, text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { store.searchText = "" }
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(look.secondary)
                    .help("Clear the search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(look.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
            .help("Find commits by message, author, hash or branch, in the selected history")

            if showsMenu {
                PopUpButton(look: look, help: "Showing \(scope.help). Click to pick a branch.", menu: branchMenu) {
                    HStack(spacing: 4) {
                        Image(systemName: scope.icon)
                            .font(.system(size: 10))
                        Text(scope.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11, weight: showsAll ? .semibold : .medium))
                    .foregroundStyle(showsAll ? look.accent : look.text)
                    .frame(maxWidth: 150)
                }
                .fixedSize()
                if showsAll {
                    ToolbarIconButton(
                        "Current Branch",
                        systemImage: "xmark.circle.fill",
                        help: "Show only \(store.branch) again"
                    ) {
                        store.showCurrentBranch()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private var showsAll: Bool {
        store.showsAllBranches
    }

    private var placeholder: String {
        showsAll || store.showsCurrentBranch
            ? "Search history"
            : "Search"
    }

    /// The current branch, all branches, then the local ones, then the
    /// remote ones.
    private func branchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = MenuAction("Current Branch", detail: store.branch) { store.showCurrentBranch() }
        current.state = store.showsCurrentBranch ? .on : .off
        menu.addItem(current)
        let all = MenuAction("All Branches") { store.selectReference(nil) }
        all.state = showsAll ? .on : .off
        menu.addItem(all)
        for (title, kind) in [("Local", ReferenceKind.localBranch), ("Remote", .remoteBranch)] {
            let branches = store.references.filter { $0.kind == kind }
            guard !branches.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: title))
            for branch in branches {
                let item = MenuAction(branch.name, detail: branch.isCurrent ? "current" : nil) {
                    store.selectReference(branch)
                }
                item.state = store.historyScope == .revision(branch.fullName) ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Which commits show.
    private var scope: (title: String, icon: String, help: String) {
        if let stash = store.selectedStash {
            return (stash.displayName, "archivebox", "the stash \(stash.displayName)")
        }
        switch store.historyScope {
        case .all:
            return ("All Branches", "square.stack.3d.up", "the commits of all branches")
        case .revision:
            let name = store.selectedReference?.name ?? (store.showsCurrentBranch ? store.branch : "branch")
            return (name, store.selectedReference?.kind.icon ?? "arrow.triangle.branch", "the commits of \(name)")
        case let .commit(hash):
            let short = String(hash.prefix(8))
            return (short, "number", "commit \(short) and the ones before it")
        case let .path(path, _):
            return (baseName(path), "doc", "the commits on \(store.pathHistoryReferenceName) that change \(path)")
        case .lostAndDangling:
            return ("Unreachable", "lifepreserver", "the commits no branch, tag or stash leads to")
        }
    }
}

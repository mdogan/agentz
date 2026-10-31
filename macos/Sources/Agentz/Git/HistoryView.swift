import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: RepositoryStore

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
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(historyTitle)
                        .font(.headline)
                    Text(historySubtitle(commitCount: commits.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if commits.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
            } else {
                ScrollViewReader { proxy in
                    List(selection: commitSelection) {
                        ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                            CommitRow(
                                commit: commit,
                                graphRow: graph?.rows[index],
                                graphColumnCount: graph?.columnCount ?? 0,
                                showsGraph: showsGraph
                            )
                            .tag(commit)
                            .listRowInsets(
                                EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 10)
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                LookListRowBackground(isSelected: commit.id == store.selectedCommit?.id)
                            )
                        }

                        if store.canLoadMoreHistory || store.isLoadingMoreHistory {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading more commits…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .listRowSeparator(.hidden)
                            .onAppear {
                                store.loadMoreHistory()
                            }
                        }
                    }
                    .listStyle(.inset)
                    .lookListBackground(Look.shared.background)
                    .onChange(of: store.commitReveal) { _, reveal in
                        guard let reveal else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(reveal.hash, anchor: .center)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                TextField("Search commits", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .help("Filter the loaded commit history")
            }
        }
    }

    private var commitSelection: Binding<GitCommit?> {
        Binding(
            get: { store.selectedCommit },
            set: { store.selectCommit($0) }
        )
    }

    private var historyTitle: String {
        switch store.historyScope {
        case let .path(path, _):
            return path
        case let .commit(hash):
            return "Commit \(String(hash.prefix(8)))"
        case .lostAndDangling:
            return "Unreachable Commits"
        case .all, .revision:
            return store.selectedReference?.name ?? "All Commits"
        }
    }

    /// The count line under the title. A path history also names the reference
    /// it is limited to, because the path alone does not say which branch the
    /// listed commits come from.
    private func historySubtitle(commitCount: Int) -> String {
        let count = "\(commitCount) commits"
        guard case .path = store.historyScope else { return count }
        return "\(count) on \(store.pathHistoryReferenceName)"
    }

    private var emptyTitle: String {
        if !store.searchText.isEmpty {
            return "No Matching Commits"
        }
        switch store.historyScope {
        case .path:
            return "No Path History"
        case .lostAndDangling:
            return "No Unreachable Commits"
        case .all, .revision, .commit:
            return "No Commits"
        }
    }

    private var emptySystemImage: String {
        switch store.historyScope {
        case .path:
            return "doc.text.magnifyingglass"
        case .lostAndDangling:
            return "lifepreserver"
        case .all, .revision, .commit:
            return "clock"
        }
    }

    private var emptyDescription: String {
        if !store.searchText.isEmpty {
            return "No commits match your search."
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

private struct CommitRow: View {
    let commit: GitCommit
    let graphRow: CommitGraphRow?
    let graphColumnCount: Int
    let showsGraph: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsGraph {
                Color.clear
                    .frame(width: graphWidth)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(commit.subject)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    CommitSignatureBadge(signature: commit.signature, compact: true)

                    ForEach(commit.decorations.prefix(2), id: \.self) { decoration in
                        HStack(spacing: 3) {
                            Image(systemName: labelIcon(decoration))
                                .font(.system(size: 8, weight: .bold))
                            Text(cleanDecoration(decoration))
                        }
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(labelColor(decoration))
                        .background(labelColor(decoration).opacity(0.14), in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(labelColor(decoration).opacity(0.22), lineWidth: 0.5)
                        )
                        .lineLimit(1)
                    }
                }

                HStack(spacing: 7) {
                    IdentityAvatar(name: commit.authorName, initials: commit.initials)
                    Text(commit.authorName)
                        .lineLimit(1)
                    Text("·")
                    Text(commit.date, format: .relative(presentation: .named))
                    if commit.parents.count > 1 {
                        Label(
                            "\(commit.parents.count) parents",
                            systemImage: "arrow.triangle.merge"
                        )
                        .foregroundStyle(GitForkTheme.purple)
                    }
                    Spacer()
                    Text(commit.shortHash)
                        .font(.caption.monospaced())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
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
            max(28, CGFloat(graphColumnCount - 1) * 14 + 14),
            140
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

    private func labelIcon(_ value: String) -> String {
        if value.contains("tag:") { return "tag.fill" }
        if value.contains("HEAD") { return "smallcircle.filled.circle" }
        if value.contains("/") { return "cloud" }
        return "arrow.triangle.branch"
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
                        lineWidth: 2,
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
                    x: nodePoint.x - 5,
                    y: nodePoint.y - 5,
                    width: 10,
                    height: 10
                )
            )
            context.fill(node, with: .color(color(row.nodeColor)))
            context.stroke(
                node,
                with: .color(.white.opacity(0.72)),
                lineWidth: 1
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

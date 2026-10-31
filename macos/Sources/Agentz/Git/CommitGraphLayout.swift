import Foundation

struct CommitGraphLayout: Sendable {
    static let colorCount = 8

    let rows: [CommitGraphRow]
    let columnCount: Int

    init(commits: [GitCommit]) {
        self.init(
            commits: commits,
            parentsByCommit: Dictionary(
                uniqueKeysWithValues: commits.map { ($0.hash, $0.parents) }
            )
        )
    }

    init(
        commits: [GitCommit],
        connectingThrough allCommits: [GitCommit]
    ) {
        let visibleHashes = Set(commits.map(\.hash))
        let allParents = Dictionary(
            uniqueKeysWithValues: allCommits.map { ($0.hash, $0.parents) }
        )
        let parentsByCommit = Dictionary(
            uniqueKeysWithValues: commits.map {
                (
                    $0.hash,
                    Self.visibleParents(
                        from: $0.parents,
                        visibleHashes: visibleHashes,
                        allParents: allParents
                    )
                )
            }
        )
        self.init(commits: commits, parentsByCommit: parentsByCommit)
    }

    private init(
        commits: [GitCommit],
        parentsByCommit: [String: [String]]
    ) {
        var lanes: [Lane] = []
        var rows: [CommitGraphRow] = []
        var maximumColumnCount = 1
        var nextLaneID = 0

        for commit in commits {
            let parents = parentsByCommit[commit.hash] ?? []
            let incomingColumns = lanes.indices.filter {
                lanes[$0].hash == commit.hash
            }
            let nodeColumn: Int

            if let existingColumn = incomingColumns.first {
                nodeColumn = existingColumn
            } else {
                let color = Self.availableColor(in: lanes)
                nodeColumn = lanes.count
                lanes.append(
                    Lane(
                        id: nextLaneID,
                        hash: commit.hash,
                        color: color
                    )
                )
                nextLaneID += 1
            }

            let incoming = lanes
            let nodeLane = incoming[nodeColumn]
            // Keep one lane per visible parent edge, even when several edges
            // target the same commit. Those lanes converge on the parent node
            // instead of joining at an unrelated row boundary.
            var outgoing = incoming.filter { $0.hash != commit.hash }
            var parentLanes: [Lane] = []

            for (parentOffset, parent) in parents.enumerated() {
                let insertionColumn = min(nodeColumn + parentOffset, outgoing.count)
                let color = parentOffset == 0
                    ? nodeLane.color
                    : Self.availableColor(in: outgoing)
                let parentLane = Lane(
                    id: nextLaneID,
                    hash: parent,
                    color: color
                )
                nextLaneID += 1
                outgoing.insert(parentLane, at: insertionColumn)
                parentLanes.append(parentLane)
            }

            var segments: [CommitGraphSegment] = []
            for column in incomingColumns {
                segments.append(
                    CommitGraphSegment(
                        start: .top(column),
                        end: .node(nodeColumn),
                        color: incoming[column].color
                    )
                )
            }

            for (column, lane) in incoming.enumerated()
            where lane.hash != commit.hash {
                guard let destination = outgoing.firstIndex(where: { $0.id == lane.id }) else {
                    continue
                }
                segments.append(
                    CommitGraphSegment(
                        start: .top(column),
                        end: .bottom(destination),
                        color: lane.color
                    )
                )
            }

            for parentLane in parentLanes {
                guard let destination = outgoing.firstIndex(where: { $0.id == parentLane.id }) else {
                    continue
                }
                segments.append(
                    CommitGraphSegment(
                        start: .node(nodeColumn),
                        end: .bottom(destination),
                        color: parentLane.color
                    )
                )
            }

            let rowColumnCount = max(
                incoming.count,
                outgoing.count,
                nodeColumn + 1
            )
            maximumColumnCount = max(maximumColumnCount, rowColumnCount)
            rows.append(
                CommitGraphRow(
                    commitHash: commit.hash,
                    nodeColumn: nodeColumn,
                    nodeColor: nodeLane.color,
                    segments: segments,
                    columnCount: rowColumnCount
                )
            )
            lanes = outgoing
        }

        self.rows = rows
        columnCount = maximumColumnCount
    }

    private static func visibleParents(
        from parents: [String],
        visibleHashes: Set<String>,
        allParents: [String: [String]]
    ) -> [String] {
        var result: [String] = []
        var visited: Set<String> = []

        func visit(_ hash: String) {
            guard visited.insert(hash).inserted else { return }
            if visibleHashes.contains(hash) {
                result.append(hash)
                return
            }
            for parent in allParents[hash] ?? [] {
                visit(parent)
            }
        }

        for parent in parents {
            visit(parent)
        }
        return result
    }

    private static func availableColor(in lanes: [Lane]) -> Int {
        let activeColors = Set(lanes.map(\.color))
        return (0..<colorCount).first { !activeColors.contains($0) }
            ?? lanes.count % colorCount
    }
}

struct CommitGraphRow: Hashable, Sendable {
    let commitHash: String
    let nodeColumn: Int
    let nodeColor: Int
    let segments: [CommitGraphSegment]
    let columnCount: Int
}

struct CommitGraphSegment: Hashable, Sendable {
    let start: CommitGraphAnchor
    let end: CommitGraphAnchor
    let color: Int
}

enum CommitGraphAnchor: Hashable, Sendable {
    case top(Int)
    case node(Int)
    case bottom(Int)

    var column: Int {
        switch self {
        case let .top(column), let .node(column), let .bottom(column):
            column
        }
    }
}

private struct Lane: Sendable {
    let id: Int
    let hash: String
    let color: Int
}

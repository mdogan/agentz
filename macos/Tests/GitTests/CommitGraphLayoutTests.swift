import Foundation
import Testing
@testable import agentz

struct CommitGraphLayoutTests {
    @Test
    func laysOutLinearHistoryInOneContinuousLane() {
        let layout = CommitGraphLayout(
            commits: [
                commit("child", parents: ["parent"]),
                commit("parent", parents: ["root"]),
                commit("root")
            ]
        )

        #expect(layout.columnCount == 1)
        #expect(layout.rows.map(\.nodeColumn) == [0, 0, 0])
        #expect(
            layout.rows[1].segments.contains(
                segment(.top(0), .node(0), color: 0)
            )
        )
        #expect(
            layout.rows[1].segments.contains(
                segment(.node(0), .bottom(0), color: 0)
            )
        )
    }

    @Test
    func showsTwoChildrenForkingFromTheSameParent() {
        let layout = CommitGraphLayout(
            commits: [
                commit("first-child", parents: ["root"]),
                commit("second-child", parents: ["root"]),
                commit("root")
            ]
        )

        #expect(layout.columnCount == 2)
        #expect(layout.rows[1].nodeColumn == 1)
        #expect(
            layout.rows[1].segments.contains {
                $0.start == .top(0) && $0.end == .bottom(0)
            }
        )
        #expect(
            layout.rows[1].segments.contains {
                $0.start == .node(1) && $0.end == .bottom(1)
            }
        )
        #expect(
            layout.rows[2].segments.contains {
                $0.start == .top(0) && $0.end == .node(0)
            }
        )
        #expect(
            layout.rows[2].segments.contains {
                $0.start == .top(1) && $0.end == .node(0)
            }
        )
        expectContinuousRowBoundaries(layout)
    }

    @Test
    func routesBothMergeParentsAndRejoinsTheirSharedAncestor() {
        let layout = CommitGraphLayout(
            commits: [
                commit("merge", parents: ["left", "right"]),
                commit("left", parents: ["root"]),
                commit("right", parents: ["root"]),
                commit("root")
            ]
        )

        #expect(layout.columnCount == 2)
        #expect(
            layout.rows[0].segments.contains {
                $0.start == .node(0) && $0.end == .bottom(0)
            }
        )
        #expect(
            layout.rows[0].segments.contains {
                $0.start == .node(0) && $0.end == .bottom(1)
            }
        )
        #expect(layout.rows[2].nodeColumn == 1)
        #expect(
            layout.rows[2].segments.contains {
                $0.start == .node(1) && $0.end == .bottom(1)
            }
        )
        #expect(
            layout.rows[3].segments.contains {
                $0.start == .top(0) && $0.end == .node(0)
            }
        )
        #expect(
            layout.rows[3].segments.contains {
                $0.start == .top(1) && $0.end == .node(0)
            }
        )
        expectContinuousRowBoundaries(layout)
    }

    @Test
    func givesConcurrentLanesDistinctColors() {
        let layout = CommitGraphLayout(
            commits: [
                commit("merge", parents: ["left", "right", "third"])
            ]
        )

        let outgoingColors = Set(
            layout.rows[0].segments
                .filter {
                    if case .bottom = $0.end { return true }
                    return false
                }
                .map(\.color)
        )

        #expect(layout.columnCount == 3)
        #expect(outgoingColors.count == 3)
    }

    @Test
    func connectsFilteredCommitsThroughHiddenAncestors() {
        let allCommits = [
            commit("tip", parents: ["hidden-1"]),
            commit("hidden-1", parents: ["hidden-2"]),
            commit("hidden-2", parents: ["root"]),
            commit("root")
        ]
        let layout = CommitGraphLayout(
            commits: [allCommits[0], allCommits[3]],
            connectingThrough: allCommits
        )

        #expect(layout.columnCount == 1)
        #expect(
            layout.rows[0].segments.contains {
                $0.start == .node(0) && $0.end == .bottom(0)
            }
        )
        #expect(
            layout.rows[1].segments.contains {
                $0.start == .top(0) && $0.end == .node(0)
            }
        )
    }

    @Test
    func keepsExistingLaneContinuousWhenASeparateTipAppears() {
        let layout = CommitGraphLayout(
            commits: [
                commit("first-tip", parents: ["first-parent"]),
                commit("second-tip", parents: ["second-parent"]),
                commit("first-parent"),
                commit("second-parent")
            ]
        )

        #expect(layout.rows[0].nodeColumn == 0)
        #expect(layout.rows[1].nodeColumn == 1)
        #expect(
            layout.rows[1].segments.contains {
                $0.start == .top(0) && $0.end == .bottom(0)
            }
        )
        expectContinuousRowBoundaries(layout)
    }

    private func commit(
        _ hash: String,
        parents: [String] = []
    ) -> GitCommit {
        GitCommit(
            hash: hash,
            parents: parents,
            authorName: "GitFork Tests",
            authorEmail: "tests@example.com",
            date: .distantPast,
            decorations: [],
            signature: .unsigned,
            subject: hash
        )
    }

    private func segment(
        _ start: CommitGraphAnchor,
        _ end: CommitGraphAnchor,
        color: Int
    ) -> CommitGraphSegment {
        CommitGraphSegment(start: start, end: end, color: color)
    }

    private func expectContinuousRowBoundaries(
        _ layout: CommitGraphLayout
    ) {
        for index in layout.rows.indices.dropLast() {
            let outgoing = Set<String>(
                layout.rows[index].segments.compactMap { segment -> String? in
                    guard case let .bottom(column) = segment.end else {
                        return nil
                    }
                    return "\(column):\(segment.color)"
                }
            )
            let incoming = Set<String>(
                layout.rows[index + 1].segments.compactMap { segment -> String? in
                    guard case let .top(column) = segment.start else {
                        return nil
                    }
                    return "\(column):\(segment.color)"
                }
            )

            #expect(outgoing == incoming)
        }
    }
}

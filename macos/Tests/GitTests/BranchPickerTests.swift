import Testing
@testable import agentz

struct BranchPickerTests {
    private let main = GitReference(
        name: "main",
        fullName: "refs/heads/main",
        kind: .localBranch,
        target: "1111111",
        isCurrent: true
    )
    private let feature = GitReference(
        name: "feature/branch-picker",
        fullName: "refs/heads/feature/branch-picker",
        kind: .localBranch,
        target: "2222222",
        isCurrent: false
    )
    private let remote = GitReference(
        name: "origin/feature/branch-picker",
        fullName: "refs/remotes/origin/feature/branch-picker",
        kind: .remoteBranch,
        target: "2222222",
        isCurrent: false
    )
    private let tag = GitReference(
        name: "v1.0",
        fullName: "refs/tags/v1.0",
        kind: .tag,
        target: "3333333",
        isCurrent: false
    )

    @Test
    func filtersLocalAndRemoteBranchesByNameAndOmitsTags() {
        let references = [main, feature, remote, tag]

        #expect(
            BranchPickerSearch.filter(references, query: "  ")
                == [main, feature, remote]
        )
        #expect(
            BranchPickerSearch.filter(references, query: "BRANCH-PICKER")
                == [feature, remote]
        )
        #expect(
            BranchPickerSearch.filter(references, query: "origin/")
                == [remote]
        )
        #expect(
            BranchPickerSearch.filter(references, query: "v1.0").isEmpty
        )
    }

    @Test
    func reconcilesToSelectedSidebarBranchThenCurrentBranch() {
        let branches = [main, feature, remote]

        #expect(
            BranchPickerNavigation.reconcile(
                selection: nil,
                branches: branches,
                preferredBranch: feature
            ) == feature
        )
        #expect(
            BranchPickerNavigation.reconcile(
                selection: remote,
                branches: [main, feature],
                preferredBranch: remote
            ) == main
        )
        #expect(
            BranchPickerNavigation.reconcile(
                selection: feature,
                branches: [remote],
                preferredBranch: feature
            ) == remote
        )
    }

    @Test
    func movesSelectionAndWrapsAtBothEnds() {
        let branches = [main, feature, remote]

        #expect(
            BranchPickerNavigation.move(
                selection: main,
                offset: 1,
                branches: branches
            ) == feature
        )
        #expect(
            BranchPickerNavigation.move(
                selection: main,
                offset: -1,
                branches: branches
            ) == remote
        )
        #expect(
            BranchPickerNavigation.move(
                selection: remote,
                offset: 1,
                branches: branches
            ) == main
        )
        #expect(
            BranchPickerNavigation.move(
                selection: nil,
                offset: -1,
                branches: branches
            ) == remote
        )
        #expect(
            BranchPickerNavigation.move(
                selection: main,
                offset: 1,
                branches: []
            ) == nil
        )
    }
}

struct GitRowStatusTests {
    @Test
    func saysNothingWhenThereIsNothingToSay() {
        #expect(GitRowStatus().summary.isEmpty)
        #expect(GitRowStatus().help.isEmpty)
    }

    @Test
    func leavesOutWhatIsZero() {
        #expect(GitRowStatus(ahead: 2).summary == "↑2")
        #expect(GitRowStatus(behind: 1).summary == "↓1")
        #expect(GitRowStatus(changes: 1).summary == "1 change")
        #expect(GitRowStatus(conflicts: 2).summary == "2 conflicts")
        #expect(
            GitRowStatus(ahead: 2, behind: 1, changes: 3, conflicts: 1).summary
                == "↑2 ↓1 · 3 changes · 1 conflict"
        )
        #expect(
            GitRowStatus(ahead: 1, behind: 2, changes: 1, conflicts: 2).help
                == "1 commit to push\n2 commits to pull\n1 uncommitted change\n2 files in conflict"
        )
    }
}

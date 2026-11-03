import Combine
import Foundation
import Testing
@testable import agentz

struct GitParserTests {
    @Test
    func parsesPorcelainStatusIncludingRenameAndUntracked() {
        let input = "M  staged.swift\u{0} M working.swift\u{0}?? new file.md\u{0}R  renamed.swift\u{0}old.swift\u{0}"
        let changes = GitParser.parseStatus(Data(input.utf8))

        #expect(changes.count == 4)
        #expect(changes.first { $0.path == "staged.swift" }?.isStaged == true)
        #expect(changes.first { $0.path == "working.swift" }?.isUnstaged == true)
        #expect(changes.first { $0.path == "new file.md" }?.isUntracked == true)
        #expect(changes.first { $0.path == "renamed.swift" }?.originalPath == "old.swift")
    }

    @Test
    func ignoresPorcelainBranchHeaderWhenParsingChanges() {
        let input = "## main...origin/main [ahead 1]\u{0} M working.swift\u{0}"
        let changes = GitParser.parseStatus(Data(input.utf8))

        #expect(changes.count == 1)
        #expect(changes[0].path == "working.swift")
        #expect(changes[0].isUnstaged)
    }

    @Test
    func classifiesEveryPorcelainConflictStateAndAvailableVersions() {
        let input = "DD both-deleted\u{0}AU added-by-us\u{0}UD deleted-by-them\u{0}"
            + "UA added-by-them\u{0}DU deleted-by-us\u{0}AA both-added\u{0}"
            + "UU both-modified\u{0}"
        let changes = GitParser.parseStatus(Data(input.utf8))

        #expect(changes.count == 7)
        #expect(changes.allSatisfy { $0.isConflicted })
        #expect(changes.allSatisfy { !$0.isStaged && !$0.isUnstaged })
        #expect(changes.allSatisfy { $0.statusSymbol(staged: false) == "U" })

        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        #expect(byPath["both-deleted"]?.conflictDescription == "Both deleted")
        #expect(byPath["both-modified"]?.conflictDescription == "Both modified")
        #expect(byPath["added-by-us"]?.hasConflictVersion(.ours) == true)
        #expect(byPath["added-by-us"]?.hasConflictVersion(.theirs) == false)
        #expect(byPath["deleted-by-us"]?.hasConflictVersion(.ours) == false)
        #expect(byPath["deleted-by-us"]?.hasConflictVersion(.theirs) == true)
        #expect(byPath["both-added"]?.hasConflictVersion(.ours) == true)
        #expect(byPath["both-added"]?.hasConflictVersion(.theirs) == true)
    }

    @Test
    func presentsDualStateChangeAccordingToItsSection() {
        let change = WorkingChange(
            path: "dual-state.swift",
            originalPath: nil,
            indexStatus: "A",
            workTreeStatus: "M"
        )

        #expect(change.statusSymbol(staged: true) == "A")
        #expect(change.displayStatus(staged: true) == "Added")
        #expect(change.statusSymbol(staged: false) == "M")
        #expect(change.displayStatus(staged: false) == "Modified")
    }

    @Test
    func groupsDisplayHunksAndTracksOldAndNewLineNumbers() throws {
        let diff = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -10,3 +10,4 @@
         context before
        -old value
        +new value
        +extra value
         context after
        """
        let document = UnifiedDiff(diff)
        let hunk = try #require(document.displayHunks.first)

        #expect(document.displayHunks.count == 1)
        #expect(hunk.header.text == "@@ -10,3 +10,4 @@")
        #expect(hunk.lines.map(\.text) == [
            " context before",
            "-old value",
            "+new value",
            "+extra value",
            " context after"
        ])
        #expect(hunk.lines.map(\.oldLineNumber) == [10, 11, nil, nil, 12])
        #expect(hunk.lines.map(\.newLineNumber) == [10, nil, 11, 12, 13])
        #expect(hunk.selectableLineIDs.count == 3)
    }

    @Test
    func pairsReplacedLinesIntoSideBySideRows() throws {
        let diff = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -10,4 +10,5 @@
         context before
        -old value
        -dropped value
        +new value
        +extra value
        +another value
         context after
        """
        let sideBySide = SideBySideDiff(UnifiedDiff(diff))
        let hunk = try #require(sideBySide.hunks.first)

        #expect(hunk.header.text == "@@ -10,4 +10,5 @@")
        #expect(hunk.rows.map { $0.old?.displayText } == [
            "context before",
            "old value",
            "dropped value",
            nil,
            "context after"
        ])
        #expect(hunk.rows.map { $0.new?.displayText } == [
            "context before",
            "new value",
            "extra value",
            "another value",
            "context after"
        ])
        #expect(hunk.rows.map { $0.old?.oldLineNumber } == [10, 11, 12, nil, 13])
        #expect(hunk.rows.map { $0.new?.newLineNumber } == [10, 11, 12, 13, 14])
        #expect(hunk.selectableLineIDs.count == 5)
        #expect(sideBySide.rowCount == 5)
        // Column width covers context lines too, not just the changed ones.
        #expect(sideBySide.oldColumnCharacters == "context before".count)
        #expect(sideBySide.newColumnCharacters == "context before".count)
    }

    @Test
    func loadsCompleteFileContextForSideBySideComparison() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkFullFileDiffTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let file = root.appendingPathComponent("lines.txt")
        var lines = (1...30).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "lines.txt"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        lines[14] = "changed line 15"
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let client = GitClient()
        let snapshot = try await client.snapshot(at: root)
        let change = try #require(
            snapshot.changes.first { $0.path == "lines.txt" }
        )
        let compactDiff = try await client.diff(
            at: root,
            change: change,
            staged: false
        )
        let fullDiff = try await client.diff(
            at: root,
            change: change,
            staged: false,
            fullFile: true
        )

        let compactLines = try #require(
            UnifiedDiff(compactDiff).displayHunks.first
        ).lines.map(\.displayText)
        #expect(!compactLines.contains("line 1"))
        #expect(!compactLines.contains("line 30"))

        let fullRows = try #require(
            SideBySideDiff(UnifiedDiff(fullDiff)).hunks.first
        ).rows
        #expect(fullRows.first?.old?.displayText == "line 1")
        #expect(fullRows.first?.new?.displayText == "line 1")
        #expect(fullRows.last?.old?.displayText == "line 30")
        #expect(fullRows.last?.new?.displayText == "line 30")
        #expect(fullRows.contains {
            $0.old?.displayText == "line 15"
                && $0.new?.displayText == "changed line 15"
        })
    }

    @Test
    func startsANewSideBySideBlockWhenDeletionsFollowAdditions() throws {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,4 +1,4 @@
        -first old
        +first new
        -second old
        +second new
        """
        let sideBySide = SideBySideDiff(UnifiedDiff(diff))
        let hunk = try #require(sideBySide.hunks.first)

        #expect(hunk.rows.count == 2)
        #expect(hunk.rows.map { $0.old?.displayText } == ["first old", "second old"])
        #expect(hunk.rows.map { $0.new?.displayText } == ["first new", "second new"])
    }

    @Test
    func buildsContinuousSideBySideColumnTextAcrossRowsAndHunks() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
         shared
        -old
        +new
        @@ -8 +8,2 @@
        +inserted
         trailing
        """
        let sideBySide = SideBySideDiff(UnifiedDiff(diff))

        let oldLines = sideBySide.columnLines(on: .old)
        let newLines = sideBySide.columnLines(on: .new)

        #expect(oldLines.map(\.text) == [
            "@@ -1,2 +1,2 @@", "shared", "old",
            "@@ -8 +8,2 @@", "", "trailing"
        ])
        #expect(newLines.map(\.text) == [
            "@@ -1,2 +1,2 @@", "shared", "new",
            "@@ -8 +8,2 @@", "inserted", "trailing"
        ])
        #expect(oldLines.filter(\.addsHunkSpacing).map(\.text) == ["old", "trailing"])
        #expect(newLines.filter(\.addsHunkSpacing).map(\.text) == ["new", "trailing"])
    }

    @Test
    func keepsMissingNewlineMarkerOnTheVersionThatOwnsIt() throws {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1 +1 @@
        -old value
        +new value
        \\ No newline at end of file
        """
        let sideBySide = SideBySideDiff(UnifiedDiff(diff))
        let hunk = try #require(sideBySide.hunks.first)

        #expect(hunk.rows.count == 2)
        #expect(hunk.rows[1].old == nil)
        #expect(hunk.rows[1].new?.kind == .noNewline)
    }

    @Test
    func separatesCommitDiffIntoFiles() {
        let diff = """
        commit abcdef123456
        Author: Ada Lovelace

         2 files changed, 2 insertions(+), 1 deletion(-)

        diff --git a/Sources/First File.swift b/Sources/First File.swift
        index 1111111..2222222 100644
        --- a/Sources/First File.swift
        +++ b/Sources/First File.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/removed.swift b/removed.swift
        deleted file mode 100644
        --- a/removed.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -removed
        diff --git a/old name.swift b/new name.swift
        similarity index 100%
        rename from old name.swift
        rename to new name.swift
        diff --git a/Assets/icon image.png b/Assets/icon image.png
        index 3333333..4444444 100644
        Binary files a/Assets/icon image.png and b/Assets/icon image.png differ
        """
        let document = UnifiedDiff(diff)

        #expect(document.preambleLines.first?.text == "commit abcdef123456")
        #expect(document.preambleLines.last?.text == "")
        #expect(document.files.count == 4)
        #expect(document.files[0].path == "Sources/First File.swift")
        #expect(document.files[0].lines.first?.text.hasPrefix("diff --git ") == true)
        #expect(document.files[1].path == "removed.swift")
        #expect(document.files[1].lines.last?.text == "-removed")
        #expect(document.files[2].path == "new name.swift")
        #expect(document.files[3].path == "Assets/icon image.png")
    }

    @Test
    func summarizesEachFileInACommitDiff() {
        let diff = """
        diff --git a/Sources/Added.swift b/Sources/Added.swift
        new file mode 100644
        --- /dev/null
        +++ b/Sources/Added.swift
        @@ -0,0 +2 @@
        +first
        +second
        diff --git a/Sources/Edited.swift b/Sources/Edited.swift
        index 1111111..2222222 100644
        --- a/Sources/Edited.swift
        +++ b/Sources/Edited.swift
        @@ -1,2 +1,2 @@
         context
        -old
        +new
        diff --git a/removed.swift b/removed.swift
        deleted file mode 100644
        --- a/removed.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -removed
        diff --git "a/old name.swift" "b/new name.swift"
        similarity index 100%
        rename from "old name.swift"
        rename to "new name.swift"
        """
        let files = UnifiedDiff(diff).files

        #expect(files.count == 4)
        #expect(files[0].change == .added)
        #expect(files[0].additions == 2)
        #expect(files[0].deletions == 0)
        #expect(files[0].originalPath == nil)
        #expect(files[1].change == .modified)
        #expect(files[1].additions == 1)
        #expect(files[1].deletions == 1)
        #expect(files[2].change == .deleted)
        #expect(files[2].additions == 0)
        #expect(files[2].deletions == 1)
        #expect(files[3].change == .renamed)
        #expect(files[3].path == "new name.swift")
        #expect(files[3].originalPath == "old name.swift")
        #expect(files[3].change.symbol == "R")
    }

    @Test
    func doesNotMistakeDiffContentForFileHeaders() {
        let diff = """
        diff --git a/notes.txt b/notes.txt
        index 1111111..2222222 100644
        --- a/notes.txt
        +++ b/notes.txt
        @@ -1,2 +1,2 @@
        -rename from somewhere
        +new file mode 100644
        """
        let file = UnifiedDiff(diff).files.first

        #expect(file?.change == .modified)
        #expect(file?.originalPath == nil)
        #expect(file?.additions == 1)
        #expect(file?.deletions == 1)
    }

    @Test
    func parsesCommitRecords() {
        let input = "abcdef123456\u{1f}111111 222222\u{1f}Ada Lovelace\u{1f}ada@example.com\u{1f}2026-07-23T10:30:00+03:00\u{1f}HEAD -> main, tag: v1.0\u{1f}G\u{1f}ABCDEF1234567890\u{1f}Ada Lovelace\u{1f}Good signature\u{1f}Ship native client\u{1e}"
        let commits = GitParser.parseCommits(input)

        #expect(commits.count == 1)
        #expect(commits[0].shortHash == "abcdef12")
        #expect(commits[0].parents.count == 2)
        #expect(commits[0].decorations == ["HEAD -> main", "tag: v1.0"])
        #expect(commits[0].signature.status == .good)
        #expect(commits[0].signature.keyID == "ABCDEF1234567890")
        #expect(commits[0].signature.signer == "Ada Lovelace")
        #expect(commits[0].subject == "Ship native client")
    }

    @Test
    func detectsSignatureWhenTrustVerificationCannotComplete() {
        let verification = """
        gpg: Signature made Fri Jul 24 09:27:31 2026 +03
        gpg:                using RSA key ABCDEF1234567890
        gpg: Fatal: trust database unavailable
        """
        let input = "abcdef123456\u{1f}\u{1f}Ada Lovelace\u{1f}ada@example.com\u{1f}2026-07-24T09:27:31+03:00\u{1f}\u{1f}N\u{1f}\u{1f}\u{1f}\(verification)\u{1f}Signed commit\u{1e}"
        let commits = GitParser.parseCommits(input)

        #expect(commits.count == 1)
        #expect(commits[0].signature.status == .cannotCheck)
        #expect(commits[0].signature.keyID == "ABCDEF1234567890")
        #expect(commits[0].subject == "Signed commit")
    }

    @Test
    func parsesAndGroupsReferences() {
        let input = """
        refs/heads/main\u{1f}abc\u{1f}abcdef
        refs/remotes/origin/HEAD\u{1f}abc\u{1f}abcdef
        refs/remotes/origin/main\u{1f}abc\u{1f}abcdef
        refs/tags/v1.0\u{1f}def\u{1f}defdef
        """
        let references = GitParser.parseReferences(input, currentBranch: "main")

        #expect(references.count == 3)
        #expect(references.first { $0.name == "main" }?.isCurrent == true)
        #expect(references.contains { $0.name == "origin/main" })
        #expect(!references.contains { $0.name == "origin/HEAD" })
    }

    @Test
    func readsBranchNameAndDetachedHeadFromStoredHeadDescription() {
        #expect(BranchDisplay("feature/api") == .branch("feature/api"))
        #expect(BranchDisplay("feature/api").branchName == "feature/api")
        #expect(!BranchDisplay("feature/api").isDetached)

        #expect(BranchDisplay("Detached at cb34769a") == .detached(hash: "cb34769a"))
        #expect(BranchDisplay("Detached at cb34769a").isDetached)
        #expect(BranchDisplay("Detached at cb34769a").branchName == nil)
    }

    @Test
    func roundTripsHeadDescriptionThroughBranchDisplay() {
        for head in ["main", "Detached at cb34769a", ""] {
            #expect(BranchDisplay(head).description == head)
        }

        // A branch literally named like the detached label stays a branch only
        // when it does not carry the prefix Git-facing code writes.
        #expect(BranchDisplay("Detached") == .branch("Detached"))
    }

    @Test
    func parsesUpstreamTrackingOfLocalBranches() throws {
        let tracked = [
            "refs/heads/feature/api",
            "abc",
            "abcdef",
            "refs/remotes/origin/feature/api",
            "origin/feature/api",
            "origin",
            "refs/heads/feature/api",
            "[ahead 1]"
        ].joined(separator: "\u{1f}")
        let untracked = [
            "refs/heads/local-only",
            "def",
            "defdef",
            "",
            "",
            "",
            "",
            ""
        ].joined(separator: "\u{1f}")
        let remote = [
            "refs/remotes/origin/feature/api",
            "abc",
            "abcdef",
            "",
            "",
            "",
            "",
            ""
        ].joined(separator: "\u{1f}")

        let references = GitParser.parseReferences(
            [tracked, untracked, remote].joined(separator: "\n"),
            currentBranch: "feature/api"
        )

        let upstream = try #require(
            references.first { $0.name == "feature/api" && $0.kind == .localBranch }?.upstream
        )
        #expect(upstream.fullName == "refs/remotes/origin/feature/api")
        #expect(upstream.shortName == "origin/feature/api")
        #expect(upstream.remote == "origin")
        #expect(upstream.remoteRef == "refs/heads/feature/api")
        #expect(references.first { $0.name == "local-only" }?.upstream == nil)
        #expect(references.first { $0.kind == .remoteBranch }?.upstream == nil)
    }

    @Test
    func omitsUpstreamWhenReferenceRecordPredatesUpstreamFields() {
        let references = GitParser.parseReferences(
            "refs/heads/main\u{1f}abc\u{1f}abcdef",
            currentBranch: "main"
        )

        #expect(references.first?.upstream == nil)
    }

    @Test
    func buildsRemoteBranchDeletionArguments() throws {
        let arguments = try GitClient.deleteRemoteBranchArguments(
            for: GitUpstream(
                fullName: "refs/remotes/origin/feature/api",
                shortName: "origin/feature/api",
                remote: "origin",
                remoteRef: "refs/heads/feature/api"
            )
        )

        #expect(
            arguments == [
                "-c",
                "remote.origin.mirror=false",
                "push",
                "--delete",
                "--",
                "origin",
                "refs/heads/feature/api"
            ]
        )
    }

    @Test
    func derivesRemoteBranchTargetFromRemoteTrackingReference() throws {
        let remoteBranch = GitReference(
            name: "origin/feature/api",
            fullName: "refs/remotes/origin/feature/api",
            kind: .remoteBranch,
            target: "aaaaaa",
            isCurrent: false
        )

        let target = try #require(remoteBranch.remoteBranchTarget)
        #expect(target.remote == "origin")
        #expect(target.remoteRef == "refs/heads/feature/api")
        #expect(target.shortName == "origin/feature/api")
        #expect(target.fullName == "refs/remotes/origin/feature/api")
        #expect(
            try GitClient.deleteRemoteBranchArguments(for: target) == [
                "-c",
                "remote.origin.mirror=false",
                "push",
                "--delete",
                "--",
                "origin",
                "refs/heads/feature/api"
            ]
        )
    }

    @Test
    func withholdsRemoteBranchTargetFromLocalAndUnqualifiedReferences() {
        let localBranch = GitReference(
            name: "feature/api",
            fullName: "refs/heads/feature/api",
            kind: .localBranch,
            target: "aaaaaa",
            isCurrent: false
        )
        let tag = GitReference(
            name: "v1.0",
            fullName: "refs/tags/v1.0",
            kind: .tag,
            target: "bbbbbb",
            isCurrent: false
        )
        // A ref directly beneath refs/remotes/ names no branch on any remote.
        let unqualified = GitReference(
            name: "origin",
            fullName: "refs/remotes/origin",
            kind: .remoteBranch,
            target: "cccccc",
            isCurrent: false
        )

        #expect(localBranch.remoteBranchTarget == nil)
        #expect(tag.remoteBranchTarget == nil)
        #expect(unqualified.remoteBranchTarget == nil)
    }

    @Test
    func rejectsRemoteDeletionOfNonBranchUpstream() {
        #expect(throws: GitOperationError.self) {
            try GitClient.deleteRemoteBranchArguments(
                for: GitUpstream(
                    fullName: "refs/remotes/origin/v1.0",
                    shortName: "origin/v1.0",
                    remote: "origin",
                    remoteRef: "refs/tags/v1.0"
                )
            )
        }
    }

    @Test
    func buildsSlashDelimitedReferenceTree() throws {
        let references = [
            GitReference(
                name: "feature/blob-store",
                fullName: "refs/heads/feature/blob-store",
                kind: .localBranch,
                target: "111111",
                isCurrent: false
            ),
            GitReference(
                name: "feature/proxy/quic",
                fullName: "refs/heads/feature/proxy/quic",
                kind: .localBranch,
                target: "222222",
                isCurrent: false
            ),
            GitReference(
                name: "fix",
                fullName: "refs/heads/fix",
                kind: .localBranch,
                target: "333333",
                isCurrent: false
            )
        ]

        let tree = ReferenceTreeNode.build(from: references)
        #expect(tree.map(\.name) == ["feature", "fix"])

        let feature = try #require(tree.first { $0.name == "feature" })
        #expect(feature.reference == nil)
        #expect(feature.children.map(\.name) == ["blob-store", "proxy"])
        #expect(feature.children.first?.reference?.name == "feature/blob-store")
        #expect(feature.children.last?.children.first?.reference?.name == "feature/proxy/quic")

        let fix = try #require(tree.first { $0.name == "fix" })
        #expect(fix.reference?.name == "fix")
        #expect(fix.children.isEmpty)
    }

    @Test
    func movesBranchUnderMultiLevelPrefixKeepingItsLastComponent() throws {
        func branch(_ name: String) -> GitReference {
            GitReference(
                name: name,
                fullName: "refs/heads/\(name)",
                kind: .localBranch,
                target: "111111",
                isCurrent: false
            )
        }
        let login = branch("team/fix/login")

        let nested = try #require(GitBranchMove(reference: login, toPrefix: "experimental/ui"))
        #expect(nested.newName == "experimental/ui/login")
        #expect(nested.destinationPrefix == "experimental/ui")

        #expect(GitBranchMove(reference: branch("fix/login"), toPrefix: "experimental")?.newName
            == "experimental/login")
        #expect(GitBranchMove(reference: login, toPrefix: "team")?.newName == "team/login")
        #expect(GitBranchMove(reference: login, toPrefix: "")?.newName == "login")
        #expect(GitBranchMove(reference: branch("login"), toPrefix: "fix")?.newName == "fix/login")

        #expect(GitBranchMove(reference: login, toPrefix: "team/fix") == nil)
        #expect(GitBranchMove(reference: branch("login"), toPrefix: "") == nil)
        let remote = GitReference(
            name: "origin/fix/login",
            fullName: "refs/remotes/origin/fix/login",
            kind: .remoteBranch,
            target: "111111",
            isCurrent: false
        )
        #expect(GitBranchMove(reference: remote, toPrefix: "experimental") == nil)
    }

    @Test
    func listsEveryLocalBranchPrefixAtEveryDepthSorted() {
        func reference(_ name: String, kind: ReferenceKind = .localBranch) -> GitReference {
            GitReference(
                name: name,
                fullName: "refs/heads/\(name)",
                kind: kind,
                target: "111111",
                isCurrent: false
            )
        }
        let references = [
            reference("team/fix/login"),
            reference("main"),
            reference("experimental/ui"),
            reference("team/fix/logout"),
            reference("Feature/b2"),
            reference("feature10/x"),
            reference("feature2/x"),
            reference("origin/remote-only/x", kind: .remoteBranch),
            reference("release/v1", kind: .tag)
        ]

        #expect(
            GitBranchMove.prefixes(in: references)
                == ["experimental", "Feature", "feature2", "feature10", "team", "team/fix"]
        )
        #expect(GitBranchMove.prefixes(in: [reference("main")]).isEmpty)
    }

    @Test
    func normalizesTypedBranchPrefixes() {
        #expect(GitBranchMove.normalizedPrefix("  experimental/ui/ ") == "experimental/ui")
        #expect(GitBranchMove.normalizedPrefix("/team/fix") == "team/fix")
        #expect(GitBranchMove.normalizedPrefix(" / ").isEmpty)
    }

    @Test
    func detectsBranchMoveConflictsWithBranchesAndFolders() throws {
        func branch(_ name: String, kind: ReferenceKind = .localBranch) -> GitReference {
            GitReference(
                name: name,
                fullName: "refs/heads/\(name)",
                kind: kind,
                target: "111111",
                isCurrent: false
            )
        }
        let login = branch("fix/login")
        let move = try #require(GitBranchMove(reference: login, toPrefix: "experimental"))

        #expect(move.conflictingBranch(in: [login, branch("experimental/other")]) == nil)
        #expect(move.conflictingBranch(in: [login, branch("experimental/login-v2")]) == nil)
        #expect(
            move.conflictingBranch(in: [login, branch("experimental/login", kind: .tag)]) == nil
        )
        #expect(
            move.conflictingBranch(in: [login, branch("experimental/login")])?.name
                == "experimental/login"
        )
        #expect(
            move.conflictingBranch(in: [login, branch("experimental/login/deep")])?.name
                == "experimental/login/deep"
        )
    }

    @Test
    func prefersMainThenMasterAsPrimaryLocalBranch() throws {
        let feature = GitReference(
            name: "feature/sidebar",
            fullName: "refs/heads/feature/sidebar",
            kind: .localBranch,
            target: "111111",
            isCurrent: true
        )
        let master = GitReference(
            name: "master",
            fullName: "refs/heads/master",
            kind: .localBranch,
            target: "222222",
            isCurrent: false
        )
        let remoteMain = GitReference(
            name: "main",
            fullName: "refs/remotes/origin/main",
            kind: .remoteBranch,
            target: "333333",
            isCurrent: false
        )

        #expect(
            GitReference.primaryLocalBranch(in: [feature, master, remoteMain]) == master
        )

        let main = GitReference(
            name: "main",
            fullName: "refs/heads/main",
            kind: .localBranch,
            target: "444444",
            isCurrent: false
        )
        #expect(GitReference.primaryLocalBranch(in: [master, main]) == main)
        #expect(GitReference.primaryLocalBranch(in: [feature, remoteMain]) == nil)
    }

    @Test
    func parsesStashAndNulDelimitedWorktreeRecords() {
        let stashes = GitParser.parseStashes(
            "stash@{0}\u{1f}abcdef\u{1f}On main: sidebar work\u{1e}\n"
                + "stash@{1}\u{1f}123456\u{1f}WIP on main: 111111 Initial\u{1e}\n"
        )
        #expect(stashes.map(\.selector) == ["stash@{0}", "stash@{1}"])
        #expect(stashes[0].id == "abcdef")
        #expect(stashes[0].displayName == "sidebar work")
        #expect(stashes[1].displayName == "WIP on main: 111111 Initial")

        let root = URL(fileURLWithPath: "/tmp/main repository")
        let worktreeOutput = """
        worktree /tmp/main repository\0HEAD abcdef\0branch refs/heads/main\0\0worktree /tmp/linked\0HEAD 123456\0detached\0locked in use\0\0
        """
        let worktrees = GitParser.parseWorktrees(worktreeOutput, currentRoot: root)

        #expect(worktrees.count == 2)
        #expect(worktrees[0].isCurrent)
        #expect(worktrees[0].branchName == "main")
        #expect(worktrees[1].displayName == "linked")
        #expect(worktrees[1].isDetached)
        #expect(worktrees[1].isLocked)
    }

    @Test
    func loadsARealRepositorySnapshotAndDiff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "# Demo\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try "# Demo\n\nChanged\n".write(to: readme, atomically: true, encoding: .utf8)
        let nestedDirectory = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let client = GitClient()
        let discoveredRoot = try await client.repositoryRoot(from: nestedDirectory)
        let snapshot = try await client.snapshot(at: discoveredRoot)

        #expect(discoveredRoot == root.standardizedFileURL)
        #expect(snapshot.branch == "main")
        #expect(snapshot.commits.first?.subject == "Initial commit")
        #expect(snapshot.commits.first?.signature.status == GitSignatureStatus.none)
        #expect(snapshot.changes.first?.path == "README.md")
        #expect(snapshot.changes.first?.isUnstaged == true)
        #expect(snapshot.stashes.isEmpty)
        #expect(snapshot.worktrees.count == 1)
        #expect(snapshot.worktrees[0].isCurrent)

        let diff = try await client.diff(
            at: root,
            change: snapshot.changes[0],
            staged: false
        )
        #expect(diff.contains("+Changed"))
    }

    @Test
    func discardsTrackedAndUntrackedFilesInOneOperation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkDiscardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let tracked = root.appendingPathComponent("tracked.txt")
        let alsoTracked = root.appendingPathComponent("also tracked.txt")
        let kept = root.appendingPathComponent("kept.txt")
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "one\n".write(to: alsoTracked, atomically: true, encoding: .utf8)
        try "one\n".write(to: kept, atomically: true, encoding: .utf8)
        try runGit(["add", "."], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        try "changed\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "changed\n".write(to: alsoTracked, atomically: true, encoding: .utf8)
        try "changed\n".write(to: kept, atomically: true, encoding: .utf8)
        let untracked = root.appendingPathComponent("untracked.txt")
        try "new\n".write(to: untracked, atomically: true, encoding: .utf8)

        let client = GitClient()
        let changes = try await client.snapshot(at: root).changes
        let discarded = changes.filter { $0.path != "kept.txt" }
        #expect(discarded.count == 3)

        try await client.discard(at: root, changes: discarded)

        #expect(try String(contentsOf: tracked, encoding: .utf8) == "one\n")
        #expect(try String(contentsOf: alsoTracked, encoding: .utf8) == "one\n")
        #expect(FileManager.default.fileExists(atPath: untracked.path) == false)
        // Files outside the selection keep their working-tree changes.
        #expect(try String(contentsOf: kept, encoding: .utf8) == "changed\n")
    }

    @Test
    func loadsStashesAndLinkedWorktreesInRepositorySnapshot() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkSidebarTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let linked = container.appendingPathComponent("linked-worktree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "one\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try "two\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["stash", "push", "-m", "sidebar stash"], at: root)
        try runGit(["worktree", "add", "-b", "feature/linked", linked.path], at: root)

        let client = GitClient()
        let snapshot = try await client.snapshot(at: root)
        #expect(snapshot.stashes.count == 1)
        #expect(snapshot.stashes[0].displayName == "sidebar stash")
        #expect(snapshot.worktrees.count == 2)
        #expect(snapshot.worktrees.first(where: \.isCurrent) != nil)
        #expect(
            snapshot.worktrees.first {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath()
                    == linked.resolvingSymlinksInPath()
            }?.branchName == "feature/linked"
        )
        let stashCommit = try await client.commit(
            at: root,
            revision: snapshot.stashes[0].selector
        )
        #expect(stashCommit.hash == snapshot.stashes[0].hash)

        let state = try await client.stateToken(at: root)
        #expect(state.stashes.contains("sidebar stash"))
        #expect(state.worktrees.contains("linked-worktree"))
    }

    @Test
    func recognizesLinkedWorktreesFromTheirFiles() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkLinkedWorktreeTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let linked = container.appendingPathComponent("linked-worktree")
        let submodule = container.appendingPathComponent("submodule")
        let plain = container.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try "one\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try runGit(["worktree", "add", "-b", "feature/linked", linked.path], at: root)

        // A submodule's `.git` file points into `.git/modules`, which has no
        // `commondir`.
        let moduleDirectory = root.appendingPathComponent(".git/modules/submodule")
        try FileManager.default.createDirectory(
            at: moduleDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try "gitdir: \(moduleDirectory.path)\n".write(
            to: submodule.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        #expect(GitWorktree.isLinked(at: linked))
        #expect(!GitWorktree.isLinked(at: root))
        #expect(!GitWorktree.isLinked(at: submodule))
        #expect(!GitWorktree.isLinked(at: plain))

        #expect(
            GitWorktree.mainWorktree(ofLinked: linked)?.resolvingSymlinksInPath().path
                == root.resolvingSymlinksInPath().path
        )
        #expect(GitWorktree.mainWorktree(ofLinked: root) == nil)
        #expect(GitWorktree.mainWorktree(ofLinked: submodule) == nil)

        // A bare repository has no main worktree to name.
        let bare = container.appendingPathComponent("bare.git")
        let bareLinked = container.appendingPathComponent("bare-linked")
        try runGit(["clone", "--bare", root.path, bare.path], at: container)
        try runGit(["worktree", "add", bareLinked.path, "main"], at: bare)
        #expect(GitWorktree.isLinked(at: bareLinked))
        #expect(GitWorktree.mainWorktree(ofLinked: bareLinked) == nil)
    }

    @Test
    @MainActor
    func storeNamesALinkedWorktreeAfterItsMainWorktree() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkWorktreeNameTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let linked = container.appendingPathComponent("linked-worktree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try "one\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try runGit(["worktree", "add", "-b", "feature/linked", linked.path], at: root)

        let store = RepositoryStore()
        store.setMonitoringActive(false)
        store.openRepository(linked)
        try await settle(store)

        #expect(store.repositoryURL?.lastPathComponent == "linked-worktree")
        #expect(store.repositoryName == "repository")

        store.openRepository(root)
        try await settle(store)

        #expect(store.repositoryURL?.lastPathComponent == "repository")
        #expect(store.repositoryName == "repository")
    }

    @Test
    func removesCleanDetachedWorktreeWithoutForce() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkRemoveWorktreeTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let linked = container.appendingPathComponent("detached worktree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(["worktree", "add", "--detach", linked.path, "HEAD"], at: root)

        let client = GitClient()
        let worktree = try #require(
            try await client.snapshot(at: root).worktrees.first {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == linked.standardizedFileURL
            }
        )
        #expect(worktree.isDetached)
        #expect(
            try GitClient.removeWorktreeArguments(for: worktree)
                == ["worktree", "remove", "--", worktree.path]
        )

        try await client.removeWorktree(at: root, worktree: worktree)

        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(try await client.snapshot(at: root).worktrees.count == 1)
    }

    @Test
    func refusesToForceRemoveDirtyDetachedWorktree() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkDirtyWorktreeTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let linked = container.appendingPathComponent("detached-worktree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(["worktree", "add", "--detach", linked.path, "HEAD"], at: root)
        try "keep me\n".write(
            to: linked.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let client = GitClient()
        let worktree = try #require(
            try await client.snapshot(at: root).worktrees.first {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == linked.standardizedFileURL
            }
        )

        do {
            try await client.removeWorktree(at: root, worktree: worktree)
            Issue.record("Plain removal unexpectedly deleted a dirty worktree")
        } catch let error as DirtyWorktreeRemovalError {
            #expect(error.path == worktree.path)
        }
        #expect(FileManager.default.fileExists(atPath: linked.path))
        #expect(
            FileManager.default.fileExists(
                atPath: linked.appendingPathComponent("untracked.txt").path
            )
        )

        #expect(
            try GitClient.removeWorktreeArguments(for: worktree, force: true)
                == ["worktree", "remove", "--force", "--", worktree.path]
        )

        try await client.removeWorktree(at: root, worktree: worktree, force: true)

        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(try await client.snapshot(at: root).worktrees.count == 1)
    }

    /// A worktree holding a branch is exactly the case that blocks branch
    /// deletion, so removing it must be possible and must keep the branch.
    @Test
    func removesWorktreeWithCheckedOutBranchAndKeepsBranch() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkBranchWorktreeTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let linked = container.appendingPathComponent("linked worktree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(["worktree", "add", "-b", "feature/linked", linked.path], at: root)

        let client = GitClient()
        let worktree = try #require(
            try await client.snapshot(at: root).worktrees.first {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == linked.standardizedFileURL
            }
        )
        #expect(!worktree.isDetached)
        #expect(worktree.branchName == "feature/linked")

        let reference = GitReference(
            name: "feature/linked",
            fullName: "refs/heads/feature/linked",
            kind: .localBranch,
            target: "abcdef",
            isCurrent: false
        )

        // Git blocks the branch while the worktree holds it, and the failure
        // must point at the worktree as the way forward.
        do {
            try await client.delete(at: root, reference: reference)
            Issue.record("Deleting a branch held by a worktree unexpectedly succeeded")
        } catch let error as GitOperationError {
            #expect(error.message.contains(linked.lastPathComponent))
            #expect(error.message.contains("Delete that worktree"))
        }

        #expect(
            try GitClient.removeWorktreeArguments(for: worktree)
                == ["worktree", "remove", "--", worktree.path]
        )

        try await client.removeWorktree(at: root, worktree: worktree)

        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(try await client.snapshot(at: root).worktrees.count == 1)
        #expect(
            !(try runGitOutput(["branch", "--list", "feature/linked"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty)
        )

        // Freeing the worktree is what makes the branch deletable again.
        try await client.delete(at: root, reference: reference)

        #expect(
            try runGitOutput(["branch", "--list", "feature/linked"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    @Test
    func prunesMissingWorktreeRegistrationImmediately() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkPruneWorktreeTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let linked = container.appendingPathComponent("stale-worktree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(["worktree", "add", "--detach", linked.path, "HEAD"], at: root)
        try FileManager.default.removeItem(at: linked)

        let client = GitClient()
        let staleWorktree = try #require(
            try await client.snapshot(at: root).worktrees.first(where: \.isPrunable)
        )
        #expect(staleWorktree.isPrunable)
        #expect(staleWorktree.displayName == linked.lastPathComponent)
        #expect(
            GitClient.pruneStaleWorktreeArguments
                == ["worktree", "prune", "--expire", "now"]
        )

        try await client.pruneStaleWorktrees(at: root)

        #expect(try await client.snapshot(at: root).worktrees.count == 1)
    }

    @Test
    func repositoryStateTokenDetectsEditsAndNewBranches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "one\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        let client = GitClient()
        let clean = try await client.stateToken(at: root)

        try "two\n".write(to: readme, atomically: true, encoding: .utf8)
        let edited = try await client.stateToken(at: root)
        #expect(edited != clean)

        try "six\n".write(to: readme, atomically: true, encoding: .utf8)
        let editedAgain = try await client.stateToken(at: root)
        #expect(editedAgain != edited)

        try runGit(["branch", "feature/live-refresh"], at: root)
        let withBranch = try await client.stateToken(at: root)
        #expect(withBranch != editedAgain)
    }

    @Test
    func fullAndWorkingTreeLoadsEstablishEquivalentMonitorTokens() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkMonitorBaselineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let file = root.appendingPathComponent("README.md")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try "two\n".write(to: file, atomically: true, encoding: .utf8)

        let client = GitClient()
        let load = try await client.snapshotAndStateToken(at: root)
        #expect(load.snapshot.changes.first?.path == "README.md")
        #expect(load.stateToken == (try await client.stateToken(at: root)))

        try "three\n".write(to: file, atomically: true, encoding: .utf8)
        let workingTree = try await client.workingTreeSnapshot(at: root)
        let updatedToken = load.stateToken.replacingWorkingTree(with: workingTree)

        #expect(workingTree.changes.first?.path == "README.md")
        #expect(updatedToken == (try await client.stateToken(at: root)))
    }

    @Test
    func appliesSelectedLinesAcrossHunksAndDiscardsACompleteTrackedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkPartialPatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let file = root.appendingPathComponent("lines.txt")
        let originalLines = (1...20).map { "line \($0)" }
        try (originalLines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "lines.txt"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        var editedLines = originalLines
        editedLines[1] = "LINE 2"
        editedLines[14] = "LINE 15"
        try (editedLines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let client = GitClient()
        var snapshot = try await client.snapshot(at: root)
        var change = try #require(snapshot.changes.first { $0.path == "lines.txt" })
        let workingDiff = try await client.diff(at: root, change: change, staged: false)
        let workingDocument = UnifiedDiff(workingDiff)
        let allEditedLines = selectedLineIDs(
            in: workingDocument,
            matching: ["-line 2", "+LINE 2", "-line 15", "+LINE 15"]
        )
        #expect(allEditedLines.count == 4)

        let stagePatch = try #require(
            workingDocument.partialPatch(
                selecting: allEditedLines,
                direction: .forward
            )
        )
        try await client.stage(at: root, patch: stagePatch)
        let stagedAfterStage = try runGitOutput(["diff", "--cached"], at: root)
        #expect(stagedAfterStage.contains("+LINE 2"))
        #expect(stagedAfterStage.contains("+LINE 15"))

        snapshot = try await client.snapshot(at: root)
        change = try #require(snapshot.changes.first { $0.path == "lines.txt" })
        let stagedDiff = try await client.diff(at: root, change: change, staged: true)
        let stagedDocument = UnifiedDiff(stagedDiff)
        let firstReplacement = selectedLineIDs(
            in: stagedDocument,
            matching: ["-line 2", "+LINE 2"]
        )
        let unstagePatch = try #require(
            stagedDocument.partialPatch(
                selecting: firstReplacement,
                direction: .reverse
            )
        )
        try await client.unstage(at: root, patch: unstagePatch)
        let stagedAfterUnstage = try runGitOutput(["diff", "--cached"], at: root)
        #expect(!stagedAfterUnstage.contains("+LINE 2"))
        #expect(stagedAfterUnstage.contains("+LINE 15"))

        snapshot = try await client.snapshot(at: root)
        change = try #require(snapshot.changes.first { $0.path == "lines.txt" })
        let remainingWorkingDiff = try await client.diff(
            at: root,
            change: change,
            staged: false
        )
        let remainingDocument = UnifiedDiff(remainingWorkingDiff)
        let discardSelection = selectedLineIDs(
            in: remainingDocument,
            matching: ["-line 2", "+LINE 2"]
        )
        let discardPatch = try #require(
            remainingDocument.partialPatch(
                selecting: discardSelection,
                direction: .reverse
            )
        )
        try await client.discard(at: root, patch: discardPatch)

        var contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("line 2\n"))
        #expect(contents.contains("LINE 15\n"))

        contents += "unstaged tail\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        snapshot = try await client.snapshot(at: root)
        change = try #require(snapshot.changes.first { $0.path == "lines.txt" })
        try await client.discard(at: root, changes: [change])

        let restored = try String(contentsOf: file, encoding: .utf8)
        #expect(!restored.contains("unstaged tail"))
        #expect(restored.contains("LINE 15\n"))
    }

    @Test
    func resolvesBothModifiedConflictsWithEitherSideOrCurrentContents() async throws {
        let client = GitClient()

        let oursRoot = try prepareBothModifiedConflict(named: "ours")
        defer { try? FileManager.default.removeItem(at: oursRoot) }
        var snapshot = try await client.snapshot(at: oursRoot)
        var conflict = try #require(snapshot.changes.first)
        #expect(conflict.indexStatus == "U")
        #expect(conflict.workTreeStatus == "U")
        #expect(conflict.isConflicted)

        try await client.resolveConflicts(
            at: oursRoot,
            conflicts: [conflict],
            using: .ours
        )
        #expect(
            try String(
                contentsOf: oursRoot.appendingPathComponent("conflict.txt"),
                encoding: .utf8
            ) == "ours\n"
        )
        snapshot = try await client.snapshot(at: oursRoot)
        #expect(!snapshot.changes.contains { $0.isConflicted })

        let theirsRoot = try prepareBothModifiedConflict(named: "theirs")
        defer { try? FileManager.default.removeItem(at: theirsRoot) }
        snapshot = try await client.snapshot(at: theirsRoot)
        conflict = try #require(snapshot.changes.first)
        try await client.resolveConflicts(
            at: theirsRoot,
            conflicts: [conflict],
            using: .theirs
        )
        #expect(
            try String(
                contentsOf: theirsRoot.appendingPathComponent("conflict.txt"),
                encoding: .utf8
            ) == "theirs\n"
        )
        snapshot = try await client.snapshot(at: theirsRoot)
        #expect(!snapshot.changes.contains { $0.isConflicted })
        #expect(snapshot.changes.first?.isStaged == true)

        let manualRoot = try prepareBothModifiedConflict(named: "manual")
        defer { try? FileManager.default.removeItem(at: manualRoot) }
        let manualFile = manualRoot.appendingPathComponent("conflict.txt")
        try "combined resolution\n".write(to: manualFile, atomically: true, encoding: .utf8)
        snapshot = try await client.snapshot(at: manualRoot)
        conflict = try #require(snapshot.changes.first)
        try await client.markConflictsResolved(at: manualRoot, conflicts: [conflict])

        snapshot = try await client.snapshot(at: manualRoot)
        #expect(!snapshot.changes.contains { $0.isConflicted })
        #expect(snapshot.changes.first?.isStaged == true)
        #expect(try runGitOutput(["show", ":conflict.txt"], at: manualRoot) == "combined resolution\n")
    }

    @Test
    func resolvesConflictBlocksOneAtATimeAndStagesOnlyTheFinalChoice() async throws {
        let root = try prepareTwoBlockConflict()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = GitClient()
        var snapshot = try await client.snapshot(at: root)
        var change = try #require(snapshot.changes.first { $0.path == "conflict.txt" })
        var document = try #require(
            try await client.conflictDocument(at: root, change: change)
        )
        #expect(document.conflicts.count == 2)

        try await client.resolveConflictBlock(
            at: root,
            change: change,
            document: document,
            blockID: document.conflicts[0].id,
            using: .ours
        )

        snapshot = try await client.snapshot(at: root)
        change = try #require(snapshot.changes.first { $0.path == "conflict.txt" })
        #expect(change.isConflicted)
        #expect(
            !((try runGitOutput(["ls-files", "-u", "--", "conflict.txt"], at: root))
                .isEmpty)
        )
        document = try #require(
            try await client.conflictDocument(at: root, change: change)
        )
        #expect(document.conflicts.count == 1)
        var contents = try String(
            contentsOf: root.appendingPathComponent("conflict.txt"),
            encoding: .utf8
        )
        #expect(contents.contains("ours line 2"))
        #expect(contents.contains("<<<<<<<"))

        try await client.resolveConflictBlock(
            at: root,
            change: change,
            document: document,
            blockID: document.conflicts[0].id,
            using: .theirs
        )

        snapshot = try await client.snapshot(at: root)
        let resolved = try #require(
            snapshot.changes.first { $0.path == "conflict.txt" }
        )
        #expect(!resolved.isConflicted)
        #expect(resolved.isStaged)
        #expect(
            (try runGitOutput(["ls-files", "-u", "--", "conflict.txt"], at: root))
                .isEmpty
        )
        contents = try String(
            contentsOf: root.appendingPathComponent("conflict.txt"),
            encoding: .utf8
        )
        #expect(contents.contains("ours line 2"))
        #expect(contents.contains("theirs line 32"))
        #expect(!contents.contains("<<<<<<<"))
    }

    @Test
    func refusesToResolveAConflictBlockAfterTheFileChanges() async throws {
        let root = try prepareTwoBlockConflict()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = GitClient()
        let snapshot = try await client.snapshot(at: root)
        let change = try #require(snapshot.changes.first { $0.path == "conflict.txt" })
        let document = try #require(
            try await client.conflictDocument(at: root, change: change)
        )
        let file = root.appendingPathComponent("conflict.txt")
        let externallyEdited = document.text.replacingOccurrences(
            of: "line 10",
            with: "external edit on line 10"
        )
        try externallyEdited.write(to: file, atomically: true, encoding: .utf8)

        do {
            try await client.resolveConflictBlock(
                at: root,
                change: change,
                document: document,
                blockID: document.conflicts[0].id,
                using: .ours
            )
            Issue.record("A stale conflict document unexpectedly overwrote the file")
        } catch let error as GitOperationError {
            #expect(error.message.contains("changed after its conflicts were loaded"))
        }

        #expect(try String(contentsOf: file, encoding: .utf8) == externallyEdited)
        #expect(
            !((try runGitOutput(["ls-files", "-u", "--", "conflict.txt"], at: root))
                .isEmpty)
        )
    }

    @Test
    func choosingAnAbsentConflictSideResolvesThePathAsADeletion() async throws {
        let root = try prepareDeleteModifyConflict(named: "deleted-ours")
        defer { try? FileManager.default.removeItem(at: root) }

        let client = GitClient()
        var snapshot = try await client.snapshot(at: root)
        let conflict = try #require(snapshot.changes.first)
        #expect(conflict.indexStatus == "D")
        #expect(conflict.workTreeStatus == "U")
        #expect(!conflict.hasConflictVersion(.ours))
        #expect(conflict.hasConflictVersion(.theirs))

        try await client.resolveConflicts(
            at: root,
            conflicts: [conflict],
            using: .ours
        )

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("conflict.txt").path))
        snapshot = try await client.snapshot(at: root)
        #expect(!snapshot.changes.contains { $0.isConflicted })
    }

    @Test
    func partiallyStagesAndDiscardsUntrackedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkUntrackedPatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        let client = GitClient()

        let stagedFile = root.appendingPathComponent("partial.txt")
        try "alpha\nbeta\ngamma\n".write(
            to: stagedFile,
            atomically: true,
            encoding: .utf8
        )
        var snapshot = try await client.snapshot(at: root)
        var change = try #require(snapshot.changes.first { $0.path == "partial.txt" })
        let untrackedDiff = try await client.diff(at: root, change: change, staged: false)
        let untrackedDocument = UnifiedDiff(untrackedDiff)
        let betaLine = selectedLineIDs(in: untrackedDocument, matching: ["+beta"])
        let stagePatch = try #require(
            untrackedDocument.partialPatch(selecting: betaLine, direction: .forward)
        )
        try await client.stage(at: root, patch: stagePatch)
        #expect(try runGitOutput(["show", ":partial.txt"], at: root) == "beta\n")
        #expect(try String(contentsOf: stagedFile, encoding: .utf8) == "alpha\nbeta\ngamma\n")

        let fullyStagedFile = root.appendingPathComponent("full staged.txt")
        try "one\ntwo\nthree\n".write(
            to: fullyStagedFile,
            atomically: true,
            encoding: .utf8
        )
        try await client.stage(at: root, paths: ["full staged.txt"])
        snapshot = try await client.snapshot(at: root)
        change = try #require(snapshot.changes.first { $0.path == "full staged.txt" })
        let fullyStagedDiff = try await client.diff(at: root, change: change, staged: true)
        let fullyStagedDocument = UnifiedDiff(fullyStagedDiff)
        let stagedMiddleLine = selectedLineIDs(
            in: fullyStagedDocument,
            matching: ["+two"]
        )
        let partialUnstagePatch = try #require(
            fullyStagedDocument.partialPatch(
                selecting: stagedMiddleLine,
                direction: .reverse,
                treatNewFileAsExisting: true
            )
        )
        try await client.unstage(at: root, patch: partialUnstagePatch)
        #expect(
            try runGitOutput(["show", ":full staged.txt"], at: root)
                == "one\nthree\n"
        )
        #expect(
            try String(contentsOf: fullyStagedFile, encoding: .utf8)
                == "one\ntwo\nthree\n"
        )

        let discardedFile = root.appendingPathComponent("discard.txt")
        try "one\ntwo\nthree\n".write(
            to: discardedFile,
            atomically: true,
            encoding: .utf8
        )
        snapshot = try await client.snapshot(at: root)
        change = try #require(snapshot.changes.first { $0.path == "discard.txt" })
        let discardDiff = try await client.diff(at: root, change: change, staged: false)
        let discardDocument = UnifiedDiff(discardDiff)
        let middleLine = selectedLineIDs(in: discardDocument, matching: ["+two"])
        let discardPatch = try #require(
            discardDocument.partialPatch(
                selecting: middleLine,
                direction: .reverse,
                treatNewFileAsExisting: true
            )
        )
        try await client.discard(at: root, patch: discardPatch)
        #expect(try String(contentsOf: discardedFile, encoding: .utf8) == "one\nthree\n")

        snapshot = try await client.snapshot(at: root)
        change = try #require(snapshot.changes.first { $0.path == "discard.txt" })
        try await client.discard(at: root, changes: [change])
        #expect(!FileManager.default.fileExists(atPath: discardedFile.path))
    }

    @Test
    func buildsUnsignedAndGPGSignedCommitArguments() {
        #expect(
            GitClient.commitArguments(
                message: "Regular commit",
                amend: false,
                signWithGPG: false
            ) == [
                "commit",
                "--no-gpg-sign",
                "-m",
                "Regular commit"
            ]
        )

        #expect(
            GitClient.commitArguments(
                message: "Signed amendment",
                amend: true,
                signWithGPG: true,
                gpgProgram: "/opt/homebrew/bin/gpg"
            ) == [
                "-c",
                "gpg.format=openpgp",
                "-c",
                "gpg.openpgp.program=/opt/homebrew/bin/gpg",
                "commit",
                "--gpg-sign",
                "--amend",
                "-m",
                "Signed amendment"
            ]
        )
    }

    @Test
    func buildsHistoryArgumentsWithoutSignatureVerification() {
        let allHistory = GitClient.historyArguments(revision: nil)
        let branchHistory = GitClient.historyArguments(
            revision: "refs/heads/main",
            offset: GitClient.historyPageSize
        )
        let pathHistory = GitClient.historyArguments(
            revision: "refs/heads/main",
            path: "Sources/-odd name.swift"
        )

        #expect(allHistory.last == "--all")
        #expect(branchHistory.last == "refs/heads/main")
        #expect(
            Array(pathHistory.suffix(4))
                == [
                    "--ignore-missing",
                    "refs/heads/main",
                    "--",
                    ":(literal)Sources/-odd name.swift"
                ]
        )
        #expect(!branchHistory.contains("--ignore-missing"))
        #expect(allHistory.contains("--topo-order"))
        #expect(allHistory.contains("--max-count=300"))
        #expect(!allHistory.contains { $0.hasPrefix("--skip=") })
        #expect(branchHistory.contains("--skip=300"))
        #expect(!allHistory.joined().contains("%G?"))
        #expect(!allHistory.joined().contains("%GK"))
        #expect(!allHistory.joined().contains("%GS"))
    }

    @Test
    func loadsHistoryForAFileOrDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkPathHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Docs"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try "first\n".write(
            to: root.appendingPathComponent("Docs/Guide.md"),
            atomically: true,
            encoding: .utf8
        )
        try "app\n".write(
            to: root.appendingPathComponent("Sources/App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "Docs/Guide.md", "Sources/App.swift"], at: root)
        try runGit(["commit", "-m", "Initial paths"], at: root)

        try "second\n".write(
            to: root.appendingPathComponent("Docs/Guide.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "Docs/Guide.md"], at: root)
        try runGit(["commit", "-m", "Update guide"], at: root)

        try "updated app\n".write(
            to: root.appendingPathComponent("Sources/App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "Sources/App.swift"], at: root)
        try runGit(["commit", "-m", "Update app"], at: root)

        try runGit(["rm", "--", "Docs/Guide.md"], at: root)
        try runGit(["commit", "-m", "Delete guide"], at: root)

        let client = GitClient()
        let directoryHistory = try await client.history(
            at: root,
            scope: .path("Docs", revision: "HEAD")
        )
        let fileHistory = try await client.history(
            at: root,
            scope: .path("Docs/Guide.md", revision: "HEAD")
        )

        #expect(
            directoryHistory.map(\.subject)
                == ["Delete guide", "Update guide", "Initial paths"]
        )
        #expect(fileHistory.map(\.subject) == directoryHistory.map(\.subject))
        #expect(directoryHistory.allSatisfy { $0.signature.status == .none })
    }

    @Test
    func limitsPathHistoryToTheSelectedBranch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkPathHistoryBranchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Docs"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try "first\n".write(
            to: root.appendingPathComponent("Docs/Guide.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "Docs/Guide.md"], at: root)
        try runGit(["commit", "-m", "Initial guide"], at: root)

        try runGit(["checkout", "-b", "feature"], at: root)
        try "feature\n".write(
            to: root.appendingPathComponent("Docs/Guide.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "Docs/Guide.md"], at: root)
        try runGit(["commit", "-m", "Guide on feature"], at: root)
        try runGit(["checkout", "main"], at: root)

        let client = GitClient()
        let mainHistory = try await client.history(
            at: root,
            scope: .path("Docs", revision: "refs/heads/main")
        )
        let featureHistory = try await client.history(
            at: root,
            scope: .path("Docs", revision: "refs/heads/feature")
        )
        let headHistory = try await client.history(
            at: root,
            scope: .path("Docs", revision: "HEAD")
        )
        let deletedBranchHistory = try await client.history(
            at: root,
            scope: .path("Docs", revision: "refs/heads/gone")
        )

        #expect(mainHistory.map(\.subject) == ["Initial guide"])
        #expect(
            featureHistory.map(\.subject) == ["Guide on feature", "Initial guide"]
        )
        #expect(headHistory.map(\.subject) == mainHistory.map(\.subject))
        #expect(deletedBranchHistory.isEmpty)
    }

    @Test
    func loadsEmptyPathHistoryBeforeTheFirstCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkUnbornPathHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)

        let history = try await GitClient().history(
            at: root,
            scope: .path("Docs", revision: "HEAD")
        )

        #expect(history.isEmpty)
    }

    @Test
    func loadsHistoryInNonOverlappingPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkHistoryPaginationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        for number in 1...5 {
            try runGit(
                ["commit", "--allow-empty", "-m", "Commit \(number)"],
                at: root
            )
        }

        let client = GitClient()
        let firstPage = try await client.history(at: root, offset: 0, limit: 2)
        let secondPage = try await client.history(at: root, offset: 2, limit: 2)
        let finalPage = try await client.history(at: root, offset: 4, limit: 2)

        #expect(firstPage.map(\.subject) == ["Commit 5", "Commit 4"])
        #expect(secondPage.map(\.subject) == ["Commit 3", "Commit 2"])
        #expect(finalPage.map(\.subject) == ["Commit 1"])
        #expect(Set((firstPage + secondPage + finalPage).map(\.hash)).count == 5)
    }

    @Test
    @MainActor
    func storeAppendsHistoryPagesUntilTheEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkHistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        for number in 1...5 {
            try runGit(
                ["commit", "--allow-empty", "-m", "Commit \(number)"],
                at: root
            )
        }

        let store = RepositoryStore(historyPageSize: 2)
        store.setMonitoringActive(false)
        store.openRepository(root)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.commits.map(\.subject) == ["Commit 5", "Commit 4"])
        #expect(store.canLoadMoreHistory)

        store.loadMoreHistory()
        for _ in 0..<500 {
            guard store.isLoadingMoreHistory else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            store.commits.map(\.subject)
                == ["Commit 5", "Commit 4", "Commit 3", "Commit 2"]
        )
        #expect(store.canLoadMoreHistory)

        store.loadMoreHistory()
        for _ in 0..<500 {
            guard store.isLoadingMoreHistory else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            store.commits.map(\.subject)
                == ["Commit 5", "Commit 4", "Commit 3", "Commit 2", "Commit 1"]
        )
        #expect(!store.canLoadMoreHistory)

        let main = try #require(
            store.references.first {
                $0.fullName == "refs/heads/main"
            }
        )
        store.selectReference(main)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.commits.map(\.subject) == ["Commit 5", "Commit 4"])
        #expect(store.canLoadMoreHistory)

        store.loadMoreHistory()
        for _ in 0..<500 {
            guard store.isLoadingMoreHistory else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            store.commits.map(\.subject)
                == ["Commit 5", "Commit 4", "Commit 3", "Commit 2"]
        )
    }

    @Test
    @MainActor
    func storeScopesPathHistoryToTheSelectedReference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkPathHistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Docs"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try "first\n".write(
            to: root.appendingPathComponent("Docs/Guide.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "Docs/Guide.md"], at: root)
        try runGit(["commit", "-m", "Initial guide"], at: root)

        try runGit(["checkout", "-b", "feature"], at: root)
        try "feature\n".write(
            to: root.appendingPathComponent("Docs/Guide.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "Docs/Guide.md"], at: root)
        try runGit(["commit", "-m", "Guide on feature"], at: root)
        try runGit(["checkout", "main"], at: root)

        let store = RepositoryStore()
        store.setMonitoringActive(false)
        store.openRepository(root)
        try await settle(store)

        store.selectPathHistory("Docs")
        try await settle(store)
        #expect(store.historyScope == .path("Docs", revision: "HEAD"))
        #expect(store.commits.map(\.subject) == ["Initial guide"])
        #expect(store.pathHistoryReferenceName == "main")

        let feature = try #require(
            store.references.first { $0.fullName == "refs/heads/feature" }
        )
        store.selectReference(feature)
        try await settle(store)

        store.selectPathHistory("Docs")
        try await settle(store)
        #expect(
            store.historyScope == .path("Docs", revision: "refs/heads/feature")
        )
        #expect(
            store.commits.map(\.subject) == ["Guide on feature", "Initial guide"]
        )
        // The reference stays selected: a path history narrows the branch that
        // is already on screen.
        #expect(store.selectedReference == feature)
        #expect(store.pathHistoryReferenceName == "feature")
        #expect(store.errorMessage == nil)
    }

    /// A repository on `main`, with a commit only `feature` has, and a store
    /// that has read it.
    @MainActor
    private func storeWithFeatureBranch(
        historyPageSize: Int = GitClient.historyPageSize
    ) async throws -> (root: URL, store: RepositoryStore, feature: GitReference) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkHistoryFilterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "On main"], at: root)
        try runGit(["checkout", "-b", "feature"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "On feature"], at: root)
        try runGit(["checkout", "main"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Later on main"], at: root)

        let store = RepositoryStore(historyPageSize: historyPageSize)
        store.setMonitoringActive(false)
        store.openRepository(root)
        try await settle(store)
        let feature = try #require(store.references.first { $0.fullName == "refs/heads/feature" })
        return (root, store, feature)
    }

    @Test
    @MainActor
    func historyKeepsItsBranchAcrossTheChanges() async throws {
        let (root, store, feature) = try await storeWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: root) }

        store.selectReference(feature)
        try await settle(store)
        let picked = try #require(store.commits.last)
        store.selectCommit(picked)

        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        store.selectChanges()
        #expect(store.selectedSection == .changes)
        store.refresh()
        try await settle(store)
        #expect(store.changes.map(\.path) == ["new.txt"])

        store.showHistory()
        try await settle(store)
        #expect(store.selectedSection == .history)
        #expect(store.historyScope == .revision("refs/heads/feature"))
        #expect(store.selectedReference?.fullName == "refs/heads/feature")
        #expect(store.commits.map(\.subject) == ["On feature", "On main"])
        #expect(store.selectedCommit?.hash == picked.hash)
        #expect(store.selectedChange == nil)
    }

    @Test
    @MainActor
    func historyCanLoadMoreAfterComingBackFromTheChanges() async throws {
        let (root, store, _) = try await storeWithFeatureBranch(historyPageSize: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.canLoadMoreHistory)

        store.selectChanges()
        store.showHistory()
        #expect(store.canLoadMoreHistory)
        store.loadMoreHistory()
        for _ in 0..<500 {
            guard store.isLoadingMoreHistory else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.commits.count == 3)
    }

    @Test
    @MainActor
    func historyFilterEndsWhenItsBranchIsGone() async throws {
        let (root, store, feature) = try await storeWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: root) }

        store.selectReference(feature)
        try await settle(store)
        store.selectChanges()

        try runGit(["branch", "-D", "feature"], at: root)
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        store.refresh()
        try await settle(store)

        #expect(store.errorMessage == nil)
        #expect(store.changes.map(\.path) == ["new.txt"])
        #expect(store.historyScope == .all)
        #expect(store.selectedReference == nil)
        #expect(store.commits.map(\.subject) == ["Later on main", "On main"])
    }

    @Test
    @MainActor
    func committingKeepsOnlyAFilterThatHasTheNewCommit() async throws {
        let (root, store, feature) = try await storeWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: root) }

        // `feature` is not checked out: the new commit would not show.
        store.selectReference(feature)
        try await settle(store)
        store.selectChanges()
        try "one\n".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "one.txt"], at: root)
        store.refresh()
        try await settle(store)
        store.commitMessage = "First"
        store.createCommit()
        try await settle(store)
        #expect(store.selectedSection == .history)
        #expect(store.historyScope == .all)
        #expect(store.selectedReference == nil)
        #expect(store.commits.first?.subject == "First")

        // `main` is: the filter stays and shows it.
        let main = try #require(store.references.first { $0.fullName == "refs/heads/main" })
        store.selectReference(main)
        try await settle(store)
        store.selectChanges()
        try "two\n".write(to: root.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "two.txt"], at: root)
        store.refresh()
        try await settle(store)
        store.commitMessage = "Second"
        store.createCommit()
        try await settle(store)
        #expect(store.historyScope == .revision("refs/heads/main"))
        #expect(store.commits.first?.subject == "Second")
    }

    @Test
    func parsesLostAndDanglingCommitHashes() {
        let first = String(repeating: "a", count: 40)
        let second = String(repeating: "b", count: 40)
        let output = """
        unreachable commit \(first)
        dangling tree \(String(repeating: "c", count: 40))
        dangling commit \(second)
        unreachable commit \(first)
        notice: HEAD points to an unborn branch
        """

        #expect(
            GitClient.parseLostAndDanglingCommitHashes(output) == [
                first,
                second
            ]
        )
    }

    @Test
    func loadsCommitsAbandonedFromDeletedBranches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkLostCommitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try "main\n".write(
            to: root.appendingPathComponent("main.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "main.txt"], at: root)
        try runGit(["commit", "-m", "Main commit"], at: root)

        try runGit(["switch", "-c", "abandoned"], at: root)
        try "recover me\n".write(
            to: root.appendingPathComponent("lost.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "lost.txt"], at: root)
        try runGit(["commit", "-m", "Recoverable abandoned work"], at: root)
        try runGit(["switch", "main"], at: root)
        try runGit(["branch", "-D", "abandoned"], at: root)

        let commits = try await GitClient().history(
            at: root,
            scope: .lostAndDangling
        )

        #expect(commits.map(\.subject) == ["Recoverable abandoned work"])
        #expect(commits[0].signature.status == .none)
    }

    @Test
    func buildsExplicitNonForcePushAndNonPruningFetchArguments() {
        let existingUpstream = GitPushTarget(
            remote: "origin",
            remoteRef: "refs/heads/main",
            establishesUpstream: false
        )
        let firstPush = GitPushTarget(
            remote: "backup",
            remoteRef: "refs/heads/feature/safe-push",
            establishesUpstream: true
        )

        #expect(
            GitClient.pushArguments(for: existingUpstream)
                == [
                    "-c",
                    "remote.origin.mirror=false",
                    "push",
                    "--no-force",
                    "--no-follow-tags",
                    "--",
                    "origin",
                    "HEAD:refs/heads/main"
                ]
        )
        #expect(
            GitClient.pushArguments(
                for: firstPush,
                sourceRef: "refs/heads/feature/safe-push"
            )
                == [
                    "-c",
                    "remote.backup.mirror=false",
                    "push",
                    "--no-force",
                    "--no-follow-tags",
                    "--set-upstream",
                    "--",
                    "backup",
                    "refs/heads/feature/safe-push:refs/heads/feature/safe-push"
                ]
        )
        #expect(GitClient.fetchArguments() == ["fetch", "--all"])
    }

    @Test
    func buildsReferenceDeletionArguments() throws {
        let branch = GitReference(
            name: "feature/sidebar-delete",
            fullName: "refs/heads/feature/sidebar-delete",
            kind: .localBranch,
            target: "abcdef",
            isCurrent: false
        )
        let tag = GitReference(
            name: "v1.0",
            fullName: "refs/tags/v1.0",
            kind: .tag,
            target: "abcdef",
            isCurrent: false
        )
        let currentBranch = GitReference(
            name: "main",
            fullName: "refs/heads/main",
            kind: .localBranch,
            target: "abcdef",
            isCurrent: true
        )
        let remoteBranch = GitReference(
            name: "origin/main",
            fullName: "refs/remotes/origin/main",
            kind: .remoteBranch,
            target: "abcdef",
            isCurrent: false
        )

        #expect(
            try GitClient.deleteArguments(for: branch)
                == ["branch", "--delete", "--", "feature/sidebar-delete"]
        )
        #expect(
            try GitClient.deleteArguments(for: tag)
                == ["tag", "--delete", "--", "v1.0"]
        )
        #expect(
            try GitClient.forceDeleteArguments(for: branch)
                == ["branch", "-D", "--", "feature/sidebar-delete"]
        )
        #expect(throws: GitOperationError.self) {
            try GitClient.deleteArguments(for: currentBranch)
        }
        #expect(throws: GitOperationError.self) {
            try GitClient.deleteArguments(for: remoteBranch)
        }
        #expect(throws: GitOperationError.self) {
            try GitClient.forceDeleteArguments(for: tag)
        }
        #expect(throws: GitOperationError.self) {
            try GitClient.forceDeleteArguments(for: currentBranch)
        }
        #expect(throws: GitOperationError.self) {
            try GitClient.forceDeleteArguments(for: remoteBranch)
        }
    }

    @Test
    func buildsBranchRenameArguments() throws {
        let branch = GitReference(
            name: "feature/sidebar-rename",
            fullName: "refs/heads/feature/sidebar-rename",
            kind: .localBranch,
            target: "abcdef",
            isCurrent: false
        )
        let currentBranch = GitReference(
            name: "main",
            fullName: "refs/heads/main",
            kind: .localBranch,
            target: "abcdef",
            isCurrent: true
        )
        let remoteBranch = GitReference(
            name: "origin/main",
            fullName: "refs/remotes/origin/main",
            kind: .remoteBranch,
            target: "abcdef",
            isCurrent: false
        )
        let tag = GitReference(
            name: "v1.0",
            fullName: "refs/tags/v1.0",
            kind: .tag,
            target: "abcdef",
            isCurrent: false
        )

        #expect(
            try GitClient.renameArguments(for: branch, to: "feature/renamed")
                == [
                    "branch",
                    "--move",
                    "--",
                    "feature/sidebar-rename",
                    "feature/renamed"
                ]
        )
        #expect(
            try GitClient.renameArguments(for: currentBranch, to: "  trunk  ")
                == ["branch", "--move", "--", "main", "trunk"]
        )
        #expect(throws: GitOperationError.self) {
            try GitClient.renameArguments(for: branch, to: "   ")
        }
        #expect(throws: GitOperationError.self) {
            try GitClient.renameArguments(for: branch, to: "feature/sidebar-rename")
        }
        #expect(throws: GitOperationError.self) {
            try GitClient.renameArguments(for: remoteBranch, to: "main")
        }
        #expect(throws: GitOperationError.self) {
            try GitClient.renameArguments(for: tag, to: "v1.1")
        }
    }

    @Test
    func renamesBranchKeepingUpstreamAndRefusingCollisions() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkBranchRenameTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("work")
        let origin = container.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "--bare", origin.path], at: container)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(["remote", "add", "origin", origin.path], at: root)
        try runGit(["push", "--set-upstream", "origin", "main"], at: root)
        try runGit(["switch", "-c", "feature/old-name"], at: root)
        try runGit(["push", "--set-upstream", "origin", "feature/old-name"], at: root)
        try runGit(["switch", "main"], at: root)

        let client = GitClient()
        let snapshot = try await client.snapshot(at: root)
        let branch = try #require(
            snapshot.references.first { $0.name == "feature/old-name" }
        )
        #expect(branch.upstream?.shortName == "origin/feature/old-name")

        try await client.rename(at: root, reference: branch, to: "feature/new-name")

        let renamedSnapshot = try await client.snapshot(at: root)
        #expect(renamedSnapshot.references.allSatisfy { $0.name != "feature/old-name" })
        let renamed = try #require(
            renamedSnapshot.references.first { $0.name == "feature/new-name" }
        )
        #expect(renamed.kind == .localBranch)
        #expect(renamed.target == branch.target)
        #expect(renamed.upstream?.shortName == "origin/feature/old-name")
        #expect(
            renamedSnapshot.references.contains {
                $0.kind == .remoteBranch && $0.name == "origin/feature/old-name"
            }
        )

        var refusedCollision = false
        do {
            try await client.rename(at: root, reference: renamed, to: "main")
        } catch is GitOperationError {
            refusedCollision = true
        }
        #expect(refusedCollision)
        #expect(
            try runGitOutput(["rev-parse", "--verify", "refs/heads/feature/new-name"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines) == branch.target
        )
    }

    @Test
    func buildsApplyAndDropStashArguments() {
        #expect(
            GitClient.stashArguments(message: "staged", scope: .staged)
                == ["stash", "push", "--staged", "-m", "staged"]
        )
        #expect(
            GitClient.stashArguments(message: "unstaged", scope: .unstaged)
                == [
                    "stash",
                    "push",
                    "--keep-index",
                    "--include-untracked",
                    "-m",
                    "unstaged"
                ]
        )
        #expect(
            GitClient.stashArguments(message: "all", scope: .all)
                == ["stash", "push", "--include-untracked", "-m", "all"]
        )
        #expect(
            GitClient.applyStashArguments(selector: "stash@{2}")
                == ["stash", "apply", "--index", "stash@{2}"]
        )
        #expect(
            GitClient.dropStashArguments(selector: "stash@{2}")
                == ["stash", "drop", "stash@{2}"]
        )
    }

    @Test
    func stashesStagedAndUnstagedScopesIndependently() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkStashScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }

        func prepareRepository(named name: String) throws -> URL {
            let root = container.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try runGit(["init", "-b", "main"], at: root)
            try runGit(["config", "user.name", "GitFork Tests"], at: root)
            try runGit(["config", "user.email", "tests@example.com"], at: root)

            try "base\n".write(
                to: root.appendingPathComponent("staged.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "base\n".write(
                to: root.appendingPathComponent("unstaged.txt"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(["add", "staged.txt", "unstaged.txt"], at: root)
            try runGit(["commit", "-m", "Initial commit"], at: root)

            try "staged\n".write(
                to: root.appendingPathComponent("staged.txt"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(["add", "staged.txt"], at: root)
            try "unstaged\n".write(
                to: root.appendingPathComponent("unstaged.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "untracked\n".write(
                to: root.appendingPathComponent("notes.txt"),
                atomically: true,
                encoding: .utf8
            )
            return root
        }

        let client = GitClient()

        let stagedRoot = try prepareRepository(named: "staged")
        try await client.stash(
            at: stagedRoot,
            message: "staged only",
            scope: .staged
        )
        let afterStaged = try await client.snapshot(at: stagedRoot)
        #expect(!afterStaged.changes.contains { $0.path == "staged.txt" })
        #expect(
            afterStaged.changes.first { $0.path == "unstaged.txt" }?.isUnstaged
                == true
        )
        #expect(
            afterStaged.changes.first { $0.path == "notes.txt" }?.isUntracked
                == true
        )
        #expect(afterStaged.stashes.count == 1)

        let unstagedRoot = try prepareRepository(named: "unstaged")
        try await client.stash(
            at: unstagedRoot,
            message: "unstaged only",
            scope: .unstaged
        )
        let afterUnstaged = try await client.snapshot(at: unstagedRoot)
        let remainingStaged = try #require(
            afterUnstaged.changes.first { $0.path == "staged.txt" }
        )
        #expect(remainingStaged.isStaged)
        #expect(!remainingStaged.isUnstaged)
        #expect(!afterUnstaged.changes.contains { $0.path == "unstaged.txt" })
        #expect(!afterUnstaged.changes.contains { $0.path == "notes.txt" })
        #expect(afterUnstaged.stashes.count == 1)
    }

    @Test
    func rejectsStagedOnlyStashBeforeMixedFileSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkMixedStashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let file = root.appendingPathComponent("mixed.txt")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "mixed.txt"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        try "ONE\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "mixed.txt"], at: root)
        try "ONE\nTWO\n".write(to: file, atomically: true, encoding: .utf8)

        var rejected = false
        do {
            try await GitClient().stash(
                at: root,
                message: "unsafe staged stash",
                scope: .staged
            )
        } catch is GitOperationError {
            rejected = true
        }

        #expect(rejected)
        let snapshot = try await GitClient().snapshot(at: root)
        #expect(snapshot.stashes.isEmpty)
        let mixedChange = try #require(
            snapshot.changes.first { $0.path == "mixed.txt" }
        )
        #expect(mixedChange.isStaged)
        #expect(mixedChange.isUnstaged)
    }

    @Test
    func pushesOnlyToTheConfirmedUpstreamTarget() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkPushTargetTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("work")
        let origin = container.appendingPathComponent("origin.git")
        let backup = container.appendingPathComponent("backup.git")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "--bare", origin.path], at: container)
        try runGit(["init", "--bare", backup.path], at: container)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(["remote", "add", "origin", origin.path], at: root)
        try runGit(["remote", "add", "backup", backup.path], at: root)
        try runGit(["push", "--set-upstream", "origin", "main"], at: root)
        try runGit(["push", "backup", "main"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Next commit"], at: root)
        try runGit(["config", "remote.pushDefault", "backup"], at: root)
        try runGit(["config", "push.default", "current"], at: root)
        try runGit(["config", "push.followTags", "true"], at: root)
        try runGit(["config", "remote.origin.mirror", "true"], at: root)
        try runGit(
            ["config", "--add", "remote.origin.push", "+refs/heads/*:refs/heads/*"],
            at: root
        )
        try runGit(["branch", "must-not-push"], at: root)
        try runGit(["tag", "must-not-follow"], at: root)

        let client = GitClient()
        let snapshot = try await client.snapshot(at: root)
        let target = try #require(snapshot.pushTarget)
        #expect(target.displayName == "origin/main")

        try await client.push(at: root, target: target)

        let head = try runGitOutput(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let originHead = try runGitOutput(["rev-parse", "refs/heads/main"], at: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let backupHead = try runGitOutput(["rev-parse", "refs/heads/main"], at: backup)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(originHead == head)
        #expect(backupHead != head)
        #expect(
            try runGitOutput(["tag", "--list", "must-not-follow"], at: origin)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        #expect(
            try runGitOutput(["branch", "--list", "must-not-push"], at: origin)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )

        try runGit(["switch", "-c", "feature/first-push"], at: root)
        let firstPushSnapshot = try await client.snapshot(at: root)
        let firstPushTarget = try #require(firstPushSnapshot.pushTarget)
        #expect(firstPushTarget.displayName == "backup/feature/first-push")
        #expect(firstPushTarget.establishesUpstream)
        try await client.push(at: root, target: firstPushTarget)
        #expect(
            try runGitOutput(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                at: root
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "backup/feature/first-push"
        )
    }

    @Test
    @MainActor
    func pushesANonCurrentLocalBranchWithoutCheckingItOut() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkSidebarPushTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("work")
        let origin = container.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "--bare", origin.path], at: container)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(["remote", "add", "origin", origin.path], at: root)
        try runGit(["push", "--set-upstream", "origin", "main"], at: root)
        try runGit(["switch", "-c", "feature/sidebar-push"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Sidebar push"], at: root)
        let featureHead = try runGitOutput(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["switch", "main"], at: root)

        let store = RepositoryStore()
        store.setMonitoringActive(false)
        store.openRepository(root)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let branch = try #require(
            store.references.first { $0.name == "feature/sidebar-push" }
        )
        #expect(!branch.isCurrent)
        #expect(branch.upstream == nil)

        store.requestPushConfirmation(for: branch)
        for _ in 0..<500 {
            guard !store.isConfirmingPush, store.errorMessage == nil else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let plan = try #require(store.pendingPushPlan)
        #expect(plan.branchName == "feature/sidebar-push")
        #expect(plan.sourceRef == "refs/heads/feature/sidebar-push")
        #expect(plan.target.displayName == "origin/feature/sidebar-push")
        #expect(plan.target.establishesUpstream)
        #expect(!store.isLoading)

        store.isConfirmingPush = false
        store.push()
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.errorMessage == nil)
        #expect(store.branch == "main")
        #expect(
            try runGitOutput(
                ["rev-parse", "refs/heads/feature/sidebar-push"],
                at: origin
            )
                .trimmingCharacters(in: .whitespacesAndNewlines) == featureHead
        )
        #expect(
            try runGitOutput(
                [
                    "for-each-ref",
                    "--format=%(upstream:short)",
                    "refs/heads/feature/sidebar-push"
                ],
                at: root
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "origin/feature/sidebar-push"
        )
    }

    @Test
    func refusesToReuseLocalBranchTrackingAnotherRemote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkRemoteCheckoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)
        try runGit(
            ["remote", "add", "origin", "https://example.invalid/origin.git"],
            at: root
        )
        try runGit(
            ["remote", "add", "upstream", "https://example.invalid/upstream.git"],
            at: root
        )
        try runGit(["update-ref", "refs/remotes/origin/topic", "HEAD"], at: root)
        try runGit(["update-ref", "refs/remotes/upstream/topic", "HEAD"], at: root)
        try runGit(["branch", "topic"], at: root)
        try runGit(
            ["branch", "--set-upstream-to=upstream/topic", "topic"],
            at: root
        )

        let reference = GitReference(
            name: "origin/topic",
            fullName: "refs/remotes/origin/topic",
            kind: .remoteBranch,
            target: try runGitOutput(["rev-parse", "HEAD"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            isCurrent: false
        )
        var rejected = false
        do {
            try await GitClient().checkout(at: root, reference: reference)
        } catch is GitOperationError {
            rejected = true
        }

        #expect(rejected)
        #expect(
            try runGitOutput(["branch", "--show-current"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "main"
        )

        try runGit(
            ["branch", "--set-upstream-to=origin/topic", "topic"],
            at: root
        )
        try await GitClient().checkout(at: root, reference: reference)
        #expect(
            try runGitOutput(["branch", "--show-current"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "topic"
        )

        try runGit(["switch", "main"], at: root)
        try runGit(["update-ref", "refs/remotes/origin/new-topic", "HEAD"], at: root)
        let newReference = GitReference(
            name: "origin/new-topic",
            fullName: "refs/remotes/origin/new-topic",
            kind: .remoteBranch,
            target: reference.target,
            isCurrent: false
        )
        try await GitClient().checkout(at: root, reference: newReference)
        #expect(
            try runGitOutput(["branch", "--show-current"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "new-topic"
        )
        #expect(
            try runGitOutput(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                at: root
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "origin/new-topic"
        )
    }

    @Test
    @MainActor
    func openingRepositoryChoosesInitialSectionFromWorkingTreeState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkInitialSectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "one\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        let store = RepositoryStore()
        store.setMonitoringActive(false)
        store.openRepository(root)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!store.isLoading)
        #expect(store.selectedSection == .history)

        try "two\n".write(to: readme, atomically: true, encoding: .utf8)
        store.openRepository(root)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!store.isLoading)
        #expect(store.selectedSection == .changes)
        #expect(store.selectedChange?.path == "README.md")
    }

    @Test
    @MainActor
    func serializesRepositoryOperationsAtTheStoreBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkOperationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["commit", "--allow-empty", "-m", "Initial commit"], at: root)

        let store = RepositoryStore()
        store.openRepository(root)
        store.openRepository(root)

        #expect(store.errorMessage?.contains("Wait for Opening repository") == true)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isLoading)
        #expect(store.repositoryURL?.standardizedFileURL == root.standardizedFileURL)
    }

    @Test
    @MainActor
    func refreshingSelectedChangeKeepsExistingDiffUntilReplacementArrives() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkDiffRefreshTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "one\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try "two\n".write(to: readme, atomically: true, encoding: .utf8)

        let store = RepositoryStore()
        store.setMonitoringActive(false)
        store.openRepository(root)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isLoading)

        store.selectChanges()
        for _ in 0..<500 {
            guard !store.diff.contains("+two") else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.diff.contains("+two"))

        var publishedDiffs: [String] = []
        let observation = store.$diff
            .dropFirst()
            .sink { publishedDiffs.append($0) }
        defer { observation.cancel() }

        try "three\n".write(to: readme, atomically: true, encoding: .utf8)
        store.refresh()
        for _ in 0..<500 {
            guard !store.diff.contains("+three") else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.diff.contains("+three"))
        #expect(!publishedDiffs.contains(""))
    }

    @Test
    @MainActor
    func activatingMonitoringChecksForChangesImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkMonitorActivationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "one\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        let store = RepositoryStore(monitorInterval: .seconds(30))
        store.setMonitoringActive(false)
        defer { store.setMonitoringActive(false) }
        store.openRepository(root)
        for _ in 0..<500 {
            guard store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isLoading)
        #expect(store.changes.isEmpty)

        try "two\n".write(to: readme, atomically: true, encoding: .utf8)
        store.setMonitoringActive(true)
        for _ in 0..<500 {
            guard store.changes.isEmpty else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.changes.contains { $0.path == "README.md" })
    }

    @Test
    func appliesAStashWithoutRemovingItThenDropsIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkStashActionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        let untracked = root.appendingPathComponent("notes.txt")
        try "one\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        try "two\n".write(to: readme, atomically: true, encoding: .utf8)
        try "untracked\n".write(to: untracked, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)

        let client = GitClient()
        try await client.stash(at: root, message: "stash actions")
        var snapshot = try await client.snapshot(at: root)
        let stash = try #require(snapshot.stashes.first)

        #expect(
            try String(contentsOf: readme, encoding: .utf8) == "one\n"
        )
        #expect(!FileManager.default.fileExists(atPath: untracked.path))

        try await client.applyStash(at: root, stash: stash)

        #expect(
            try String(contentsOf: readme, encoding: .utf8) == "two\n"
        )
        #expect(FileManager.default.fileExists(atPath: untracked.path))
        #expect(
            try runGitOutput(["diff", "--cached", "--", "README.md"], at: root)
                .contains("+two")
        )

        snapshot = try await client.snapshot(at: root)
        #expect(snapshot.stashes.map(\.id).contains(stash.id))

        try await client.dropStash(at: root, stash: stash)
        snapshot = try await client.snapshot(at: root)
        #expect(snapshot.stashes.isEmpty)
    }

    @Test
    func deletesMergedLocalBranchesAndLocalTags() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkDeleteReferenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "# Delete references\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try runGit(["branch", "feature/delete-me"], at: root)
        try runGit(["tag", "v-delete-me"], at: root)

        let client = GitClient()
        try await client.delete(
            at: root,
            reference: GitReference(
                name: "feature/delete-me",
                fullName: "refs/heads/feature/delete-me",
                kind: .localBranch,
                target: "abcdef",
                isCurrent: false
            )
        )
        try await client.delete(
            at: root,
            reference: GitReference(
                name: "v-delete-me",
                fullName: "refs/tags/v-delete-me",
                kind: .tag,
                target: "abcdef",
                isCurrent: false
            )
        )

        #expect(
            try runGitOutput(
                ["branch", "--list", "feature/delete-me"],
                at: root
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        #expect(
            try runGitOutput(
                ["tag", "--list", "v-delete-me"],
                at: root
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    @Test
    func deletesTrackedRemoteBranchAlongsideLocalBranch() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkDeleteRemoteBranchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let remote = container.appendingPathComponent("remote.git")
        let root = container.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--bare", "-b", "main"], at: remote)

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["remote", "add", "origin", remote.path], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "# Delete remote branch\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try runGit(["push", "-u", "origin", "main"], at: root)
        try runGit(["switch", "-c", "feature/remote-delete"], at: root)
        try runGit(["push", "-u", "origin", "feature/remote-delete"], at: root)
        try runGit(["switch", "main"], at: root)

        let client = GitClient()
        let snapshot = try await client.snapshot(at: root)
        let reference = try #require(
            snapshot.references.first {
                $0.kind == .localBranch && $0.name == "feature/remote-delete"
            }
        )
        let upstream = try #require(reference.upstream)
        #expect(upstream.shortName == "origin/feature/remote-delete")

        try await client.delete(at: root, reference: reference)
        try await client.deleteRemoteBranch(at: root, upstream: upstream)

        #expect(
            try runGitOutput(["branch", "--list", reference.name], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        #expect(
            try runGitOutput(["ls-remote", "--heads", "origin"], at: root)
                .contains("refs/heads/main")
        )
        #expect(
            !(try runGitOutput(["ls-remote", "--heads", "origin"], at: root)
                .contains("refs/heads/feature/remote-delete"))
        )
    }

    @Test
    func deletesRemoteBranchWithoutALocalCounterpart() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkDeleteRemoteOnlyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let remote = container.appendingPathComponent("remote.git")
        let root = container.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--bare", "-b", "main"], at: remote)

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try runGit(["remote", "add", "origin", remote.path], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "# Delete remote only\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try runGit(["push", "-u", "origin", "main"], at: root)
        try runGit(["switch", "-c", "feature/remote-only"], at: root)
        try runGit(["push", "-u", "origin", "feature/remote-only"], at: root)
        try runGit(["switch", "main"], at: root)
        // Leave only the remote-tracking ref behind, as a fetched branch that
        // was never checked out would appear.
        try runGit(["branch", "-D", "feature/remote-only"], at: root)

        let client = GitClient()
        let snapshot = try await client.snapshot(at: root)
        let reference = try #require(
            snapshot.references.first {
                $0.kind == .remoteBranch && $0.name == "origin/feature/remote-only"
            }
        )
        let target = try #require(reference.remoteBranchTarget)

        try await client.deleteRemoteBranch(at: root, upstream: target)

        let heads = try runGitOutput(["ls-remote", "--heads", "origin"], at: root)
        #expect(heads.contains("refs/heads/main"))
        #expect(!heads.contains("refs/heads/feature/remote-only"))
        #expect(
            try runGitOutput(["branch", "--remotes", "--list", reference.name], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    @Test
    func requiresForceToDeleteUnmergedLocalBranch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkForceDeleteBranchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)

        let readme = root.appendingPathComponent("README.md")
        try "main\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)
        try runGit(["switch", "-c", "feature/unmerged"], at: root)

        let feature = root.appendingPathComponent("feature.txt")
        try "unmerged\n".write(to: feature, atomically: true, encoding: .utf8)
        try runGit(["add", "feature.txt"], at: root)
        try runGit(["commit", "-m", "Unmerged commit"], at: root)
        try runGit(["switch", "main"], at: root)

        let reference = GitReference(
            name: "feature/unmerged",
            fullName: "refs/heads/feature/unmerged",
            kind: .localBranch,
            target: "abcdef",
            isCurrent: false
        )
        let client = GitClient()

        do {
            try await client.delete(at: root, reference: reference)
            Issue.record("Safe deletion unexpectedly deleted an unmerged branch")
        } catch let error as UnmergedBranchDeletionError {
            #expect(error.branch == reference.name)
            #expect(error.message.contains("is not fully merged"))
        }

        #expect(
            !(try runGitOutput(["branch", "--list", reference.name], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty)
        )

        try await client.forceDelete(at: root, reference: reference)

        #expect(
            try runGitOutput(["branch", "--list", reference.name], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    @Test
    func resolvesExecutablesFromAugmentedGUIPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkGPGTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let fakeGPG = bin.appendingPathComponent("gpg")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: fakeGPG)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGPG.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let searchPath = GitClient.commandSearchPath(
            inheritedPath: bin.path,
            homeDirectory: root
        )
        let resolved = GitClient.executableURL(
            named: "gpg",
            searchPath: searchPath,
            workingDirectory: root
        )

        #expect(resolved == fakeGPG.standardizedFileURL)
        #expect(searchPath.contains("/opt/homebrew/bin"))
        #expect(searchPath.contains("/usr/local/bin"))
    }

    @Test
    func readsTheFilesGitWouldOverwriteFromItsMessage() {
        let message = """
        error: Your local changes to the following files would be overwritten by checkout:
        \ta.txt
        \tsub dir/b.txt
        Please commit your changes or stash them before you switch branches.
        error: The following untracked working tree files would be overwritten by checkout:
        \tc.txt
        Please move or remove them before you switch branches.
        Aborting
        """
        #expect(GitClient.overwrittenFiles(in: message) == ["a.txt", "sub dir/b.txt", "c.txt"])
        #expect(GitClient.overwrittenFiles(in: "fatal: 'x' is already used by worktree at '/y'") == nil)
    }

    /// A repository on `main`, with `feature` changing `a.txt` and adding
    /// `c.txt`. `b.txt` is the same on both.
    private func prepareBranches(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkSwitchTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try configureConflictRepository(at: root)
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], at: root)
        try runGit(["commit", "-m", "first"], at: root)
        try runGit(["switch", "-c", "feature"], at: root)
        try "two\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], at: root)
        try runGit(["commit", "-m", "second"], at: root)
        try runGit(["switch", "main"], at: root)
        return root
    }

    @MainActor
    private func openedStore(_ root: URL) async throws -> RepositoryStore {
        let store = RepositoryStore()
        store.setMonitoringActive(false)
        store.openRepository(root)
        try await settle(store)
        return store
    }

    @Test
    @MainActor
    func switchingCarriesChangesThatAreNotInTheWay() async throws {
        let root = try prepareBranches(named: "carry")
        defer { try? FileManager.default.removeItem(at: root) }
        try "changed\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let store = try await openedStore(root)
        let feature = try #require(store.references.first { $0.name == "feature" })
        store.checkout(feature)
        try await settle(store)

        #expect(store.pendingCheckout == nil)
        #expect(store.errorMessage == nil)
        #expect(store.branch == "feature")
        #expect(store.changes.map(\.path) == ["b.txt"])
        #expect(store.stashes.isEmpty)
    }

    @Test
    @MainActor
    func switchingAsksBeforeTouchingChangesInTheWayAndCanStashThem() async throws {
        let root = try prepareBranches(named: "stash")
        defer { try? FileManager.default.removeItem(at: root) }
        try "local\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let store = try await openedStore(root)
        let feature = try #require(store.references.first { $0.name == "feature" })
        store.checkout(feature)
        try await settle(store)

        #expect(store.errorMessage == nil)
        #expect(store.branch == "main")
        #expect(store.pendingCheckout == PendingCheckout(reference: feature, reason: .overwrites(["a.txt", "c.txt"])))
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "local\n")

        store.stashAndCheckout()
        try await settle(store)

        #expect(store.errorMessage == nil)
        #expect(store.pendingCheckout == nil)
        #expect(store.branch == "feature")
        #expect(store.changes.isEmpty)
        #expect(store.stashes.map(\.displayName) == ["Before switching to feature"])
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "two\n")
    }

    @Test
    @MainActor
    func cancellingASwitchLeavesEverythingAsItWas() async throws {
        let root = try prepareBranches(named: "cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try "local\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let store = try await openedStore(root)
        let feature = try #require(store.references.first { $0.name == "feature" })
        store.checkout(feature)
        try await settle(store)
        #expect(store.pendingCheckout != nil)

        store.cancelCheckout()
        try await settle(store)

        #expect(store.pendingCheckout == nil)
        #expect(store.branch == "main")
        #expect(store.stashes.isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "local\n")
    }

    @Test
    @MainActor
    func switchingAsksFirstWhileAgentsWorkInTheWorktree() async throws {
        let root = try prepareBranches(named: "agents")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await openedStore(root)
        var asked: [URL] = []
        var agents = ["Claude “Fix it”"]
        store.agentsWorking = {
            asked.append($0)
            return agents
        }
        let feature = try #require(store.references.first { $0.name == "feature" })

        // It asks, and nothing happened yet.
        store.checkout(feature)
        #expect(!store.isLoading)
        #expect(asked == [store.repositoryURL])
        #expect(store.pendingCheckout == PendingCheckout(reference: feature, reason: .agentsWorking(agents)))
        #expect(store.branch == "main")

        // Stashing is for another question.
        store.stashAndCheckout()
        #expect(!store.isLoading)
        #expect(store.pendingCheckout != nil)

        // Cancel leaves it as it was.
        store.cancelCheckout()
        #expect(store.pendingCheckout == nil)
        #expect(store.branch == "main")

        // Switch Anyway switches.
        store.checkout(feature)
        store.checkoutDespiteAgents()
        try await settle(store)
        #expect(store.pendingCheckout == nil)
        #expect(store.branch == "feature")

        // Once the agent is done, there is nothing to ask.
        agents = []
        let main = try #require(store.references.first { $0.name == "main" })
        store.checkout(main)
        #expect(store.pendingCheckout == nil)
        try await settle(store)
        #expect(store.branch == "main")
    }

    @Test
    @MainActor
    func switchAnywayStillAsksAboutChangesInTheWay() async throws {
        let root = try prepareBranches(named: "both")
        defer { try? FileManager.default.removeItem(at: root) }
        try "local\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let store = try await openedStore(root)
        store.agentsWorking = { _ in ["Claude “Fix it”"] }
        let feature = try #require(store.references.first { $0.name == "feature" })
        store.checkout(feature)
        store.checkoutDespiteAgents()
        try await settle(store)

        #expect(store.pendingCheckout == PendingCheckout(reference: feature, reason: .overwrites(["a.txt"])))
        #expect(store.branch == "main")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "local\n")
    }

    @Test
    func newBranchStartsAtThePickedBranchAndChecksOutOnlyIfAsked() async throws {
        let root = try prepareBranches(named: "new-branch")
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["update-ref", "refs/remotes/origin/feature", "feature"], at: root)
        func output(_ arguments: [String]) throws -> String {
            try runGitCommand(arguments, at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let featureHash = try output(["rev-parse", "feature"])
        let mainHash = try output(["rev-parse", "main"])
        let feature = GitReference(
            name: "feature", fullName: "refs/heads/feature", kind: .localBranch,
            target: featureHash, isCurrent: false
        )
        let remote = GitReference(
            name: "origin/feature", fullName: "refs/remotes/origin/feature", kind: .remoteBranch,
            target: featureHash, isCurrent: false
        )
        let client = GitClient()

        // Without the checkout, HEAD stays.
        try await client.createBranch(at: root, name: "stays", from: feature, checkout: false)
        #expect(try output(["rev-parse", "stays"]) == featureHash)
        #expect(try output(["branch", "--show-current"]) == "main")

        // At HEAD, without the checkout.
        try await client.createBranch(at: root, name: "at-head", checkout: false)
        #expect(try output(["rev-parse", "at-head"]) == mainHash)
        #expect(try output(["branch", "--show-current"]) == "main")

        // From a remote branch: it doesn't take that branch as its upstream.
        try await client.createBranch(at: root, name: "from-remote", from: remote, checkout: false)
        #expect(try output(["rev-parse", "from-remote"]) == featureHash)
        #expect(try output(["for-each-ref", "--format=%(upstream)", "refs/heads/from-remote"]).isEmpty)

        try await client.createBranch(at: root, name: "moved", from: remote)
        #expect(try output(["branch", "--show-current"]) == "moved")
        #expect(try output(["rev-parse", "HEAD"]) == featureHash)
        #expect(try output(["for-each-ref", "--format=%(upstream)", "refs/heads/moved"]).isEmpty)
    }

    @Test
    @MainActor
    func newBranchWithCheckoutAsksLikeASwitch() async throws {
        let root = try prepareBranches(named: "new-branch-asks")
        defer { try? FileManager.default.removeItem(at: root) }
        try "local\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let store = try await openedStore(root)
        store.agentsWorking = { _ in ["Claude “Fix it”"] }
        let feature = try #require(store.references.first { $0.name == "feature" })
        let main = try #require(store.references.first { $0.isCurrent })

        // No switch, or a switch that changes no files: nothing to ask.
        store.createBranch(named: "stays", from: feature, checkout: false)
        #expect(store.pendingCheckout == nil)
        try await settle(store)
        #expect(store.branch == "main")
        #expect(store.references.contains { $0.name == "stays" })
        store.createBranch(named: "same-files", from: main)
        #expect(store.pendingCheckout == nil)
        try await settle(store)
        #expect(store.branch == "same-files")
        try runGit(["switch", "main"], at: root)
        try await settle(store)
        store.refresh()
        try await settle(store)

        // Agents work there: it asks, and nothing happened yet.
        store.createBranch(named: "moved", from: feature)
        #expect(store.pendingCheckout == PendingCheckout(reference: feature, newBranch: "moved", reason: .agentsWorking(["Claude “Fix it”"])))
        #expect(store.pendingCheckout?.destination == "moved")
        #expect(!store.references.contains { $0.name == "moved" })

        // Switch Anyway meets the changes in the way, and asks about those.
        store.checkoutDespiteAgents()
        try await settle(store)
        #expect(store.pendingCheckout == PendingCheckout(reference: feature, newBranch: "moved", reason: .overwrites(["a.txt"])))
        #expect(store.branch == "main")
        #expect(!store.references.contains { $0.name == "moved" })

        // Stash and Switch ends on the new branch, with the changes stashed.
        store.stashAndCheckout()
        try await settle(store)
        #expect(store.errorMessage == nil)
        #expect(store.pendingCheckout == nil)
        #expect(store.branch == "moved")
        #expect(store.stashes.count == 1)
    }

    @Test
    @MainActor
    func switchingToTheCurrentBranchDoesNothing() async throws {
        let root = try prepareBranches(named: "current")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await openedStore(root)
        let main = try #require(store.references.first { $0.isCurrent })
        store.checkout(main)

        #expect(!store.isLoading)
        #expect(store.branch == "main")
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        _ = try runGitCommand(arguments, at: root)
    }

    private func settle(_ store: RepositoryStore) async throws {
        for _ in 0..<500 {
            guard await store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func prepareBothModifiedConflict(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkConflictTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try configureConflictRepository(at: root)
            let file = root.appendingPathComponent("conflict.txt")
            try "base\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "conflict.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)

            try runGit(["switch", "-c", "incoming"], at: root)
            try "theirs\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["commit", "-am", "Incoming change"], at: root)

            try runGit(["switch", "main"], at: root)
            try "ours\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["commit", "-am", "Our change"], at: root)
            try expectMergeConflict(at: root)
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func prepareDeleteModifyConflict(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkConflictTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try configureConflictRepository(at: root)
            let file = root.appendingPathComponent("conflict.txt")
            try "base\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "conflict.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)

            try runGit(["switch", "-c", "incoming"], at: root)
            try "theirs\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["commit", "-am", "Incoming change"], at: root)

            try runGit(["switch", "main"], at: root)
            try runGit(["rm", "conflict.txt"], at: root)
            try runGit(["commit", "-m", "Delete on ours"], at: root)
            try expectMergeConflict(at: root)
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func prepareTwoBlockConflict() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkConflictBlockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try configureConflictRepository(at: root)
            let file = root.appendingPathComponent("conflict.txt")
            let baseLines = (1...40).map { "line \($0)" }
            try (baseLines.joined(separator: "\n") + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "conflict.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)

            try runGit(["switch", "-c", "incoming"], at: root)
            var theirs = baseLines
            theirs[1] = "theirs line 2"
            theirs[31] = "theirs line 32"
            try (theirs.joined(separator: "\n") + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            try runGit(["commit", "-am", "Incoming changes"], at: root)

            try runGit(["switch", "main"], at: root)
            var ours = baseLines
            ours[1] = "ours line 2"
            ours[31] = "ours line 32"
            try (ours.joined(separator: "\n") + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            try runGit(["commit", "-am", "Our changes"], at: root)
            try expectMergeConflict(at: root)
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func configureConflictRepository(at root: URL) throws {
        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
    }

    private func expectMergeConflict(at root: URL) throws {
        do {
            try runGit(["merge", "incoming"], at: root)
            throw GitOperationError(
                command: "git merge incoming",
                message: "Expected the fixture merge to conflict."
            )
        } catch let error as GitOperationError {
            guard !error.message.contains("Expected the fixture merge") else {
                throw error
            }
        }
    }

    private func runGitOutput(_ arguments: [String], at root: URL) throws -> String {
        try runGitCommand(arguments, at: root)
    }

    private func runGitCommand(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw GitOperationError(command: "git \(arguments.joined(separator: " "))", message: message)
        }

        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    }

    private func selectedLineIDs(
        in document: UnifiedDiff,
        matching texts: Set<String>
    ) -> Set<Int> {
        Set(document.lines.filter { texts.contains($0.text) }.map(\.id))
    }
}

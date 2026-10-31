import Foundation
import Testing
@testable import agentz

struct CommitHashPickerTests {
    @Test
    func normalizesHashesAndRejectsNonHashInput() {
        #expect(CommitHashQuery.normalized("  C6A1CC9  ") == "c6a1cc9")
        #expect(
            CommitHashQuery.normalized(String(repeating: "a", count: 40))
                == String(repeating: "a", count: 40)
        )
        #expect(CommitHashQuery.normalized("c6a") == nil)
        #expect(CommitHashQuery.normalized("HEAD~1") == nil)
        #expect(CommitHashQuery.normalized("refs/heads/main") == nil)
        #expect(CommitHashQuery.normalized(String(repeating: "a", count: 65)) == nil)
        #expect(CommitHashQuery.normalized("") == nil)
    }

    @Test
    func matchesLoadedCommitsByHashPrefix() {
        let first = commit("c6a1cc99de73f5d891dd72d41cfab2555495384f")
        let second = commit("c6a2b13723e0a4f4cd0b2f4a2d3c1e5b6a7f8091")
        let third = commit("b13723ee0eca27b447d62278a4d8f0c1e2b3a4d5")
        let commits = [first, second, third]

        #expect(
            CommitHashPickerSearch.matches(commits, query: "c6a") == [first, second]
        )
        #expect(CommitHashPickerSearch.matches(commits, query: " C6A1 ") == [first])
        #expect(CommitHashPickerSearch.matches(commits, query: "zzz") == [])
        #expect(CommitHashPickerSearch.matches(commits, query: "  ") == commits)
        #expect(
            CommitHashPickerSearch.matches(commits, query: "", limit: 2)
                == [first, second]
        )
    }

    @Test
    func reconcilesAndWrapsKeyboardSelection() {
        let first = commit("aaaa111122223333444455556666777788889999")
        let second = commit("bbbb111122223333444455556666777788889999")
        let third = commit("cccc111122223333444455556666777788889999")
        let commits = [first, second, third]

        #expect(
            CommitHashPickerNavigation.reconcile(
                selection: second,
                commits: commits
            ) == second
        )
        #expect(
            CommitHashPickerNavigation.reconcile(
                selection: second,
                commits: [first, third]
            ) == first
        )
        #expect(
            CommitHashPickerNavigation.move(
                selection: first,
                offset: -1,
                commits: commits
            ) == third
        )
        #expect(
            CommitHashPickerNavigation.move(
                selection: third,
                offset: 1,
                commits: commits
            ) == first
        )
        #expect(
            CommitHashPickerNavigation.move(
                selection: nil,
                offset: 1,
                commits: []
            ) == nil
        )
    }

    @Test
    func explainsWhyAHashLookupFailed() {
        #expect(
            GitClient.commitLookupMessage(
                for: "c6a1",
                error: "error: short object ID c6a1 is ambiguous\n"
            ) == "“c6a1” matches more than one object. Type more of the hash."
        )
        #expect(
            GitClient.commitLookupMessage(
                for: "deadbee",
                error: "fatal: Needed a single revision\n"
            ) == "No commit in this repository matches “deadbee”."
        )
    }

    @Test
    func resolvesShortAndFullHashesIncludingUnreachableCommits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkCommitHashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        try "first\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial commit"], at: root)

        try "second\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", "README.md"], at: root)
        try runGit(["commit", "-m", "Unreachable work"], at: root)
        let unreachableHash = try runGitOutput(["rev-parse", "HEAD"], at: root)
        try runGit(["reset", "--hard", "HEAD~1"], at: root)

        let headHash = try runGitOutput(["rev-parse", "HEAD"], at: root)
        let client = GitClient()

        let fromFullHash = try await client.commit(at: root, matchingHash: headHash)
        let fromShortHash = try await client.commit(
            at: root,
            matchingHash: String(headHash.prefix(7))
        )
        let unreachable = try await client.commit(
            at: root,
            matchingHash: String(unreachableHash.prefix(7))
        )

        #expect(fromFullHash.hash == headHash)
        #expect(fromShortHash.hash == headHash)
        #expect(fromFullHash.subject == "Initial commit")
        #expect(unreachable.hash == unreachableHash)
        #expect(unreachable.subject == "Unreachable work")

        await #expect(throws: GitOperationError.self) {
            try await client.commit(at: root, matchingHash: "deadbeef")
        }
    }

    @Test
    @MainActor
    func opensLoadedCommitsInPlaceAndNarrowsHistoryForOlderOnes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkOpenCommitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "GitFork Tests"], at: root)
        try runGit(["config", "user.email", "tests@example.com"], at: root)
        for number in 1...5 {
            try runGit(["commit", "--allow-empty", "-m", "Commit \(number)"], at: root)
        }
        let fourthHash = try runGitOutput(["rev-parse", "HEAD~1"], at: root)
        let secondHash = try runGitOutput(["rev-parse", "HEAD~3"], at: root)

        let store = RepositoryStore(historyPageSize: 2)
        store.setMonitoringActive(false)
        store.openRepository(root)
        try await settle(store)
        #expect(store.commits.map(\.subject) == ["Commit 5", "Commit 4"])

        let olderCommit = try await store.lookUpCommit(hash: String(secondHash.prefix(7)))
        #expect(olderCommit.hash == secondHash)
        #expect(olderCommit.subject == "Commit 2")
        #expect(store.commits.map(\.subject) == ["Commit 5", "Commit 4"])
        await #expect(throws: GitOperationError.self) {
            try await store.lookUpCommit(hash: "deadbeef")
        }

        store.openCommit(hash: String(fourthHash.prefix(7)))
        try await settle(store)
        #expect(store.historyScope == .all)
        #expect(store.commits.map(\.subject) == ["Commit 5", "Commit 4"])
        #expect(store.selectedCommit?.hash == fourthHash)
        #expect(store.commitReveal?.hash == fourthHash)

        store.openCommit(hash: secondHash)
        try await settle(store)
        #expect(store.historyScope == .commit(secondHash))
        #expect(store.commits.map(\.subject) == ["Commit 2", "Commit 1"])
        #expect(store.selectedCommit?.hash == secondHash)
        #expect(store.commitReveal?.hash == secondHash)
        #expect(store.errorMessage == nil)

        store.openCommit(hash: "HEAD~1")
        #expect(!store.isLoading)
        #expect(store.errorMessage != nil)
        #expect(store.historyScope == .commit(secondHash))
    }

    private func settle(_ store: RepositoryStore) async throws {
        for _ in 0..<500 {
            guard await store.isLoading else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func commit(_ hash: String) -> GitCommit {
        GitCommit(
            hash: hash,
            parents: [],
            authorName: "GitFork Tests",
            authorEmail: "tests@example.com",
            date: .distantPast,
            decorations: [],
            signature: .unsigned,
            subject: "Commit \(hash.prefix(8))"
        )
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        _ = try runGitCommand(arguments, at: root)
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
            throw GitOperationError(
                command: "git \(arguments.joined(separator: " "))",
                message: message
            )
        }

        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation
import Testing
@testable import agentz

/// The commit and branch actions of the history, run against real
/// repositories.
struct HistoryActionTests {
    @Test
    func rewritesCommitsAsPlanned() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        try repo.commit("b.txt", "b\n", "B")
        try repo.commit("c.txt", "c\n", "C")
        try repo.commit("d.txt", "d\n", "D")
        try repo.commit("e.txt", "e\n", "E")

        let client = GitClient()
        let b = try repo.hash("HEAD~3")
        var plan = try await client.rebasePlan(at: repo.root, from: b, warning: nil)
        #expect(plan.steps.map(\.commit.subject) == ["E", "D", "C", "B"])
        #expect(plan.steps.last?.message == "B")
        #expect(!plan.changesSomething)

        // Newest first: E, D, C, B.
        plan.steps[3].action = .reword
        plan.steps[3].message = "B again\n\nWith a body."
        plan.steps[2].action = .fixup
        plan.steps[1].action = .drop
        plan.steps.swapAt(0, 1)
        #expect(plan.changesSomething)
        #expect(plan.problem == nil)
        try await client.rewrite(at: repo.root, plan: plan)

        #expect(try repo.subjects() == ["E", "B again", "A"])
        #expect(try repo.git(["log", "-1", "--format=%B", "HEAD~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
            == "B again\n\nWith a body.")
        #expect(try repo.files() == ["a.txt", "b.txt", "c.txt", "e.txt"])
        #expect(GitClient.operationInProgress(at: repo.root) == nil)
    }

    @Test
    func squashKeepsBothMessagesAndRewritesTheRootCommit() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        try repo.commit("b.txt", "b\n", "B")

        let client = GitClient()
        var plan = try await client.rebasePlan(at: repo.root, from: try repo.hash("HEAD~1"), warning: nil)
        #expect(plan.base == nil)
        #expect(plan.set(try repo.hash("HEAD"), to: .squash))
        try await client.rewrite(at: repo.root, plan: plan)

        #expect(try repo.subjects() == ["A"])
        let message = try repo.git(["log", "-1", "--format=%B"])
        #expect(message.contains("A") && message.contains("B") && !message.contains("#"))
    }

    @Test
    func aFoldWithNothingBeforeItIsAProblem() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        try repo.commit("b.txt", "b\n", "B")

        var plan = try await GitClient().rebasePlan(at: repo.root, from: try repo.hash("HEAD~1"), warning: nil)
        plan.steps[1].action = .fixup
        #expect(plan.problem != nil)
        plan.steps[1].action = .reword
        plan.steps[1].message = "  "
        #expect(plan.problem != nil)
    }

    @Test
    func refusesCommitsOutsideTheBranchAndMergesInTheWay() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        try repo.git(["switch", "-c", "side"])
        try repo.commit("s.txt", "s\n", "S")
        let side = try repo.hash("HEAD")
        try repo.git(["switch", "main"])
        try repo.commit("b.txt", "b\n", "B")
        let b = try repo.hash("HEAD")

        let client = GitClient()
        await #expect(throws: GitOperationError.self) {
            _ = try await client.rebasePlan(at: repo.root, from: side, warning: nil)
        }
        try repo.git(["merge", "--no-ff", "--no-edit", "side"])
        await #expect(throws: GitOperationError.self) {
            _ = try await client.rebasePlan(at: repo.root, from: b, warning: nil)
        }
    }

    @Test
    func keepsUncommittedChangesThroughARewrite() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        try repo.commit("b.txt", "b\n", "B")
        try "changed\n".write(to: repo.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let client = GitClient()
        var plan = try await client.rebasePlan(at: repo.root, from: try repo.hash("HEAD"), warning: nil)
        plan.set(try repo.hash("HEAD"), to: .drop)
        try await client.rewrite(at: repo.root, plan: plan)

        #expect(try repo.subjects() == ["A"])
        #expect(try String(contentsOf: repo.root.appendingPathComponent("a.txt"), encoding: .utf8) == "changed\n")
    }

    @Test
    func rewordingHeadKeepsStagedChanges() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        try "staged\n".write(to: repo.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try repo.git(["add", "a.txt"])

        try await GitClient().rewordHead(at: repo.root, message: "New A")

        #expect(try repo.subjects() == ["New A"])
        #expect(try repo.git(["diff", "--cached", "--name-only"]).contains("a.txt"))
    }

    @Test
    func aConflictStopsAndAbortGoesBack() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "A")
        try repo.git(["switch", "-c", "side"])
        try repo.commit("a.txt", "side\n", "Side")
        let sideCommit = try await GitClient().commit(at: repo.root, revision: "HEAD")
        try repo.git(["switch", "main"])
        try repo.commit("a.txt", "main\n", "Main")
        let before = try repo.hash("HEAD")

        let client = GitClient()
        await #expect(throws: GitOperationError.self) {
            try await client.cherryPick(at: repo.root, commit: sideCommit)
        }
        #expect(GitClient.operationInProgress(at: repo.root) == .cherryPick)
        try await client.abortOperation(at: repo.root, .cherryPick)
        #expect(GitClient.operationInProgress(at: repo.root) == nil)
        #expect(try repo.hash("HEAD") == before)

        let side = GitReference(name: "side", fullName: "refs/heads/side", kind: .localBranch,
                                target: sideCommit.hash, isCurrent: false)
        await #expect(throws: GitOperationError.self) {
            try await client.rebase(at: repo.root, onto: side)
        }
        #expect(GitClient.operationInProgress(at: repo.root) == .rebase)
        let snapshot = try await client.snapshot(at: repo.root)
        #expect(snapshot.operation == .rebase)
        try await client.abortOperation(at: repo.root, .rebase)
        #expect(try repo.hash("HEAD") == before)

        await #expect(throws: GitOperationError.self) {
            try await client.merge(at: repo.root, reference: side)
        }
        #expect(GitClient.operationInProgress(at: repo.root) == .merge)
        // Resolved and staged, the merge goes on without an editor.
        try "both\n".write(to: repo.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try repo.git(["add", "a.txt"])
        try await client.continueOperation(at: repo.root, .merge)
        #expect(GitClient.operationInProgress(at: repo.root) == nil)
        #expect(try repo.git(["rev-list", "--count", "--merges", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test
    func plansARebaseOntoABranchWithoutItsCommits() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        try repo.git(["switch", "-c", "feature"])
        try repo.commit("f.txt", "f\n", "F1")
        try repo.commit("g.txt", "g\n", "F2")
        try repo.git(["switch", "main"])
        try repo.commit("m.txt", "m\n", "M")
        try repo.git(["switch", "feature"])

        let client = GitClient()
        let main = GitReference(name: "main", fullName: "refs/heads/main", kind: .localBranch,
                                target: try repo.hash("main"), isCurrent: false)
        var plan = try await client.rebasePlan(at: repo.root, onto: main, warning: nil)
        #expect(plan.steps.map(\.commit.subject) == ["F2", "F1"])
        #expect(plan.movesOntoBranch)
        plan.steps[0].action = .fixup
        try await client.rewrite(at: repo.root, plan: plan)
        #expect(try repo.subjects() == ["F1", "M", "A"])
    }

    @Test
    @MainActor
    func historyShowsTheCurrentBranchUntilAllArePicked() async throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        let store = RepositoryStore()
        store.setMonitoringActive(false)

        // Without commits there is nothing to show, and no error.
        store.openRepository(repo.root)
        try await settle(store)
        #expect(store.errorMessage == nil)
        #expect(store.showsCurrentBranch)

        try repo.commit("a.txt", "a\n", "On main")
        try repo.git(["switch", "-c", "side"])
        try repo.commit("s.txt", "s\n", "On side")
        try repo.git(["switch", "main"])
        store.refresh()
        try await settle(store)
        #expect(store.historyScope == .currentBranch)
        #expect(store.commits.map(\.subject) == ["On main"])

        // A checkout elsewhere: the history follows HEAD.
        try repo.git(["switch", "side"])
        store.refresh()
        try await settle(store)
        #expect(store.commits.map(\.subject) == ["On side", "On main"])

        store.selectReference(nil)
        try await settle(store)
        #expect(store.showsAllBranches)
        store.showCurrentBranch()
        try await settle(store)
        #expect(store.showsCurrentBranch)
        #expect(store.selectedReference == nil)
    }

    @MainActor
    private func settle(_ store: RepositoryStore) async throws {
        for _ in 0..<500 {
            guard store.isLoading else { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func readsTheGitDirectoryOfALinkedWorktree() throws {
        let repo = try TestRepository()
        defer { repo.remove() }
        try repo.commit("a.txt", "a\n", "A")
        let linked = repo.container.appendingPathComponent("linked")
        try repo.git(["worktree", "add", "-b", "linked", linked.path])
        let directory = GitClient.gitDirectory(at: linked)
        #expect(directory.path.hasSuffix(".git/worktrees/linked"))
        #expect(GitClient.operationInProgress(at: linked) == nil)
    }
}

/// A repository in a temporary folder, with a branch `main`.
private struct TestRepository {
    let container: URL
    let root: URL

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryActionTests-\(UUID().uuidString)")
        root = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "History Tests"])
        try git(["config", "user.email", "tests@example.com"])
        try git(["config", "commit.gpgSign", "false"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    func commit(_ file: String, _ content: String, _ subject: String) throws {
        try content.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(["add", file])
        try git(["commit", "-m", subject])
    }

    func hash(_ revision: String) throws -> String {
        try git(["rev-parse", revision]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func subjects() throws -> [String] {
        try git(["log", "--format=%s"]).split(separator: "\n").map(String.init)
    }

    func files() throws -> [String] {
        try git(["ls-files"]).split(separator: "\n").map(String.init)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitOperationError(
                command: "git \(arguments.joined(separator: " "))",
                message: String(decoding: errorData, as: UTF8.self)
            )
        }
        return String(decoding: data, as: UTF8.self)
    }
}

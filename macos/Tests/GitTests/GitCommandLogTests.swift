import Foundation
import Testing
@testable import agentz

struct GitCommandLogTests {
    @Test
    func classifiesReadCommands() {
        let reads: [[String]] = [
            ["--no-optional-locks", "status", "--porcelain=v1", "--branch", "-z"],
            ["--no-optional-locks", "diff", "--cached", "--raw"],
            GitClient.historyArguments(revision: nil, limit: 10),
            ["for-each-ref", "--format=%(refname)", "refs/heads"],
            ["rev-parse", "--show-toplevel"],
            ["show-ref", "--verify", "--quiet", "refs/heads/main"],
            ["symbolic-ref", "--quiet", "HEAD"],
            ["config", "--get", "gpg.program"],
            ["stash", "list", "--format=%gd"],
            ["worktree", "list", "--porcelain", "-z"],
            ["remote"],
            ["branch"],
            ["tag", "--list"],
            ["apply", "--recount", "--cached", "--check", "-"],
            ["clean", "-n", "--", "file"],
        ]
        for arguments in reads {
            #expect(GitCommandKind.classify(arguments) == .read, "\(arguments)")
        }
    }

    @Test
    func classifiesWriteCommands() {
        let start = GitReference(
            name: "origin/main",
            fullName: "refs/remotes/origin/main",
            kind: .remoteBranch,
            target: "abcdef",
            isCurrent: false
        )
        let writes: [[String]] = [
            GitClient.commitArguments(message: "Message", amend: false, signWithGPG: true),
            ["add", "--", "file"],
            ["restore", "--staged", "--", "file"],
            ["rm", "--cached", "--ignore-unmatch", "--", "file"],
            ["apply", "--recount", "--cached", "-"],
            ["apply", "--recount", "--cached", "--reverse", "-"],
            ["checkout", "--ours", "--", "file"],
            ["switch", "--track", "origin/main"],
            ["switch", "-c", "feature"],
            ["branch", "--move", "old", "new"],
            ["branch", "feature"],
            ["tag", "v1.0"],
            GitClient.createBranchArguments(name: "feature", from: nil, checkout: false),
            GitClient.createBranchArguments(name: "feature", from: nil, checkout: true),
            GitClient.createBranchArguments(name: "feature", from: start, checkout: false),
            GitClient.createBranchArguments(name: "feature", from: start, checkout: true),
            GitClient.stashArguments(message: "WIP", scope: .all),
            GitClient.applyStashArguments(selector: "stash@{0}"),
            ["config", "user.name", "Name"],
            ["reset", "--soft", "HEAD~1"],
        ]
        for arguments in writes {
            #expect(GitCommandKind.classify(arguments) == .write, "\(arguments)")
        }
    }

    @Test
    func classifiesDeleteCommands() throws {
        let upstream = GitUpstream(
            fullName: "refs/remotes/origin/feature",
            shortName: "origin/feature",
            remote: "origin",
            remoteRef: "refs/heads/feature"
        )
        let deletes: [[String]] = [
            ["branch", "--delete", "feature"],
            ["branch", "-D", "feature"],
            ["tag", "--delete", "v1.0"],
            try GitClient.deleteRemoteBranchArguments(for: upstream),
            ["push", "origin", ":refs/heads/feature"],
            GitClient.dropStashArguments(selector: "stash@{0}"),
            ["worktree", "remove", "../other"],
            GitClient.pruneStaleWorktreeArguments,
            ["restore", "--worktree", "--", "file"],
            ["restore", "file"],
            ["clean", "-f", "--", "file"],
            ["rm", "-f", "--", "file"],
            ["apply", "--recount", "--reverse", "-"],
            ["reset", "--hard", "HEAD"],
            ["checkout", "--", "file"],
        ]
        for arguments in deletes {
            #expect(GitCommandKind.classify(arguments) == .delete, "\(arguments)")
        }
    }

    @Test
    func classifiesNetworkCommands() {
        let target = GitPushTarget(
            remote: "origin",
            remoteRef: "refs/heads/main",
            establishesUpstream: true
        )
        let network: [[String]] = [
            GitClient.fetchArguments(),
            ["pull", "--ff-only"],
            GitClient.pushArguments(for: target),
        ]
        for arguments in network {
            #expect(GitCommandKind.classify(arguments) == .network, "\(arguments)")
        }
    }

    @Test
    func quotesArgumentsForTheShell() {
        #expect(GitCommandLogEntry.shellQuoted("status") == "status")
        #expect(GitCommandLogEntry.shellQuoted("--format=%(refname)") == "'--format=%(refname)'")
        #expect(GitCommandLogEntry.shellQuoted("my file.txt") == "'my file.txt'")
        #expect(GitCommandLogEntry.shellQuoted("it's") == #"'it'\''s'"#)
        #expect(GitCommandLogEntry.shellQuoted("") == "''")

        let entry = makeEntry(["commit", "-m", "Fix bug"])
        #expect(entry.commandLine == "git commit -m 'Fix bug'")
    }

    @Test @MainActor
    func keepsEntriesInStartOrderAndTrimsPastTheCap() {
        let base = Date()
        let log = GitCommandLog(limit: 10, now: { base })
        log.record(makeEntry(["status"], startedAt: base.addingTimeInterval(-1)))
        log.record(makeEntry(["diff"], startedAt: base.addingTimeInterval(-3)))
        log.record(makeEntry(["log"], startedAt: base.addingTimeInterval(-2)))
        #expect(log.entries.map { $0.arguments[0] } == ["diff", "log", "status"])

        for index in 0..<8 {
            log.record(makeEntry(["show", "\(index)"], startedAt: base.addingTimeInterval(Double(index))))
        }
        // Past the cap, the oldest go until the log is at 90% of it.
        #expect(log.entries.count == 9)
        #expect(log.entries.first?.arguments[0] == "status")

        log.clear()
        #expect(log.entries.isEmpty)
    }

    @Test @MainActor
    func keepsTodayAndTheSixDaysBefore() throws {
        let calendar = utcCalendar
        let now = try #require(date("2026-09-29T15:00:00Z"))
        let log = GitCommandLog(calendar: calendar, now: { now })

        let cutoff = GitCommandLog.retentionCutoff(now: now, calendar: calendar)
        #expect(cutoff == date("2026-09-23T00:00:00Z"))

        log.restore([
            makeEntry(["expired"], startedAt: cutoff.addingTimeInterval(-1)),
            makeEntry(["oldest-kept"], startedAt: cutoff),
            makeEntry(["today"], startedAt: now),
        ])
        #expect(log.entries.map { $0.arguments[0] } == ["oldest-kept", "today"])
    }

    @Test @MainActor
    func restoreMergesSavedEntriesWithoutDuplicates() {
        let base = Date()
        let log = GitCommandLog(now: { base })
        let live = makeEntry(["status"], startedAt: base)
        log.record(live)
        log.restore([live, makeEntry(["diff"], startedAt: base.addingTimeInterval(-5))])
        #expect(log.entries.map { $0.arguments[0] } == ["diff", "status"])
    }

    @Test
    func savesAndRestoresEntriesThroughTheLogFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkCommandLogFileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.jsonl")
        let now = Date()
        let cutoff = now.addingTimeInterval(-3600)

        let file = GitCommandLogFile(url: url)
        let expired = makeEntry(["fetch", "--all"], startedAt: cutoff.addingTimeInterval(-60))
        let failed = makeEntry(
            ["branch", "--delete", "my feature"],
            startedAt: now.addingTimeInterval(-10),
            outcome: .failed(exitCode: 1)
        )
        let cancelled = makeEntry(["log"], startedAt: now, outcome: .cancelled)
        file.append(expired)
        file.append(cancelled)
        file.append(failed)
        await file.flush()

        // Unreadable lines are skipped, not fatal.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()

        let restored = await GitCommandLogFile(url: url).load(since: cutoff, limit: 100)
        // Timestamps are saved to the millisecond.
        #expect(restored.map(\.id) == [failed.id, cancelled.id])
        #expect(restored.map(\.arguments) == [failed.arguments, cancelled.arguments])
        #expect(restored.map(\.outcome) == [.failed(exitCode: 1), .cancelled])
        #expect(restored.map(\.directory) == [failed.directory, cancelled.directory])
        for (saved, original) in zip(restored, [failed, cancelled]) {
            #expect(abs(saved.startedAt.timeIntervalSince(original.startedAt)) < 0.001)
        }

        // Loading rewrote the file without the expired and unreadable lines.
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)

        file.replace(with: [])
        await file.flush()
        #expect(await GitCommandLogFile(url: url).load(since: cutoff, limit: 100).isEmpty)
    }

    @Test
    func namesAndBoundsTheRetainedDays() throws {
        let calendar = utcCalendar
        let now = try #require(date("2026-09-29T15:00:00Z"))

        #expect(GitCommandLogDay.offsets == [0, 1, 2, 3, 4, 5, 6])
        #expect(GitCommandLogDay.title(daysAgo: 0, now: now, calendar: calendar) == "Today")
        #expect(GitCommandLogDay.title(daysAgo: 1, now: now, calendar: calendar) == "Yesterday")
        #expect(GitCommandLogDay.title(daysAgo: 2, now: now, calendar: calendar).contains("27"))

        let yesterday = GitCommandLogDay.range(daysAgo: 1, now: now, calendar: calendar)
        #expect(yesterday.lowerBound == date("2026-09-28T00:00:00Z"))
        #expect(yesterday.upperBound == date("2026-09-29T00:00:00Z"))

        let lateYesterday = try #require(date("2026-09-28T23:59:00Z"))
        #expect(GitCommandLogDay.daysAgo(lateYesterday, now: now, calendar: calendar) == 1)

        var filter = GitCommandLogFilter()
        filter.dateRange = yesterday
        #expect(filter.matches(makeEntry(["status"], startedAt: lateYesterday), repositoryPath: "/repo"))
        #expect(!filter.matches(makeEntry(["status"], startedAt: now), repositoryPath: "/repo"))
    }

    @Test
    func mapsDirectoriesToTheInnermostOpenedRoot() {
        let roots: Set<String> = ["/work/app", "/work/app/vendor/lib"]
        #expect(GitCommandLog.repositoryPath(forDirectory: "/work/app", roots: roots) == "/work/app")
        #expect(GitCommandLog.repositoryPath(forDirectory: "/work/app/src", roots: roots) == "/work/app")
        #expect(
            GitCommandLog.repositoryPath(forDirectory: "/work/app/vendor/lib/x", roots: roots)
                == "/work/app/vendor/lib"
        )
        #expect(GitCommandLog.repositoryPath(forDirectory: "/work/application", roots: roots) == "/work/application")
    }

    @Test
    func filtersByKindFailureRepositoryAndText() {
        let read = makeEntry(["status"])
        let failedDelete = makeEntry(
            ["branch", "--delete", "feature"],
            outcome: .failed(exitCode: 1)
        )

        var filter = GitCommandLogFilter()
        #expect(filter.matches(read, repositoryPath: "/repo"))
        #expect(filter.matches(failedDelete, repositoryPath: "/repo"))

        filter.kinds = [.delete]
        #expect(!filter.matches(read, repositoryPath: "/repo"))
        #expect(filter.matches(failedDelete, repositoryPath: "/repo"))

        filter = GitCommandLogFilter(failedOnly: true)
        #expect(!filter.matches(read, repositoryPath: "/repo"))
        #expect(filter.matches(failedDelete, repositoryPath: "/repo"))

        filter = GitCommandLogFilter(repositoryPath: "/other")
        #expect(!filter.matches(read, repositoryPath: "/repo"))

        filter = GitCommandLogFilter(searchText: "FEATURE")
        #expect(!filter.matches(read, repositoryPath: "/repo"))
        #expect(filter.matches(failedDelete, repositoryPath: "/repo"))
    }

    @Test
    func recordsCommandsRunByGitClientExceptSuppressedOnes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitForkCommandLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q", "-b", "main"]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()

        let client = GitClient()
        let suppressedDirectory = root.appendingPathComponent("poller")
        try FileManager.default.createDirectory(
            at: suppressedDirectory,
            withIntermediateDirectories: true
        )
        _ = try await GitCommandLogScope.$isSuppressed.withValue(true) {
            try await client.repositoryRoot(from: suppressedDirectory)
        }
        _ = try await client.repositoryRoot(from: root)

        // Entries reach the log through the main actor after each command.
        var entries: [GitCommandLogEntry] = []
        for _ in 0..<100 {
            entries = await MainActor.run {
                GitCommandLog.shared.entries.filter {
                    $0.directory.path.hasPrefix(root.path)
                }
            }
            if !entries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.directory == root)
        #expect(entry.arguments == ["rev-parse", "--show-toplevel"])
        #expect(entry.kind == .read)
        #expect(entry.outcome == .succeeded)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private func makeEntry(
        _ arguments: [String],
        startedAt: Date = Date(),
        outcome: GitCommandOutcome = .succeeded
    ) -> GitCommandLogEntry {
        GitCommandLogEntry(
            arguments: arguments,
            directory: URL(fileURLWithPath: "/repo"),
            hasInput: false,
            startedAt: startedAt,
            duration: 0.01,
            outcome: outcome,
            outputByteCount: 0,
            errorOutput: ""
        )
    }
}

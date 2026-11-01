import Foundation

struct RepositoryStateToken: Equatable, Sendable {
    let status: String
    let stagedDiff: String
    let references: String
    let stashes: String
    let worktrees: String
    let workingTreeMetadata: String

    func replacingWorkingTree(with snapshot: WorkingTreeSnapshot) -> Self {
        Self(
            status: snapshot.status,
            stagedDiff: snapshot.stagedDiff,
            references: references,
            stashes: stashes,
            worktrees: worktrees,
            workingTreeMetadata: snapshot.workingTreeMetadata
        )
    }
}

struct WorkingTreeSnapshot: Sendable {
    let changes: [WorkingChange]
    let status: String
    let stagedDiff: String
    let workingTreeMetadata: String
}

struct RepositoryLoad: Sendable {
    let snapshot: RepositorySnapshot
    let stateToken: RepositoryStateToken
}

private final class GitProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var launched = false
    private var terminationRequested = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func processDidStart() {
        lock.lock()
        launched = true
        let process = processToTerminate()
        lock.unlock()
        process?.terminate()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = processToTerminate()
        lock.unlock()
        process?.terminate()
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var hasLaunched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return launched
    }

    private func processToTerminate() -> Process? {
        guard cancelled,
              !terminationRequested,
              let process,
              process.isRunning else {
            return nil
        }
        terminationRequested = true
        return process
    }
}

struct GitClient: Sendable {
    static let historyPageSize = 300

    private let gitURL = URL(fileURLWithPath: "/usr/bin/git")
    private static let verifiedCommitFormat =
        "%H%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%D%x1f%G?%x1f%GK%x1f%GS%x1f%GG%x1f%s%x1e"
    private static let unverifiedCommitFormat =
        "%H%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%D%x1fN%x1f%x1f%x1f%x1f%s%x1e"
    private static let statusArguments = [
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "--branch",
        "-z",
        "--untracked-files=all"
    ]
    private static let stagedDiffArguments = [
        "--no-optional-locks",
        "diff",
        "--cached",
        "--raw",
        "--no-renames",
        "--no-ext-diff"
    ]
    private static let referenceArguments = [
        "for-each-ref",
        """
        --format=%(refname)%1f%(objectname:short)%1f%(objectname)%1f%(upstream)%1f\
        %(upstream:short)%1f%(upstream:remotename)%1f%(upstream:remoteref)%1f%(upstream:track)
        """,
        "refs/heads", "refs/remotes", "refs/tags"
    ]
    private static let stashArguments = [
        "stash",
        "list",
        "--format=%gd%x1f%H%x1f%gs%x1e"
    ]
    private static let worktreeArguments = [
        "worktree",
        "list",
        "--porcelain",
        "-z"
    ]
    private static let processEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["PATH"] = commandSearchPath(
            inheritedPath: environment["PATH"]
        )
        return environment
    }()

    func repositoryRoot(from directory: URL) async throws -> URL {
        let result = try await run(["rev-parse", "--show-toplevel"], in: directory)
        return URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL
    }

    func snapshot(
        at root: URL,
        revision: String? = nil,
        historyLimit: Int = historyPageSize
    ) async throws -> RepositorySnapshot {
        try await loadSnapshot(
            at: root,
            historyScope: CommitHistoryScope(revision: revision),
            includesStateToken: false,
            historyLimit: historyLimit
        ).snapshot
    }

    func snapshotAndStateToken(
        at root: URL,
        revision: String? = nil,
        historyLimit: Int = historyPageSize
    ) async throws -> RepositoryLoad {
        try await snapshotAndStateToken(
            at: root,
            historyScope: CommitHistoryScope(revision: revision),
            historyLimit: historyLimit
        )
    }

    func snapshotAndStateToken(
        at root: URL,
        historyScope: CommitHistoryScope,
        historyLimit: Int = historyPageSize
    ) async throws -> RepositoryLoad {
        let load = try await loadSnapshot(
            at: root,
            historyScope: historyScope,
            includesStateToken: true,
            historyLimit: historyLimit
        )
        guard let stateToken = load.stateToken else {
            preconditionFailure("A repository state token was requested but not loaded.")
        }
        return RepositoryLoad(snapshot: load.snapshot, stateToken: stateToken)
    }

    private func loadSnapshot(
        at root: URL,
        historyScope: CommitHistoryScope,
        includesStateToken: Bool,
        historyLimit: Int
    ) async throws -> (snapshot: RepositorySnapshot, stateToken: RepositoryStateToken?) {
        async let branchResult = runAllowingFailure(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        async let statusResult = run(Self.statusArguments, in: root)
        async let stagedDiffResult = loadStagedDiff(
            at: root,
            included: includesStateToken
        )
        async let refsResult = run(Self.referenceArguments, in: root)
        async let stashResult = run(Self.stashArguments, in: root)
        async let worktreeResult = run(Self.worktreeArguments, in: root)
        async let history = history(
            at: root,
            scope: historyScope,
            limit: historyLimit
        )

        let branchCommand = try await branchResult
        let branch: String
        if branchCommand.exitCode == 0 {
            branch = branchCommand.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let detached = try await run(["rev-parse", "--short", "HEAD"], in: root)
            branch = BranchDisplay.detached(
                hash: detached.output.trimmingCharacters(in: .whitespacesAndNewlines)
            ).description
        }

        async let upstreamResult = runAllowingFailure(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: root
        )
        async let countsResult = runAllowingFailure(
            ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
            in: root
        )

        let status = try await statusResult
        let refs = try await refsResult
        let stashes = try await stashResult
        let worktrees = try await worktreeResult
        let commits = try await history
        let stagedDiff = try await stagedDiffResult
        let upstreamCommand = try await upstreamResult
        let countsCommand = try await countsResult
        let upstream = upstreamCommand.exitCode == 0
            ? upstreamCommand.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let pushTarget = try await resolvePushTarget(
            at: root,
            branch: branch,
            hasUpstream: upstream != nil
        )

        let counts = countsCommand.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }

        let changes = GitParser.parseStatus(Data(status.output.utf8))
        let snapshot = RepositorySnapshot(
            root: root,
            branch: branch,
            upstream: upstream,
            pushTarget: pushTarget,
            ahead: counts.first ?? 0,
            behind: counts.dropFirst().first ?? 0,
            changes: changes,
            references: GitParser.parseReferences(refs.output, currentBranch: branch),
            stashes: GitParser.parseStashes(stashes.output),
            worktrees: GitParser.parseWorktrees(worktrees.output, currentRoot: root),
            commits: commits
        )
        let stateToken = includesStateToken
            ? RepositoryStateToken(
                status: status.output,
                stagedDiff: stagedDiff.output,
                references: refs.output,
                stashes: stashes.output,
                worktrees: worktrees.output,
                workingTreeMetadata: workingTreeMetadata(
                    from: changes,
                    at: root
                )
            )
            : nil
        return (snapshot, stateToken)
    }

    func history(
        at root: URL,
        revision: String? = nil,
        offset: Int = 0,
        limit: Int = historyPageSize
    ) async throws -> [GitCommit] {
        try await history(
            at: root,
            scope: CommitHistoryScope(revision: revision),
            offset: offset,
            limit: limit
        )
    }

    func history(
        at root: URL,
        scope: CommitHistoryScope,
        offset: Int = 0,
        limit: Int = historyPageSize
    ) async throws -> [GitCommit] {
        if scope == .lostAndDangling {
            return try await lostAndDanglingCommits(
                at: root,
                offset: offset,
                limit: limit
            )
        }

        let revision: String?
        let path: String?
        switch scope {
        case .all:
            revision = nil
            path = nil
        case let .revision(value), let .commit(value):
            revision = value
            path = nil
        case let .path(value, pathRevision):
            revision = pathRevision
            path = value
        case .lostAndDangling:
            preconditionFailure("Handled above.")
        }
        let result = try await run(
            Self.historyArguments(
                revision: revision,
                path: path,
                offset: offset,
                limit: limit
            ),
            in: root
        )
        return GitParser.parseCommits(result.output)
    }

    static func historyArguments(
        revision: String?,
        path: String? = nil,
        offset: Int = 0,
        limit: Int = historyPageSize
    ) -> [String] {
        var arguments = [
            "log",
            "--topo-order",
            "--max-count=\(limit)",
            "--date=iso-strict",
            "--pretty=format:\(unverifiedCommitFormat)"
        ]
        if offset > 0 {
            arguments.append("--skip=\(offset)")
        }
        if path != nil {
            // A path history only filters a branch that is already on screen,
            // so a revision that has since disappeared — or a HEAD that is
            // still unborn — should come back empty instead of failing the
            // load with a fatal Git error.
            arguments.append("--ignore-missing")
        }
        arguments.append(revision ?? "--all")
        if let path {
            arguments.append("--")
            arguments.append(":(literal)\(path)")
        }
        return arguments
    }

    func repositoryPaths(at root: URL) async throws -> [RepositoryPathItem] {
        let result = try await run(
            ["ls-files", "--cached", "-z"],
            in: root
        )
        return Self.parseRepositoryPathItems(result.output)
    }

    static func parseRepositoryPathItems(_ output: String) -> [RepositoryPathItem] {
        let files = output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        var directories = Set<String>()

        for file in files {
            let components = file.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard components.count > 1 else { continue }
            for end in 1..<components.count {
                directories.insert(
                    components[..<end].joined(separator: "/")
                )
            }
        }

        return (
            directories.map {
                RepositoryPathItem(path: $0, kind: .directory)
            }
            + files.map {
                RepositoryPathItem(path: $0, kind: .file)
            }
        )
        .sorted {
            let order = $0.path.localizedStandardCompare($1.path)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return $0.kind == .directory && $1.kind == .file
        }
    }

    private func lostAndDanglingCommits(
        at root: URL,
        offset: Int,
        limit: Int
    ) async throws -> [GitCommit] {
        let fsck = try await run(
            [
                "fsck",
                "--full",
                "--no-reflogs",
                "--unreachable",
                "--no-progress"
            ],
            in: root
        )
        let hashes = Self.parseLostAndDanglingCommitHashes(
            fsck.output + "\n" + fsck.error
        )
        guard !hashes.isEmpty else { return [] }

        let revisions = hashes.joined(separator: "\n") + "\n--not\n--all\n"
        var arguments = [
            "log",
            "--topo-order",
            "--max-count=\(limit)",
            "--date=iso-strict",
            "--pretty=format:\(Self.unverifiedCommitFormat)",
        ]
        if offset > 0 {
            arguments.append("--skip=\(offset)")
        }
        arguments.append("--stdin")
        let result = try await run(
            arguments,
            in: root,
            input: Data(revisions.utf8)
        )
        return GitParser.parseCommits(result.output)
    }

    static func parseLostAndDanglingCommitHashes(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                  fields[1] == "commit",
                  fields[0] == "unreachable" || fields[0] == "dangling" else {
                return nil
            }
            let hash = String(fields[2])
            guard !hash.isEmpty,
                  hash.allSatisfy({ $0.isHexDigit }),
                  seen.insert(hash).inserted else {
                return nil
            }
            return hash
        }
    }

    func stateToken(at root: URL) async throws -> RepositoryStateToken {
        async let workingTree = workingTreeSnapshot(at: root)
        async let referencesResult = run(Self.referenceArguments, in: root)
        async let stashResult = run(Self.stashArguments, in: root)
        async let worktreeResult = run(Self.worktreeArguments, in: root)

        let workingTreeSnapshot = try await workingTree
        let references = try await referencesResult
        let stashes = try await stashResult
        let worktrees = try await worktreeResult

        return RepositoryStateToken(
            status: workingTreeSnapshot.status,
            stagedDiff: workingTreeSnapshot.stagedDiff,
            references: references.output,
            stashes: stashes.output,
            worktrees: worktrees.output,
            workingTreeMetadata: workingTreeSnapshot.workingTreeMetadata
        )
    }

    func workingTreeSnapshot(at root: URL) async throws -> WorkingTreeSnapshot {
        async let statusResult = run(Self.statusArguments, in: root)
        async let stagedDiffResult = run(Self.stagedDiffArguments, in: root)

        let status = try await statusResult
        let stagedDiff = try await stagedDiffResult
        let changes = GitParser.parseStatus(Data(status.output.utf8))
        return WorkingTreeSnapshot(
            changes: changes,
            status: status.output,
            stagedDiff: stagedDiff.output,
            workingTreeMetadata: workingTreeMetadata(from: changes, at: root)
        )
    }

    private func loadStagedDiff(
        at root: URL,
        included: Bool
    ) async throws -> GitCommandResult {
        guard included else {
            return GitCommandResult(output: "", error: "", exitCode: 0)
        }
        return try await run(Self.stagedDiffArguments, in: root)
    }

    func diff(
        at root: URL,
        change: WorkingChange,
        staged: Bool,
        fullFile: Bool = false
    ) async throws -> String {
        var arguments = ["diff", "--no-ext-diff", "--no-color"]
        if fullFile {
            arguments.append("--unified=\(Int32.max)")
        }
        if staged {
            arguments.append("--cached")
        }
        arguments += ["--", change.path]

        let result = try await run(arguments, in: root)
        if result.output.isEmpty && change.isUntracked {
            let untrackedDiff = try await runAllowingFailure([
                "diff",
                "--no-index",
                "--no-ext-diff",
                "--no-color",
                fullFile ? "--unified=\(Int32.max)" : "--unified=3",
                "--",
                "/dev/null",
                change.path
            ], in: root)
            guard untrackedDiff.exitCode <= 1 else {
                throw GitOperationError(
                    command: "git diff --no-index -- /dev/null \(change.path)",
                    message: untrackedDiff.error.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return untrackedDiff.output.isEmpty
                ? "No textual changes."
                : untrackedDiff.output
        }
        return result.output.isEmpty ? "No textual changes." : result.output
    }

    private func workingTreeMetadata(
        from changes: [WorkingChange],
        at root: URL
    ) -> String {
        let fileManager = FileManager.default

        return changes.map { change in
            let attributes = try? fileManager.attributesOfItem(
                atPath: root.appendingPathComponent(change.path).path
            )
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let modificationDate = attributes?[.modificationDate] as? Date
            let modificationBits = modificationDate?
                .timeIntervalSinceReferenceDate.bitPattern ?? 0
            let fileIdentifier = (attributes?[.systemFileNumber] as? NSNumber)?
                .uint64Value ?? 0
            return "\(change.path)\u{1f}\(size)\u{1f}\(modificationBits)\u{1f}\(fileIdentifier)"
        }
        .joined(separator: "\u{1e}")
    }

    func commitDetails(at root: URL, hash: String) async throws -> String {
        let result = try await run([
            "show",
            "--no-ext-diff",
            "--no-color",
            "--format=fuller",
            "--stat",
            "--patch",
            "--find-renames",
            hash
        ], in: root)
        return result.output
    }

    func commit(at root: URL, revision: String) async throws -> GitCommit {
        let result = try await run([
            "log",
            "--max-count=1",
            "--date=iso-strict",
            "--pretty=format:\(Self.verifiedCommitFormat)",
            revision
        ], in: root)
        guard let commit = GitParser.parseCommits(result.output).first else {
            throw GitOperationError(
                command: "git log --max-count=1 \(revision)",
                message: "Git did not return the requested commit."
            )
        }
        return commit
    }

    /// Resolves a short or full commit hash, including hashes that are only
    /// reachable from the reflog or from no reference at all.
    func commit(at root: URL, matchingHash hash: String) async throws -> GitCommit {
        let arguments = ["rev-parse", "--verify", "--end-of-options", "\(hash)^{commit}"]
        let resolved = try await runAllowingFailure(arguments, in: root)
        guard resolved.exitCode == 0 else {
            throw GitOperationError(
                command: "git \(arguments.joined(separator: " "))",
                message: Self.commitLookupMessage(for: hash, error: resolved.error)
            )
        }
        return try await commit(
            at: root,
            revision: resolved.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func commitLookupMessage(for hash: String, error: String) -> String {
        error.localizedCaseInsensitiveContains("ambiguous")
            ? "“\(hash)” matches more than one object. Type more of the hash."
            : "No commit in this repository matches “\(hash)”."
    }

    func stage(at root: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths, in: root)
    }

    func unstage(at root: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let restore = try await runAllowingFailure(["restore", "--staged", "--"] + paths, in: root)
        if restore.exitCode != 0 {
            _ = try await run(["rm", "--cached", "--ignore-unmatch", "--"] + paths, in: root)
        }
    }

    func markConflictsResolved(
        at root: URL,
        conflicts: [WorkingChange]
    ) async throws {
        let paths = conflicts.filter(\.isConflicted).map(\.path)
        guard !paths.isEmpty else { return }
        // -A records a selected deletion as well as edited file contents.
        _ = try await run(["add", "-A", "--"] + paths, in: root)
    }

    func conflictDocument(
        at root: URL,
        change: WorkingChange
    ) async throws -> ConflictDocument? {
        guard change.isConflicted else { return nil }
        let fileURL = root.appendingPathComponent(change.path)
        return await Task.detached(priority: .userInitiated) {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]) else {
                return nil
            }
            guard values.isRegularFile == true else { return nil }
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let document = ConflictDocument(text)
            return document.conflicts.isEmpty ? nil : document
        }.value
    }

    /// Resolves only one textual marker block. The unmerged index stages stay
    /// intact while other well-formed blocks remain; the path is added only
    /// after the final block is gone.
    func resolveConflictBlock(
        at root: URL,
        change: WorkingChange,
        document: ConflictDocument,
        blockID: ConflictBlock.ID,
        using side: ConflictResolutionSide
    ) async throws {
        guard change.isConflicted else { return }
        let fileURL = root.appendingPathComponent(change.path)
        let shouldMarkResolved = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: fileURL)
            guard let currentText = String(data: data, encoding: .utf8),
                  currentText == document.text else {
                throw GitOperationError(
                    command: "resolve conflict block in \(change.path)",
                    message: "The file changed after its conflicts were loaded. Review the updated file and try again."
                )
            }
            guard let resolvedText = document.resolving(
                blockID: blockID,
                using: side
            ) else {
                throw GitOperationError(
                    command: "resolve conflict block in \(change.path)",
                    message: "That conflict block is no longer present. Review the updated file and try again."
                )
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try Data(resolvedText.utf8).write(to: fileURL, options: .atomic)
            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: fileURL.path
                )
            }

            let resolvedDocument = ConflictDocument(resolvedText)
            return resolvedDocument.conflicts.isEmpty
                && !resolvedDocument.hasUnparsedMarkers
        }.value

        if shouldMarkResolved {
            _ = try await run(["add", "-A", "--", change.path], in: root)
        }
    }

    /// Replaces each conflicted working-tree path with the selected unmerged
    /// stage and records the result in the index. A side can legitimately be
    /// absent for modify/delete conflicts; choosing that side resolves the
    /// path as a deletion.
    func resolveConflicts(
        at root: URL,
        conflicts: [WorkingChange],
        using side: ConflictResolutionSide
    ) async throws {
        let conflicts = conflicts.filter(\.isConflicted)
        guard !conflicts.isEmpty else { return }

        let presentPaths = conflicts
            .filter { $0.hasConflictVersion(side) }
            .map(\.path)
        let deletedPaths = conflicts
            .filter { !$0.hasConflictVersion(side) }
            .map(\.path)

        if !presentPaths.isEmpty {
            _ = try await run(["checkout", "--\(side.rawValue)", "--"] + presentPaths, in: root)
            _ = try await run(["add", "-A", "--"] + presentPaths, in: root)
        }
        if !deletedPaths.isEmpty {
            _ = try await run(["rm", "-f", "--"] + deletedPaths, in: root)
        }
    }

    func stage(at root: URL, patch: String) async throws {
        try await apply(patch, at: root, cached: true, reverse: false)
    }

    func unstage(at root: URL, patch: String) async throws {
        try await apply(patch, at: root, cached: true, reverse: true)
    }

    func discard(at root: URL, patch: String) async throws {
        try await apply(patch, at: root, cached: false, reverse: true)
    }

    func discard(at root: URL, changes: [WorkingChange]) async throws {
        let tracked = changes.filter { !$0.isUntracked }.map(\.path)
        let untracked = changes.filter(\.isUntracked).map(\.path)
        if !tracked.isEmpty {
            _ = try await run(["restore", "--worktree", "--"] + tracked, in: root)
        }
        if !untracked.isEmpty {
            _ = try await run(["clean", "-f", "--"] + untracked, in: root)
        }
    }

    func commit(
        at root: URL,
        message: String,
        amend: Bool,
        signWithGPG: Bool
    ) async throws {
        let gpgProgram = signWithGPG
            ? try await resolvedGPGProgram(at: root).path
            : nil
        let arguments = Self.commitArguments(
            message: message,
            amend: amend,
            signWithGPG: signWithGPG,
            gpgProgram: gpgProgram
        )
        _ = try await run(arguments, in: root)
    }

    static func commitArguments(
        message: String,
        amend: Bool,
        signWithGPG: Bool,
        gpgProgram: String? = nil
    ) -> [String] {
        var arguments: [String] = []
        if signWithGPG {
            arguments += ["-c", "gpg.format=openpgp"]
            if let gpgProgram {
                arguments += ["-c", "gpg.openpgp.program=\(gpgProgram)"]
            }
        }

        arguments += [
            "commit",
            signWithGPG ? "--gpg-sign" : "--no-gpg-sign"
        ]
        if amend {
            arguments.append("--amend")
        }
        arguments += ["-m", message]
        return arguments
    }

    static func commandSearchPath(
        inheritedPath: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        var directories = (inheritedPath ?? "")
            .split(separator: ":")
            .map(String.init)
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent("bin").path,
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var seen = Set<String>()
        return directories
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    static func executableURL(
        named program: String,
        searchPath: String,
        workingDirectory: URL
    ) -> URL? {
        let expanded = NSString(string: program).expandingTildeInPath
        if expanded.contains("/") {
            let candidate = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : workingDirectory.appendingPathComponent(expanded)
            return FileManager.default.isExecutableFile(atPath: candidate.path)
                ? candidate.standardizedFileURL
                : nil
        }

        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(expanded)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private func resolvedGPGProgram(at root: URL) async throws -> URL {
        let configuredProgram = try await configuredGPGProgram(at: root)
        let searchPath = Self.commandSearchPath(
            inheritedPath: ProcessInfo.processInfo.environment["PATH"]
        )

        if let configuredProgram {
            if let executable = Self.executableURL(
                named: configuredProgram,
                searchPath: searchPath,
                workingDirectory: root
            ) {
                return executable
            }

            throw GitOperationError(
                command: "git commit --gpg-sign",
                message: """
                Git's configured GPG program '\(configuredProgram)' could not be found. \
                Install GnuPG or update it with:
                git config --global gpg.program /absolute/path/to/gpg
                """
            )
        }

        for candidate in ["gpg", "gpg2"] {
            if let executable = Self.executableURL(
                named: candidate,
                searchPath: searchPath,
                workingDirectory: root
            ) {
                return executable
            }
        }

        throw GitOperationError(
            command: "git commit --gpg-sign",
            message: """
            GPG was not found. Install GnuPG (for example, `brew install gnupg`) \
            or configure its absolute path with:
            git config --global gpg.program /absolute/path/to/gpg
            """
        )
    }

    private func configuredGPGProgram(at root: URL) async throws -> String? {
        for key in ["gpg.openpgp.program", "gpg.program"] {
            let result = try await runAllowingFailure(
                ["config", "--get", key],
                in: root
            )
            let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func fetch(at root: URL) async throws {
        _ = try await run(Self.fetchArguments(), in: root)
    }

    static func fetchArguments() -> [String] {
        ["fetch", "--all"]
    }

    func pull(at root: URL) async throws {
        _ = try await run(["pull", "--ff-only"], in: root)
    }

    func push(
        at root: URL,
        target: GitPushTarget?,
        sourceRef: String = "HEAD"
    ) async throws {
        guard let target else {
            throw GitOperationError(
                command: "git push",
                message: "No safe place to push the branch to was found."
            )
        }

        _ = try await run(
            Self.pushArguments(for: target, sourceRef: sourceRef),
            in: root
        )
    }

    static func pushArguments(
        for target: GitPushTarget,
        sourceRef: String = "HEAD"
    ) -> [String] {
        var arguments = [
            "-c",
            "remote.\(target.remote).mirror=false",
            "push",
            "--no-force",
            "--no-follow-tags"
        ]
        if target.establishesUpstream {
            arguments.append("--set-upstream")
        }
        arguments += ["--", target.remote, "\(sourceRef):\(target.remoteRef)"]
        return arguments
    }

    /// Resolves the same narrow destination used by current-branch pushes for
    /// any local branch selected in the sidebar.
    func pushTarget(
        at root: URL,
        for reference: GitReference
    ) async throws -> GitPushTarget? {
        guard reference.kind == .localBranch else { return nil }

        if let upstream = reference.upstream {
            guard upstream.remote != ".",
                  upstream.remoteRef.hasPrefix("refs/heads/") else {
                return nil
            }
            return GitPushTarget(
                remote: upstream.remote,
                remoteRef: upstream.remoteRef,
                establishesUpstream: false
            )
        }

        let remotes = try await run(["remote"], in: root).output
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let remote = remotes.first else { return nil }
        return GitPushTarget(
            remote: remote,
            remoteRef: "refs/heads/\(reference.name)",
            establishesUpstream: true
        )
    }

    func checkout(at root: URL, reference: GitReference) async throws {
        do {
            try await switchTo(reference, at: root)
        } catch let error as GitOperationError {
            guard let files = Self.overwrittenFiles(in: error.message) else { throw error }
            throw CheckoutOverwriteError(files: files, message: error.message)
        }
    }

    /// The files `git switch` said it would overwrite, or nil when that is
    /// not why it failed. They are the lines with a tab in front.
    static func overwrittenFiles(in message: String) -> [String]? {
        guard message.contains("would be overwritten by") else { return nil }
        return message
            .split(separator: "\n")
            .filter { $0.hasPrefix("\t") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func switchTo(_ reference: GitReference, at root: URL) async throws {
        if reference.kind == .remoteBranch {
            let localName = reference.name.split(separator: "/").dropFirst().joined(separator: "/")
            let localRef = "refs/heads/\(localName)"
            let existing = try await runAllowingFailure(
                ["show-ref", "--verify", "--quiet", localRef],
                in: root
            )
            if existing.exitCode == 0 {
                let upstream = try await runAllowingFailure(
                    ["for-each-ref", "--format=%(upstream)", localRef],
                    in: root
                )
                let configuredUpstream = upstream.output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard configuredUpstream == reference.fullName else {
                    throw GitOperationError(
                        command: "git switch \(localName)",
                        message: """
                        Local branch '\(localName)' already exists but does not track \
                        \(reference.name). Rename or remove it before checking out this remote branch.
                        """
                    )
                }
                _ = try await run(["switch", "--", localName], in: root)
            } else {
                _ = try await run(
                    ["switch", "--track", "-c", localName, "--", reference.fullName],
                    in: root
                )
            }
        } else if reference.kind == .localBranch {
            _ = try await run(["switch", "--", reference.name], in: root)
        } else {
            _ = try await run(["switch", "--detach", "--", reference.fullName], in: root)
        }
    }

    func createBranch(at root: URL, name: String) async throws {
        _ = try await run(["switch", "-c", name], in: root)
    }

    func rename(at root: URL, reference: GitReference, to name: String) async throws {
        _ = try await run(
            Self.renameArguments(for: reference, to: name),
            in: root
        )
    }

    func delete(at root: URL, reference: GitReference) async throws {
        do {
            _ = try await run(
                Self.deleteArguments(for: reference),
                in: root
            )
        } catch let error as GitOperationError {
            guard reference.kind == .localBranch else { throw error }
            if error.message.contains("is not fully merged") {
                throw UnmergedBranchDeletionError(
                    branch: reference.name,
                    message: error.message
                )
            }
            guard Self.describesWorktreeCheckout(error.message) else { throw error }
            throw GitOperationError(
                command: error.command,
                message: """
                \(error.message) Delete that worktree, or check out a different \
                branch inside it, before deleting \(reference.name).
                """
            )
        }
    }

    /// Git blocks branch deletion while a linked worktree has the branch
    /// checked out. The wording changed across Git versions, so both forms are
    /// recognised.
    private static func describesWorktreeCheckout(_ message: String) -> Bool {
        message.contains("used by worktree at")
            || message.contains("checked out at")
    }

    func forceDelete(at root: URL, reference: GitReference) async throws {
        _ = try await run(
            Self.forceDeleteArguments(for: reference),
            in: root
        )
    }

    func deleteRemoteBranch(at root: URL, upstream: GitUpstream) async throws {
        _ = try await run(
            Self.deleteRemoteBranchArguments(for: upstream),
            in: root
        )
    }

    static func deleteRemoteBranchArguments(for upstream: GitUpstream) throws -> [String] {
        guard !upstream.remote.isEmpty,
              upstream.remoteRef.hasPrefix("refs/heads/") else {
            throw GitOperationError(
                command: "git push --delete",
                message: """
                \(upstream.shortName) does not name a branch on a remote, so GitFork \
                cannot delete it.
                """
            )
        }
        return [
            "-c",
            "remote.\(upstream.remote).mirror=false",
            "push",
            "--delete",
            "--",
            upstream.remote,
            upstream.remoteRef
        ]
    }

    static func deleteArguments(for reference: GitReference) throws -> [String] {
        switch reference.kind {
        case .localBranch:
            guard !reference.isCurrent else {
                throw GitOperationError(
                    command: "git branch --delete",
                    message: "Check out another branch before deleting \(reference.name)."
                )
            }
            return ["branch", "--delete", "--", reference.name]
        case .tag:
            return ["tag", "--delete", "--", reference.name]
        case .remoteBranch:
            throw GitOperationError(
                command: "git branch --delete",
                message: """
                \(reference.name) lives on a remote. Use Delete Remote Branch to \
                remove it with git push --delete.
                """
            )
        }
    }

    /// Renames a local branch. The plain `--move` form is deliberate: Git
    /// refuses to overwrite an existing branch, so a rename can never discard
    /// another branch's commits.
    static func renameArguments(for reference: GitReference, to name: String) throws -> [String] {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.kind == .localBranch else {
            throw GitOperationError(
                command: "git branch --move",
                message: """
                \(reference.name) is not a local branch. Only local branches can \
                be renamed.
                """
            )
        }
        guard !newName.isEmpty else {
            throw GitOperationError(
                command: "git branch --move",
                message: "Enter a name for \(reference.name)."
            )
        }
        guard newName != reference.name else {
            throw GitOperationError(
                command: "git branch --move",
                message: "\(reference.name) already has that name."
            )
        }
        return ["branch", "--move", "--", reference.name, newName]
    }

    static func forceDeleteArguments(for reference: GitReference) throws -> [String] {
        guard reference.kind == .localBranch else {
            throw GitOperationError(
                command: "git branch -D",
                message: "Only local branches can be force deleted."
            )
        }
        guard !reference.isCurrent else {
            throw GitOperationError(
                command: "git branch -D",
                message: "Check out another branch before deleting \(reference.name)."
            )
        }
        return ["branch", "-D", "--", reference.name]
    }

    /// Removes a linked worktree. A worktree with a branch checked out can be
    /// removed like any other; Git keeps the branch itself, and freeing it this
    /// way is what makes that branch deletable again.
    func removeWorktree(
        at root: URL,
        worktree: GitWorktree,
        force: Bool = false
    ) async throws {
        do {
            _ = try await run(
                Self.removeWorktreeArguments(for: worktree, force: force),
                in: root
            )
        } catch let error as GitOperationError {
            guard !force, Self.describesDirtyWorktree(error.message) else {
                throw error
            }
            throw DirtyWorktreeRemovalError(
                path: worktree.path,
                message: error.message
            )
        }
    }

    /// Git refuses a plain removal when the worktree still holds modified or
    /// untracked files and says so by pointing at `--force`.
    private static func describesDirtyWorktree(_ message: String) -> Bool {
        message.contains("contains modified or untracked files")
            || message.contains("use --force")
    }

    static func removeWorktreeArguments(
        for worktree: GitWorktree,
        force: Bool = false
    ) throws -> [String] {
        guard !worktree.isCurrent else {
            throw GitOperationError(
                command: "git worktree remove",
                message: "The current worktree cannot be deleted."
            )
        }
        guard !worktree.isBare else {
            throw GitOperationError(
                command: "git worktree remove",
                message: "Bare worktrees cannot be deleted here."
            )
        }
        guard !worktree.isLocked else {
            throw GitOperationError(
                command: "git worktree remove",
                message: "Unlock this worktree before deleting it."
            )
        }
        guard !worktree.isPrunable else {
            throw GitOperationError(
                command: "git worktree remove",
                message: "Prune this missing worktree instead of deleting it."
            )
        }
        return force
            ? ["worktree", "remove", "--force", "--", worktree.path]
            : ["worktree", "remove", "--", worktree.path]
    }

    func pruneStaleWorktrees(at root: URL) async throws {
        _ = try await run(Self.pruneStaleWorktreeArguments, in: root)
    }

    static let pruneStaleWorktreeArguments = [
        "worktree",
        "prune",
        "--expire",
        "now"
    ]

    func stash(
        at root: URL,
        message: String,
        scope: StashScope = .all
    ) async throws {
        if scope == .staged {
            let status = try await run(
                ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                in: root
            )
            let hasPartiallyStagedFile = GitParser.parseStatus(Data(status.output.utf8))
                .contains { $0.isStaged && $0.isUnstaged }
            guard !hasPartiallyStagedFile else {
                throw GitOperationError(
                    command: "git stash push --staged",
                    message: """
                    Staged-only stash is unavailable while a file has both staged and \
                    unstaged changes. Separate those hunks first so Git cannot create \
                    a stash and then fail while cleaning the working tree.
                    """
                )
            }
        }

        _ = try await run(
            Self.stashArguments(message: message, scope: scope),
            in: root
        )
    }

    static func stashArguments(message: String, scope: StashScope) -> [String] {
        var arguments = ["stash", "push"]
        switch scope {
        case .staged:
            arguments.append("--staged")
        case .unstaged:
            arguments += ["--keep-index", "--include-untracked"]
        case .all:
            arguments.append("--include-untracked")
        }
        arguments += ["-m", message]
        return arguments
    }

    func applyStash(at root: URL, stash: GitStash) async throws {
        _ = try await run(
            Self.applyStashArguments(selector: stash.selector),
            in: root
        )
    }

    static func applyStashArguments(selector: String) -> [String] {
        ["stash", "apply", "--index", selector]
    }

    func dropStash(at root: URL, stash: GitStash) async throws {
        _ = try await run(
            Self.dropStashArguments(selector: stash.selector),
            in: root
        )
    }

    static func dropStashArguments(selector: String) -> [String] {
        ["stash", "drop", selector]
    }

    private func resolvePushTarget(
        at root: URL,
        branch: String,
        hasUpstream: Bool
    ) async throws -> GitPushTarget? {
        guard !BranchDisplay(branch).isDetached else { return nil }

        if hasUpstream {
            async let remoteResult = runAllowingFailure(
                ["config", "--get", "branch.\(branch).remote"],
                in: root
            )
            async let mergeResult = runAllowingFailure(
                ["config", "--get", "branch.\(branch).merge"],
                in: root
            )
            let remoteCommand = try await remoteResult
            let mergeCommand = try await mergeResult
            let remote = remoteCommand.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteRef = mergeCommand.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard remoteCommand.exitCode == 0,
                  mergeCommand.exitCode == 0,
                  !remote.isEmpty,
                  remote != ".",
                  remoteRef.hasPrefix("refs/heads/") else {
                return nil
            }
            return GitPushTarget(
                remote: remote,
                remoteRef: remoteRef,
                establishesUpstream: false
            )
        }

        let remotes = try await run(["remote"], in: root).output
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let remote = remotes.first else { return nil }
        return GitPushTarget(
            remote: remote,
            remoteRef: "refs/heads/\(branch)",
            establishesUpstream: true
        )
    }

    private func apply(
        _ patch: String,
        at root: URL,
        cached: Bool,
        reverse: Bool
    ) async throws {
        let patchData = Data(patch.utf8)
        var arguments = ["apply", "--recount"]
        if cached {
            arguments.append("--cached")
        }
        if reverse {
            arguments.append("--reverse")
        }

        _ = try await run(arguments + ["--check", "-"], in: root, input: patchData)
        _ = try await run(arguments + ["-"], in: root, input: patchData)
    }

    private func run(
        _ arguments: [String],
        in directory: URL,
        input: Data? = nil
    ) async throws -> GitCommandResult {
        let result = try await execute(arguments, in: directory, input: input)
        guard result.exitCode == 0 else {
            throw GitOperationError(
                command: "git \(arguments.joined(separator: " "))",
                message: result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    private func runAllowingFailure(
        _ arguments: [String],
        in directory: URL
    ) async throws -> GitCommandResult {
        try await execute(arguments, in: directory, input: nil)
    }

    private func execute(
        _ arguments: [String],
        in directory: URL,
        input: Data?
    ) async throws -> GitCommandResult {
        let gitURL = self.gitURL
        let cancellation = GitProcessCancellation()
        let startedAt = Date()
        func log(_ outcome: GitCommandOutcome, outputByteCount: Int = 0, error: String) {
            GitCommandLog.record(
                arguments: arguments,
                directory: directory,
                hasInput: input != nil,
                startedAt: startedAt,
                outcome: outcome,
                outputByteCount: outputByteCount,
                errorOutput: error
            )
        }

        let result: GitCommandResult
        do {
            result = try await runProcess(
                arguments,
                in: directory,
                input: input,
                gitURL: gitURL,
                cancellation: cancellation
            )
        } catch is CancellationError {
            // Only commands that actually ran belong in the log.
            if cancellation.hasLaunched {
                log(.cancelled, error: "")
            }
            throw CancellationError()
        } catch {
            log(.failed(exitCode: nil), error: error.localizedDescription)
            throw error
        }

        log(
            result.exitCode == 0 ? .succeeded : .failed(exitCode: result.exitCode),
            outputByteCount: result.output.utf8.count,
            error: result.error
        )
        return result
    }

    private func runProcess(
        _ arguments: [String],
        in directory: URL,
        input: Data?,
        gitURL: URL,
        cancellation: GitProcessCancellation
    ) async throws -> GitCommandResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                let process = Process()
                guard cancellation.install(process) else {
                    throw CancellationError()
                }
                defer { cancellation.clear(process) }

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let inputPipe = input == nil ? nil : Pipe()
                process.executableURL = gitURL
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = inputPipe

                process.environment = Self.processEnvironment

                try process.run()
                cancellation.processDidStart()

                if let input, let inputPipe {
                    inputPipe.fileHandleForWriting.write(input)
                    try inputPipe.fileHandleForWriting.close()
                }

                let outputTask = Task.detached {
                    outputPipe.fileHandleForReading.readDataToEndOfFile()
                }
                let errorTask = Task.detached {
                    errorPipe.fileHandleForReading.readDataToEndOfFile()
                }

                process.waitUntilExit()
                let outputData = await outputTask.value
                let errorData = await errorTask.value
                if cancellation.isCancelled {
                    throw CancellationError()
                }

                return GitCommandResult(
                    output: String(decoding: outputData, as: UTF8.self),
                    error: String(decoding: errorData, as: UTF8.self),
                    exitCode: process.terminationStatus
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

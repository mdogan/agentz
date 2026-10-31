import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case history = "All Commits"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .changes: "square.and.pencil"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum CommitHistoryScope: Equatable, Sendable {
    case all
    case revision(String)
    case commit(String)
    /// Commits touching `path`, limited to the history reachable from
    /// `revision`. The revision is a full ref name, or `HEAD` when no
    /// reference is selected.
    case path(String, revision: String)
    case lostAndDangling

    init(revision: String?) {
        self = revision.map(Self.revision) ?? .all
    }
}

/// A request to scroll the history list to a commit the user opened by hash.
/// The identifier makes every request distinct, so opening the same commit
/// twice scrolls to it twice.
struct CommitReveal: Equatable, Sendable {
    let id = UUID()
    let hash: String
}

struct RepositoryPathItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case directory
        case file
    }

    let path: String
    let kind: Kind

    var id: String {
        "\(kind.rawValue):\(path)"
    }
}

enum ReferenceKind: String, Sendable {
    case localBranch
    case remoteBranch
    case tag

    var title: String {
        switch self {
        case .localBranch: "Branches"
        case .remoteBranch: "Remotes"
        case .tag: "Tags"
        }
    }

    var icon: String {
        switch self {
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }
}

/// The remote-tracking branch configured for a local branch through
/// `branch.<name>.remote` and `branch.<name>.merge`.
struct GitUpstream: Hashable, Sendable {
    /// The local remote-tracking ref, such as `refs/remotes/origin/feature`.
    let fullName: String
    /// The display form, such as `origin/feature`.
    let shortName: String
    /// The remote name, such as `origin`.
    let remote: String
    /// The ref as it exists on the remote, such as `refs/heads/feature`.
    let remoteRef: String
}

struct GitReference: Identifiable, Hashable, Sendable {
    let name: String
    let fullName: String
    let kind: ReferenceKind
    let target: String
    let isCurrent: Bool
    let upstream: GitUpstream?

    init(
        name: String,
        fullName: String,
        kind: ReferenceKind,
        target: String,
        isCurrent: Bool,
        upstream: GitUpstream? = nil
    ) {
        self.name = name
        self.fullName = fullName
        self.kind = kind
        self.target = target
        self.isCurrent = isCurrent
        self.upstream = upstream
    }

    var id: String { fullName }

    /// The branch on the remote that this remote-tracking ref stands for, such
    /// as `refs/heads/feature` on `origin` for `refs/remotes/origin/feature`.
    /// The first path component names the remote, matching how Git lays out
    /// `refs/remotes/`. Returns `nil` for anything that does not name a branch
    /// beneath a remote.
    var remoteBranchTarget: GitUpstream? {
        guard kind == .remoteBranch,
              let separator = name.firstIndex(of: "/") else {
            return nil
        }
        let remote = String(name[..<separator])
        let branch = String(name[name.index(after: separator)...])
        guard !remote.isEmpty, !branch.isEmpty else { return nil }
        return GitUpstream(
            fullName: fullName,
            shortName: name,
            remote: remote,
            remoteRef: "refs/heads/\(branch)"
        )
    }

    static func primaryLocalBranch(in references: [GitReference]) -> GitReference? {
        references.first { $0.kind == .localBranch && $0.name == "main" }
            ?? references.first { $0.kind == .localBranch && $0.name == "master" }
    }
}

struct ReferenceTreeNode: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let kind: ReferenceKind
    let reference: GitReference?
    let children: [ReferenceTreeNode]

    var id: String {
        "\(kind.rawValue):\(path)"
    }

    static func build(from references: [GitReference]) -> [ReferenceTreeNode] {
        build(from: references, components: [], depth: 0)
    }

    private static func build(
        from references: [GitReference],
        components: [String],
        depth: Int
    ) -> [ReferenceTreeNode] {
        let grouped = Dictionary(grouping: references) {
            $0.name.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)[depth]
        }

        return grouped.map { name, matches in
            let pathComponents = components + [name]
            let path = pathComponents.joined(separator: "/")
            let exact = matches.first {
                $0.name.split(separator: "/", omittingEmptySubsequences: false).count == depth + 1
            }
            let descendants = matches.filter {
                $0.name.split(separator: "/", omittingEmptySubsequences: false).count > depth + 1
            }

            return ReferenceTreeNode(
                name: name,
                path: path,
                kind: matches[0].kind,
                reference: exact,
                children: descendants.isEmpty
                    ? []
                    : build(
                        from: descendants,
                        components: pathComponents,
                        depth: depth + 1
                    )
            )
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// A local branch moved under a different name prefix by dropping it on a
/// sidebar folder. Prefixes can be any depth: `team/fix/login` dropped on
/// `experimental/ui` becomes `experimental/ui/login`. The branch keeps its last
/// path component and an empty prefix moves it to the top level.
struct GitBranchMove: Hashable, Sendable {
    let reference: GitReference
    let destinationPrefix: String
    let newName: String

    /// Returns `nil` for anything but a local branch, and when the branch
    /// already sits directly under `prefix`.
    init?(reference: GitReference, toPrefix prefix: String) {
        guard reference.kind == .localBranch else { return nil }
        let leaf = reference.name.components(separatedBy: "/").last ?? reference.name
        let newName = prefix.isEmpty ? leaf : "\(prefix)/\(leaf)"
        guard newName != reference.name else { return nil }
        self.reference = reference
        self.destinationPrefix = prefix
        self.newName = newName
    }

    /// Every prefix in use by a local branch, at every depth, sorted the way
    /// the sidebar sorts folders: `team/fix/login` contributes both `team`
    /// and `team/fix`.
    static func prefixes(in references: [GitReference]) -> [String] {
        var prefixes = Set<String>()
        for reference in references where reference.kind == .localBranch {
            let components = reference.name.components(separatedBy: "/").dropLast()
            for depth in components.indices {
                prefixes.insert(components[...depth].joined(separator: "/"))
            }
        }
        return prefixes.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Normalizes a typed prefix: surrounding whitespace and slashes are
    /// dropped, so `" experimental/ui/ "` names the `experimental/ui` prefix.
    static func normalizedPrefix(_ prefix: String) -> String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The local branch that already occupies the new name, either exactly or
    /// as a folder of the same name, which Git's ref layout cannot hold
    /// alongside a branch.
    func conflictingBranch(in references: [GitReference]) -> GitReference? {
        references.first {
            $0.kind == .localBranch
                && $0 != reference
                && ($0.name == newName || $0.name.hasPrefix(newName + "/"))
        }
    }
}

struct GitStash: Identifiable, Hashable, Sendable {
    let selector: String
    let hash: String
    let subject: String

    var id: String { hash }

    var displayName: String {
        guard subject.hasPrefix("On "),
              let separator = subject.range(of: ": ") else {
            return subject
        }
        return String(subject[separator.upperBound...])
    }
}

struct GitPushTarget: Hashable, Sendable {
    let remote: String
    let remoteRef: String
    let establishesUpstream: Bool

    var branchName: String {
        remoteRef.hasPrefix("refs/heads/")
            ? String(remoteRef.dropFirst("refs/heads/".count))
            : remoteRef
    }

    var displayName: String {
        "\(remote)/\(branchName)"
    }
}

/// The exact local branch and remote destination approved by the push UI.
/// Keeping the source ref in the plan lets sidebar pushes operate on a branch
/// without checking it out first.
struct GitPushPlan: Hashable, Sendable {
    let branchName: String
    let sourceRef: String
    let target: GitPushTarget
    let ahead: Int?
}

enum StashScope: String, Sendable {
    case staged
    case unstaged
    case all

    var title: String {
        switch self {
        case .staged: "Staged Changes"
        case .unstaged: "Unstaged Changes"
        case .all: "All Changes"
        }
    }

    var description: String {
        switch self {
        case .staged:
            "Only staged changes will be saved. Unstaged and untracked changes will remain."
        case .unstaged:
            "Unstaged and untracked changes will be saved. Staged changes will remain."
        case .all:
            "Staged, unstaged, and untracked changes will be saved."
        }
    }
}

struct GitWorktree: Identifiable, Hashable, Sendable {
    let path: String
    let head: String?
    let branch: String?
    let isBare: Bool
    let isDetached: Bool
    let isLocked: Bool
    let isPrunable: Bool
    let isCurrent: Bool

    var id: String { path }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var branchName: String? {
        branch.map {
            $0.hasPrefix("refs/heads/")
                ? String($0.dropFirst("refs/heads/".count))
                : $0
        }
    }

    /// Whether `root` is a linked worktree, read from its files instead of Git
    /// so the recent-repositories list can check every entry while it loads.
    static func isLinked(at root: URL) -> Bool {
        linkedGitDirectory(at: root) != nil
    }

    /// The main worktree of the repository that the linked worktree at `root`
    /// belongs to. `nil` when `root` is not a linked worktree, and when the
    /// repository is bare or keeps its Git directory away from its main
    /// worktree, so there is no main worktree to point at.
    static func mainWorktree(ofLinked root: URL) -> URL? {
        guard let gitDirectory = linkedGitDirectory(at: root),
              let path = firstLine(of: gitDirectory.appendingPathComponent("commondir")) else {
            return nil
        }

        // Git finds the main worktree the same way: the common directory
        // without its trailing `.git`.
        let commonDirectory = resolve(path, against: gitDirectory).standardizedFileURL
        guard commonDirectory.lastPathComponent == ".git" else { return nil }
        return commonDirectory.deletingLastPathComponent()
    }

    /// A linked worktree's `.git` is a file naming `<common dir>/worktrees/<name>`,
    /// and only that directory holds a `commondir` file; a submodule's `.git`
    /// file names a directory without one.
    static func linkedGitDirectory(at root: URL) -> URL? {
        guard let line = firstLine(of: root.appendingPathComponent(".git")),
              line.hasPrefix("gitdir:") else {
            return nil
        }

        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDirectory = resolve(path, against: root)
        guard FileManager.default.fileExists(
            atPath: gitDirectory.appendingPathComponent("commondir").path
        ) else {
            return nil
        }
        return gitDirectory
    }

    private static func firstLine(of file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first else {
            return nil
        }
        return String(line).trimmingCharacters(in: .whitespaces)
    }

    private static func resolve(_ path: String, against directory: URL) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : directory.appendingPathComponent(path, isDirectory: true)
    }
}

enum GitSignatureStatus: Character, Hashable, Sendable {
    case good = "G"
    case bad = "B"
    case unknownValidity = "U"
    case expiredSignature = "X"
    case expiredKey = "Y"
    case revokedKey = "R"
    case cannotCheck = "E"
    case none = "N"

    init(code: Character?) {
        self = code.flatMap(Self.init(rawValue:)) ?? .cannotCheck
    }

    var isSigned: Bool { self != .none }

    var title: String {
        switch self {
        case .good: "Verified signature"
        case .bad: "Bad signature"
        case .unknownValidity: "Signed · unknown trust"
        case .expiredSignature: "Signed · signature expired"
        case .expiredKey: "Signed · key expired"
        case .revokedKey: "Signed · key revoked"
        case .cannotCheck: "Signed · verification unavailable"
        case .none: "Unsigned"
        }
    }
}

struct GitCommitSignature: Hashable, Sendable {
    let status: GitSignatureStatus
    let keyID: String
    let signer: String

    static let unsigned = GitCommitSignature(
        status: .none,
        keyID: "",
        signer: ""
    )

    var details: String {
        var parts = [status.title]
        if !signer.isEmpty {
            parts.append(signer)
        }
        if !keyID.isEmpty {
            parts.append("Key \(keyID)")
        }
        return parts.joined(separator: " · ")
    }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let hash: String
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let date: Date
    let decorations: [String]
    let signature: GitCommitSignature
    let subject: String

    var id: String { hash }
    var shortHash: String { String(hash.prefix(8)) }
    var initials: String {
        let parts = authorName.split(separator: " ")
        return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct WorkingChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let indexStatus: Character
    let workTreeStatus: Character

    var id: String {
        "\(path)|\(indexStatus)|\(workTreeStatus)"
    }

    var isStaged: Bool {
        !isConflicted && indexStatus != " " && indexStatus != "?"
    }

    var isUnstaged: Bool {
        !isConflicted
            && (workTreeStatus != " " || (indexStatus == "?" && workTreeStatus == "?"))
    }

    var isUntracked: Bool {
        indexStatus == "?" && workTreeStatus == "?"
    }

    /// Porcelain v1 uses these seven two-character states for paths whose
    /// index still contains unmerged stages. They are neither staged changes
    /// nor ordinary working-tree changes until the user resolves them.
    var isConflicted: Bool {
        switch (indexStatus, workTreeStatus) {
        case ("D", "D"), ("A", "U"), ("U", "D"), ("U", "A"),
             ("D", "U"), ("A", "A"), ("U", "U"):
            true
        default:
            false
        }
    }

    var conflictDescription: String? {
        switch (indexStatus, workTreeStatus) {
        case ("D", "D"): "Both deleted"
        case ("A", "U"): "Added by us"
        case ("U", "D"): "Deleted by them"
        case ("U", "A"): "Added by them"
        case ("D", "U"): "Deleted by us"
        case ("A", "A"): "Both added"
        case ("U", "U"): "Both modified"
        default: nil
        }
    }

    func hasConflictVersion(_ side: ConflictResolutionSide) -> Bool {
        guard isConflicted else { return false }
        return switch side {
        case .ours:
            switch (indexStatus, workTreeStatus) {
            case ("A", "U"), ("U", "D"), ("A", "A"), ("U", "U"): true
            default: false
            }
        case .theirs:
            switch (indexStatus, workTreeStatus) {
            case ("U", "A"), ("D", "U"), ("A", "A"), ("U", "U"): true
            default: false
            }
        }
    }

    var displayStatus: String {
        displayStatus(staged: isStaged)
    }

    func displayStatus(staged: Bool) -> String {
        if isConflicted {
            return "Conflict"
        }
        let status = staged ? indexStatus : workTreeStatus
        return switch status {
        case "A", "?": "Added"
        case "M": "Modified"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "U": "Conflict"
        default: "Changed"
        }
    }

    var statusSymbol: String {
        statusSymbol(staged: isStaged)
    }

    func statusSymbol(staged: Bool) -> String {
        if isConflicted {
            return "U"
        }
        let status = staged ? indexStatus : workTreeStatus
        return status == "?" ? "A" : String(status)
    }
}

enum ConflictResolutionSide: String, Sendable {
    case ours
    case theirs

    var title: String {
        switch self {
        case .ours: "Ours"
        case .theirs: "Theirs"
        }
    }
}

/// What HEAD currently points at, recovered from the single string Git reports
/// for the current branch. A detached HEAD is a repository state rather than a
/// branch name, so the UI can present it as one instead of printing a sentence.
enum BranchDisplay: Equatable, Sendable, CustomStringConvertible {
    case branch(String)
    case detached(hash: String)

    static let detachedPrefix = "Detached at "

    init(_ head: String) {
        guard head.hasPrefix(Self.detachedPrefix) else {
            self = .branch(head)
            return
        }
        self = .detached(hash: String(head.dropFirst(Self.detachedPrefix.count)))
    }

    /// The round-trippable description stored in `RepositorySnapshot.branch`.
    var description: String {
        switch self {
        case let .branch(name): name
        case let .detached(hash): Self.detachedPrefix + hash
        }
    }

    var isDetached: Bool {
        if case .detached = self { return true }
        return false
    }

    /// The branch name, or `nil` while HEAD is detached and there is none.
    var branchName: String? {
        if case let .branch(name) = self { return name }
        return nil
    }
}

struct RepositorySnapshot: Sendable {
    let root: URL
    let branch: String
    let upstream: String?
    let pushTarget: GitPushTarget?
    let ahead: Int
    let behind: Int
    let changes: [WorkingChange]
    let references: [GitReference]
    let stashes: [GitStash]
    let worktrees: [GitWorktree]
    let commits: [GitCommit]
}

struct GitCommandResult: Sendable {
    let output: String
    let error: String
    let exitCode: Int32
}

struct GitOperationError: LocalizedError, Sendable {
    let command: String
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "Git command failed: \(command)" : message
    }
}

struct UnmergedBranchDeletionError: LocalizedError, Sendable {
    let branch: String
    let message: String

    var errorDescription: String? {
        message
    }
}

/// Raised when `git worktree remove` refuses because the worktree holds
/// modified or untracked files. Removing it anyway requires `--force`, so the
/// UI turns this into a second, explicit confirmation.
struct DirtyWorktreeRemovalError: LocalizedError, Sendable {
    let path: String
    let message: String

    var errorDescription: String? {
        message
    }
}

enum GitParser {
    static func parseStatus(_ data: Data) -> [WorkingChange] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var changes: [WorkingChange] = []
        var index = 0

        while index < fields.count {
            let field = String(decoding: fields[index], as: UTF8.self)
            guard field.count >= 3 else {
                index += 1
                continue
            }

            let status = Array(field.prefix(2))
            guard status[0] != "#" else {
                index += 1
                continue
            }
            let pathStart = field.index(field.startIndex, offsetBy: 3)
            let path = String(field[pathStart...])
            var originalPath: String?

            if status[0] == "R" || status[0] == "C" {
                index += 1
                if index < fields.count {
                    originalPath = String(decoding: fields[index], as: UTF8.self)
                }
            }

            changes.append(
                WorkingChange(
                    path: path,
                    originalPath: originalPath,
                    indexStatus: status[0],
                    workTreeStatus: status[1]
                )
            )
            index += 1
        }

        return changes.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    static func parseCommits(_ text: String) -> [GitCommit] {
        let formatter = ISO8601DateFormatter()

        return text
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let clean = record.trimmingCharacters(in: .whitespacesAndNewlines)
                let fields = clean.components(separatedBy: "\u{1f}")
                guard fields.count >= 7 else { return nil }

                let decorations = fields[5]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                let signature: GitCommitSignature
                let subject: String
                if fields.count >= 11 {
                    let rawVerification = fields[9]
                    let reportedStatus = GitSignatureStatus(code: fields[6].first)
                    signature = GitCommitSignature(
                        status: reportedStatus == .none && !rawVerification.isEmpty
                            ? .cannotCheck
                            : reportedStatus,
                        keyID: fields[7].isEmpty
                            ? signingKey(from: rawVerification)
                            : fields[7],
                        signer: fields[8]
                    )
                    subject = fields[10]
                } else {
                    signature = .unsigned
                    subject = fields[6]
                }

                return GitCommit(
                    hash: fields[0],
                    parents: fields[1].split(separator: " ").map(String.init),
                    authorName: fields[2],
                    authorEmail: fields[3],
                    date: formatter.date(from: fields[4]) ?? .distantPast,
                    decorations: decorations,
                    signature: signature,
                    subject: subject
                )
            }
    }

    private static func signingKey(from verification: String) -> String {
        for line in verification.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: " key ", options: .caseInsensitive) else {
                continue
            }
            return line[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func parseReferences(_ text: String, currentBranch: String) -> [GitReference] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { return nil }

            let fullName = fields[0]
            let kind: ReferenceKind
            let name: String

            if fullName.hasPrefix("refs/heads/") {
                kind = .localBranch
                name = String(fullName.dropFirst("refs/heads/".count))
            } else if fullName.hasPrefix("refs/remotes/") {
                guard !fullName.hasSuffix("/HEAD") else { return nil }
                kind = .remoteBranch
                name = String(fullName.dropFirst("refs/remotes/".count))
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
                name = String(fullName.dropFirst("refs/tags/".count))
            } else {
                return nil
            }

            return GitReference(
                name: name,
                fullName: fullName,
                kind: kind,
                target: fields[2],
                isCurrent: kind == .localBranch && name == currentBranch,
                upstream: kind == .localBranch ? upstream(from: fields) : nil
            )
        }
        .sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    /// Reads the `%(upstream...)` fields of a `for-each-ref` record. Git leaves
    /// them empty for branches without tracking configuration.
    private static func upstream(from fields: [String]) -> GitUpstream? {
        guard fields.count >= 7 else { return nil }
        let fullName = fields[3]
        let shortName = fields[4]
        let remote = fields[5]
        let remoteRef = fields[6]
        guard !fullName.isEmpty,
              !shortName.isEmpty,
              !remote.isEmpty,
              !remoteRef.isEmpty else {
            return nil
        }
        return GitUpstream(
            fullName: fullName,
            shortName: shortName,
            remote: remote,
            remoteRef: remoteRef
        )
    }

    static func parseStashes(_ text: String) -> [GitStash] {
        text.split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\u{1f}")
                guard fields.count >= 3 else { return nil }
                return GitStash(
                    selector: fields[0],
                    hash: fields[1],
                    subject: fields[2]
                )
            }
    }

    static func parseWorktrees(_ text: String, currentRoot: URL) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var attributes: [String: String] = [:]

        func finishRecord() {
            guard let path = attributes["worktree"] else {
                attributes.removeAll(keepingCapacity: true)
                return
            }
            let candidate = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            worktrees.append(
                GitWorktree(
                    path: path,
                    head: attributes["HEAD"],
                    branch: attributes["branch"],
                    isBare: attributes.keys.contains("bare"),
                    isDetached: attributes.keys.contains("detached"),
                    isLocked: attributes.keys.contains("locked"),
                    isPrunable: attributes.keys.contains("prunable"),
                    isCurrent: candidate
                        == currentRoot.resolvingSymlinksInPath().standardizedFileURL
                )
            )
            attributes.removeAll(keepingCapacity: true)
        }

        for field in text.components(separatedBy: "\0") {
            guard !field.isEmpty else {
                if !attributes.isEmpty {
                    finishRecord()
                }
                continue
            }

            if let separator = field.firstIndex(of: " ") {
                attributes[String(field[..<separator])] = String(field[field.index(after: separator)...])
            } else {
                attributes[field] = ""
            }
        }

        if !attributes.isEmpty {
            finishRecord()
        }
        return worktrees
    }
}

import Foundation
import Observation

/// What a Git command does to the repository, read from its arguments so the
/// command log can label and filter every command GitFork runs.
enum GitCommandKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Reads repository state without changing it.
    case read
    /// Changes the index, the working tree, refs, or configuration.
    case write
    /// Removes something that may not be recoverable: a branch, tag, stash,
    /// worktree, remote branch, or uncommitted changes.
    case delete
    /// Talks to a remote: fetch, pull, and push.
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "Read"
        case .write: "Write"
        case .delete: "Delete"
        case .network: "Network"
        }
    }

    var systemImage: String {
        switch self {
        case .read: "eye"
        case .write: "pencil"
        case .delete: "trash"
        case .network: "arrow.up.arrow.down"
        }
    }

    /// Git options that come before the subcommand and take a separate value.
    private static let globalOptionsWithValue: Set<String> = [
        "-c", "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path"
    ]

    static func classify(_ arguments: [String]) -> GitCommandKind {
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") {
            index += globalOptionsWithValue.contains(arguments[index]) ? 2 : 1
        }
        guard index < arguments.count else { return .read }

        let subcommand = arguments[index]
        let rest = arguments[(index + 1)...]
        // Paths after `--` are never options.
        let beforePaths = rest.prefix { $0 != "--" }
        let options = Set(beforePaths.filter { $0.hasPrefix("-") })
        let operands = beforePaths.filter { !$0.hasPrefix("-") }
        let hasPaths = rest.contains("--")
        func has(_ flags: String...) -> Bool {
            flags.contains { options.contains($0) }
        }

        switch subcommand {
        case "status", "diff", "log", "show", "rev-parse", "rev-list",
             "for-each-ref", "show-ref", "ls-files", "ls-tree", "cat-file",
             "merge-base", "blame", "grep", "describe", "name-rev", "shortlog",
             "check-ignore", "count-objects", "var", "version":
            return .read

        case "fetch", "pull", "ls-remote", "clone":
            return .network

        case "push":
            let deletesRef = rest.contains { $0.hasPrefix(":") && $0.count > 1 }
            return has("--delete", "-d") || deletesRef ? .delete : .network

        case "symbolic-ref":
            if has("--delete", "-d") { return .delete }
            return operands.count > 1 ? .write : .read

        case "config":
            if options.contains(where: { $0.hasPrefix("--get") })
                || has("--list", "-l") {
                return .read
            }
            return .write

        case "remote":
            switch operands.first {
            case nil, "show", "get-url": return .read
            case "remove", "rm", "prune": return .delete
            default: return .write
            }

        case "stash":
            switch operands.first {
            case "list", "show": return .read
            case "drop", "clear": return .delete
            default: return .write
            }

        case "worktree":
            switch operands.first {
            case "list": return .read
            case "remove", "prune": return .delete
            default: return .write
            }

        case "branch":
            if has("-d", "-D", "--delete") { return .delete }
            if has("-m", "-M", "--move", "-c", "-C", "--copy",
                   "-u", "--unset-upstream", "--edit-description")
                || options.contains(where: { $0.hasPrefix("--set-upstream-to") }) {
                return .write
            }
            return operands.isEmpty || has("--list", "-l") ? .read : .write

        case "tag":
            if has("-d", "--delete") { return .delete }
            return operands.isEmpty || has("--list", "-l") ? .read : .write

        case "apply":
            if has("--check", "--stat", "--numstat", "--summary") { return .read }
            // A reversed patch applied to the working tree discards changes.
            if has("--reverse", "-R"), !has("--cached", "--index") { return .delete }
            return .write

        case "restore":
            // `restore` touches the working tree unless only --staged is given.
            let touchesWorktree = has("--worktree", "-W") || !has("--staged", "-S")
            return touchesWorktree ? .delete : .write

        case "clean":
            return has("-n", "--dry-run") ? .read : .delete

        case "rm":
            return has("--cached") ? .write : .delete

        case "reset":
            return has("--hard") ? .delete : .write

        case "checkout":
            // Checking out paths replaces their working-tree changes, except
            // when a conflict side is chosen on purpose.
            if hasPaths, !has("--ours", "--theirs") { return .delete }
            return .write

        case "prune":
            return .delete

        default:
            return .write
        }
    }
}

enum GitCommandOutcome: Hashable, Codable, Sendable {
    case succeeded
    /// The process exited with a non-zero status, or could not start
    /// (`exitCode` is `nil`).
    case failed(exitCode: Int32?)
    /// GitFork stopped the command after it started, usually because its
    /// result was no longer needed.
    case cancelled
}

struct GitCommandLogEntry: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    let arguments: [String]
    let directory: URL
    /// Whether the command read a patch or other data from standard input.
    let hasInput: Bool
    let startedAt: Date
    let duration: TimeInterval
    let outcome: GitCommandOutcome
    let outputByteCount: Int
    let errorOutput: String

    var kind: GitCommandKind { GitCommandKind.classify(arguments) }

    var isFailure: Bool {
        if case .failed = outcome { return true }
        return false
    }

    /// The command as it can be pasted into a shell.
    var commandLine: String {
        (["git"] + arguments.map(Self.shellQuoted)).joined(separator: " ")
    }

    private static let shellSafeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_./=:@%+,^~"))

    static func shellQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        if argument.unicodeScalars.allSatisfy(shellSafeCharacters.contains) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Keeps the Git commands GitFork ran, oldest first, for the command log
/// window. Commands run while `GitCommandLogScope.isSuppressed` is set (the
/// background change poller) are not kept. Once `startPersisting(to:)` is
/// called, the log is saved to disk and restored at the next launch; either
/// way it keeps only today and the six days before it.
@MainActor
@Observable
final class GitCommandLog {
    static let shared = GitCommandLog()
    /// A safety cap on top of the seven-day window.
    nonisolated static let defaultLimit = 20_000
    /// Today and the six days before it.
    nonisolated static let retainedDays = 7
    nonisolated private static let errorOutputLimit = 4000
    private static let repositoryRootsKey = "gitCommandLogRepositoryRoots"

    private(set) var entries: [GitCommandLogEntry] = []
    /// Repository roots opened in GitFork. A command run in a subdirectory is
    /// shown under the root that contains it.
    private(set) var repositoryRoots: Set<String> = []
    /// Asks the log window to show one repository, or every repository when
    /// the path is `nil`.
    private(set) var focusRequest: GitCommandLogFocusRequest?
    private let limit: Int
    private let calendar: Calendar
    private let now: () -> Date
    @ObservationIgnored private var file: GitCommandLogFile?
    @ObservationIgnored private var defaults: UserDefaults?

    init(
        limit: Int = GitCommandLog.defaultLimit,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        precondition(limit > 0)
        self.limit = limit
        self.calendar = calendar
        self.now = now
    }

    /// The oldest start time the log keeps: the start of the sixth day
    /// before today.
    nonisolated static func retentionCutoff(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(retainedDays - 1), to: today) ?? today
    }

    /// Restores the saved log and saves every command recorded from now on.
    func startPersisting(to file: GitCommandLogFile, defaults: UserDefaults = .standard) {
        guard self.file == nil else { return }
        self.file = file
        self.defaults = defaults
        repositoryRoots.formUnion(defaults.stringArray(forKey: Self.repositoryRootsKey) ?? [])
        for entry in entries {
            file.append(entry)
        }

        let cutoff = Self.retentionCutoff(now: now(), calendar: calendar)
        let limit = limit
        Task {
            let saved = await file.load(since: cutoff, limit: limit)
            restore(saved)
        }
    }

    /// Merges entries read from disk with any recorded while they loaded.
    func restore(_ saved: [GitCommandLogEntry]) {
        let known = Set(entries.map(\.id))
        entries = (saved.filter { !known.contains($0.id) } + entries)
            .sorted { $0.startedAt < $1.startedAt }
        pruneExpired()
        // Keep only roots that some kept command still belongs to.
        let directories = entries.map { $0.directory.standardizedFileURL.path }
        let used = repositoryRoots.filter { root in
            directories.contains { $0 == root || $0.hasPrefix(root + "/") }
        }
        if used != repositoryRoots {
            repositoryRoots = used
            saveRepositoryRoots()
        }
    }

    func record(_ entry: GitCommandLogEntry) {
        // Commands finish out of order; keep the list in start order.
        var index = entries.endIndex
        while index > entries.startIndex,
              entries[index - 1].startedAt > entry.startedAt {
            index -= 1
        }
        entries.insert(entry, at: index)
        file?.append(entry)
        pruneExpired()
    }

    /// Drops commands from before the seven-day window, and the oldest ones
    /// past the size cap, and rewrites the saved log when anything went.
    func pruneExpired() {
        let cutoff = Self.retentionCutoff(now: now(), calendar: calendar)
        let expired = entries.prefix { $0.startedAt < cutoff }.count
        // Trim well under the cap so a full log is not rewritten per command.
        let overLimit = entries.count - expired > limit
            ? entries.count - expired - limit * 9 / 10
            : 0
        guard expired + overLimit > 0 else { return }
        entries.removeFirst(expired + overLimit)
        file?.replace(with: entries)
    }

    func clear() {
        entries.removeAll()
        file?.replace(with: [])
    }

    func registerRepository(_ root: URL) {
        let (inserted, _) = repositoryRoots.insert(root.standardizedFileURL.path)
        if inserted {
            saveRepositoryRoots()
        }
    }

    private func saveRepositoryRoots() {
        defaults?.set(repositoryRoots.sorted(), forKey: Self.repositoryRootsKey)
    }

    func requestFocus(on repository: URL?) {
        focusRequest = GitCommandLogFocusRequest(
            repositoryPath: repository?.standardizedFileURL.path
        )
    }

    /// The opened repository root that contains `entry`'s directory, or the
    /// directory itself when no opened root contains it.
    func repositoryPath(for entry: GitCommandLogEntry) -> String {
        Self.repositoryPath(
            forDirectory: entry.directory.standardizedFileURL.path,
            roots: repositoryRoots
        )
    }

    nonisolated static func repositoryPath(forDirectory directory: String, roots: Set<String>) -> String {
        roots
            .filter { directory == $0 || directory.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
            ?? directory
    }

    /// Records a finished command from any thread.
    nonisolated static func record(
        arguments: [String],
        directory: URL,
        hasInput: Bool,
        startedAt: Date,
        outcome: GitCommandOutcome,
        outputByteCount: Int,
        errorOutput: String
    ) {
        guard !GitCommandLogScope.isSuppressed else { return }
        let trimmedError = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = GitCommandLogEntry(
            arguments: arguments,
            directory: directory,
            hasInput: hasInput,
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            outcome: outcome,
            outputByteCount: outputByteCount,
            errorOutput: String(trimmedError.prefix(errorOutputLimit))
        )
        Task { @MainActor in
            shared.record(entry)
        }
    }
}

/// The saved command log: one JSON entry per line, so recording a command
/// only appends a line. All file work runs in order on a private queue.
final class GitCommandLogFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "agentz.git-command-log")

    init(url: URL) {
        self.url = url
    }

    static var defaultURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support
            .appendingPathComponent("agentz", isDirectory: true)
            .appendingPathComponent("git-command-log.jsonl")
    }

    /// Reads the saved entries that started at or after `cutoff`, newest
    /// `limit` at most, and rewrites the file without the rest.
    func load(since cutoff: Date, limit: Int) async -> [GitCommandLogEntry] {
        await withCheckedContinuation { continuation in
            queue.async { [url] in
                let data = (try? Data(contentsOf: url)) ?? Data()
                let decoded = Self.decode(data, since: cutoff, limit: limit)
                if decoded.droppedLines {
                    Self.write(decoded.entries, to: url)
                }
                continuation.resume(returning: decoded.entries)
            }
        }
    }

    func append(_ entry: GitCommandLogEntry) {
        queue.async { [url] in
            guard let line = Self.encode([entry]) else { return }
            do {
                try Self.createDirectory(for: url)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try line.write(to: url, options: .atomic)
                    return
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // The log is a convenience; a failed save must not interrupt Git work.
            }
        }
    }

    func replace(with entries: [GitCommandLogEntry]) {
        queue.async { [url] in
            Self.write(entries, to: url)
        }
    }

    /// Waits until every queued write has finished.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    static func decode(
        _ data: Data,
        since cutoff: Date,
        limit: Int
    ) -> (entries: [GitCommandLogEntry], droppedLines: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = timestampFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid timestamp \(text)"
                )
            }
            return date
        }
        var entries: [GitCommandLogEntry] = []
        var lineCount = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            lineCount += 1
            guard let entry = try? decoder.decode(GitCommandLogEntry.self, from: Data(line)),
                  entry.startedAt >= cutoff else {
                continue
            }
            entries.append(entry)
        }
        entries.sort { $0.startedAt < $1.startedAt }
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        return (entries, entries.count != lineCount)
    }

    static func encode(_ entries: [GitCommandLogEntry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let formatter = timestampFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { return nil }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    /// Readable UTC timestamps with milliseconds, such as
    /// `2026-09-29T13:04:05.123Z`.
    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func write(_ entries: [GitCommandLogEntry], to url: URL) {
        guard let data = encode(entries) else { return }
        try? createDirectory(for: url)
        try? data.write(to: url, options: .atomic)
    }

    private static func createDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

enum GitCommandLogScope {
    /// Set for work whose commands should not appear in the log.
    @TaskLocal static var isSuppressed = false
}

struct GitCommandLogFocusRequest: Equatable {
    let id = UUID()
    let repositoryPath: String?
}

/// The command log window's filter: which kinds to show, whether to show only
/// failures, one repository or all, one day or all, and free text matched
/// against the command line and directory.
struct GitCommandLogFilter: Equatable {
    var kinds: Set<GitCommandKind> = Set(GitCommandKind.allCases)
    var failedOnly = false
    /// `nil` shows every repository.
    var repositoryPath: String?
    /// `nil` shows every day.
    var dateRange: Range<Date>?
    var searchText = ""

    func matches(_ entry: GitCommandLogEntry, repositoryPath entryRepository: String) -> Bool {
        guard kinds.contains(entry.kind) else { return false }
        if failedOnly, !entry.isFailure { return false }
        if let repositoryPath, entryRepository != repositoryPath { return false }
        if let dateRange, !dateRange.contains(entry.startedAt) { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return entry.commandLine.localizedCaseInsensitiveContains(query)
            || entry.directory.path.localizedCaseInsensitiveContains(query)
    }
}

/// The days the command log keeps, counted back from today: 0 is today, 1 is
/// yesterday, up to `GitCommandLog.retainedDays - 1`.
enum GitCommandLogDay {
    static let offsets = Array(0..<GitCommandLog.retainedDays)

    static func range(daysAgo: Int, now: Date, calendar: Calendar) -> Range<Date> {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return start..<end
    }

    /// How many days before today `date` falls.
    static func daysAgo(_ date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
    }

    /// "Today", "Yesterday", then the weekday and date, such as
    /// "Friday, Sep 26".
    static func title(daysAgo: Int, now: Date, calendar: Calendar) -> String {
        switch daysAgo {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            let day = range(daysAgo: daysAgo, now: now, calendar: calendar).lowerBound
            var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return day.formatted(style)
        }
    }
}

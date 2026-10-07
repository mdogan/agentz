// Conveniences on top of the Swift side UniFFI generates for the Rust core
// (Generated/AgentzCore.swift, from ../core).

import Foundation

public extension Agent {
    var name: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .shell: "shell"
        }
    }

    init?(name: String) {
        guard let agent = [Agent.claude, .codex, .shell].first(where: { $0.name == name }) else { return nil }
        self = agent
    }
}

public extension SessionKey {
    init(_ agent: Agent, _ id: String) {
        self.init(agent: agent, id: id)
    }

    /// From its `description`, `agent:id`.
    init?(parsing text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let agent = Agent(name: parts[0]), !parts[1].isEmpty else { return nil }
        self.init(agent, parts[1])
    }
}

extension SessionKey: CustomStringConvertible {
    public var description: String { "\(agent.name):\(id)" }
}

public extension Session {
    var key: SessionKey { SessionKey(agent, id) }
}

/// Unix seconds, for `Window.left`.
public func unixNow() -> UInt64 {
    UInt64(max(Date().timeIntervalSince1970, 0))
}

public extension Worktree {
    /// Its branch, or what it has instead, e.g. `detached 1a2b3c4`.
    var label: String {
        if bare { return "bare" }
        if let branch { return branch }
        return "detached \(head.prefix(7))"
    }
}

public extension Branch {
    /// `feature/x`, or `origin/feature/x` for a remote-only branch.
    var ref: String {
        remote.map { "\($0)/\(name)" } ?? name
    }
}

public extension RunningElsewhere {
    /// Where it runs, for "Running in …", e.g. `Ghostty`.
    var appName: String {
        switch app {
        case nil: "another app"
        case "Agentz": "another agentz window"
        case let app?: app
        }
    }
}

public extension WorktreeState {
    /// Removing it loses nothing.
    var removable: Bool {
        switch self {
        case .merged, .missing: true
        default: false
        }
    }

    /// What it is, e.g. `2 commits not in main`. `into` is the branch that
    /// merged means merged into.
    func text(into: String) -> String {
        switch self {
        case .merged: "Merged into \(into), nothing uncommitted"
        case .missing: "Its folder is gone"
        case let .changes(files): files == 1 ? "1 uncommitted change" : "\(files) uncommitted changes"
        case let .notMerged(commits): commits == 1 ? "1 commit not in \(into)" : "\(commits) commits not in \(into)"
        case .locked: "Locked"
        case let .inUse(program): "\(program) runs in it"
        case let .unknown(problem): problem
        }
    }
}

/// The branch to show after `place`, `repo` or `repo/worktree`. Not when
/// the worktree is named after it: `fix-x` as agentz names new worktrees,
/// or `x`, for `fix/x`.
public func shownBranch(_ branch: String?, place: String) -> String? {
    guard let branch else { return nil }
    guard let worktree = place.split(separator: "/", maxSplits: 1).dropFirst().first else { return branch }
    let names = [branch.replacingOccurrences(of: "/", with: "-"), branch.split(separator: "/").last.map(String.init)]
    return names.contains(String(worktree)) ? nil : branch
}

/// The deepest worktree that `dir` is in, comparing real paths too.
public func worktree(containing dir: String, in worktrees: [Worktree]) -> Worktree? {
    let dirs = [dir, realPath(dir)].compactMap(\.self)
    return worktrees
        .filter { wt in dirs.contains { pathStarts($0, with: wt.path) } }
        .max { $0.path.count < $1.path.count }
}

/// What went wrong, in the core's own words.
public func errorMessage(_ error: Error) -> String {
    if case let CoreError.Failed(message) = error { return message }
    return "\(error)"
}

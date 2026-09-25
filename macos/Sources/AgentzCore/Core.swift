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

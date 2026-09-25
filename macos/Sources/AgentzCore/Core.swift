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

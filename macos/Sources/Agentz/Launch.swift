import AgentzCore
import Foundation

/// How to start an agent or a shell in the agentz server.
struct Launch {
    /// Run by `bash -c "exec <command>"`.
    var command: String
    /// Added to the environment.
    var env: [String: String] = [:]
    /// Starts the program as a login shell (`exec -l`), as Ghostty does.
    var login = false

    /// Agents run through `/usr/bin/env`, which looks the program up in
    /// PATH.
    static func agent(_ agent: Agent, args: [String], cwd: String) -> Launch {
        var args = args
        var env: [String: String] = [:]
        // Claude only tells its status line how much of the rate limits is
        // left, so we put ours in front of the user's.
        if agent == .claude, let exe = Bundle.main.executablePath, let claude = claudeSettings(cwd, exe) {
            args += ["--settings", claude.settings]
            if let theirs = claude.userCommand { env[userStatusLineVar()] = theirs }
        }
        let program = agent == .claude ? "claude" : "codex"
        let extraVar = agent == .claude ? "AGENTZ_CLAUDE_ARGS" : "AGENTZ_CODEX_ARGS"
        var argv = [program]
        // Extra flags go first so they also apply to `codex resume`.
        let extra = (ProcessInfo.processInfo.environment[extraVar] ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        if agent == .codex, args.first == "resume" {
            argv += ["resume"] + extra + args.dropFirst()
        } else {
            argv += extra + args
        }
        return Launch(command: (["/usr/bin/env"] + argv).map(quoteIfNeeded).joined(separator: " "), env: env)
    }

    /// The user's login shell, with Ghostty's shell integration (folder
    /// reports, prompt marks).
    @MainActor
    static func shell() -> Launch {
        let (argv, env) = GhosttyApp.shellLaunch(ShellEnvironment.shell, env: ShellEnvironment.current())
        return Launch(command: argv.map(quoteIfNeeded).joined(separator: " "), env: env, login: true)
    }

    /// The shell's name, e.g. "fish", used as its title.
    static var shellName: String {
        baseName(ShellEnvironment.shell)
    }

    /// What the server starts: `bash` runs the command as Ghostty would,
    /// with this app's environment and what Ghostty adds to it. The size is
    /// set when the terminal knows it.
    @MainActor
    func spawn(cwd: String, meta: SessionMeta) -> Spawn {
        var env = GhosttyApp.programEnvironment(ShellEnvironment.current())
        env.merge(self.env) { $1 }
        return Spawn(
            argv: ["/bin/bash", "--noprofile", "--norc", "-c", "exec " + (login ? "-l " : "") + command],
            env: env.map { "\($0)=\($1)" }.sorted(),
            cwd: cwd,
            size: TermSize(cols: 80, rows: 24, widthPx: 0, heightPx: 0),
            meta: meta
        )
    }
}

/// Plain words stay as they are, so the command line stays readable in `ps`.
private func quoteIfNeeded(_ s: String) -> String {
    let plain = !s.isEmpty && s.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "/._-+=:,@%".unicodeScalars.contains($0)
    }
    return plain ? s : shellQuote(s)
}

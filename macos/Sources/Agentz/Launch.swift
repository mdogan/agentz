import AgentzCore
import Foundation

/// How to start an agent or a shell in a terminal.
struct Launch {
    /// Run by `bash -c` inside Ghostty's `login` wrapper.
    var command: String
    /// Added to the environment.
    var env: [String: String] = [:]

    /// Agents run through `/usr/bin/env`: Ghostty's wrapper uses `exec -l`,
    /// which would name the process `-claude`. `env` looks the program up
    /// in PATH and gives it its real name.
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

    /// The user's login shell. Ghostty sees which shell it is and sets up
    /// its shell integration (folder reports, prompt marks).
    static func shell() -> Launch {
        Launch(command: quoteIfNeeded(ShellEnvironment.shell))
    }

    /// The shell's name, e.g. "fish", used as its title.
    static var shellName: String {
        baseName(ShellEnvironment.shell)
    }
}

/// Plain words stay as they are, so Ghostty can still tell the shell from
/// the command.
private func quoteIfNeeded(_ s: String) -> String {
    let plain = !s.isEmpty && s.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "/._-+=:,@%".unicodeScalars.contains($0)
    }
    return plain ? s : shellQuote(s)
}

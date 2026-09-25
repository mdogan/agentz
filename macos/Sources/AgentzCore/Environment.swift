// The environment agents and shells run with.
//
// An app started from the Dock or Finder gets launchd's environment, which
// has a short PATH and none of the user's shell setup, so `claude` and
// `codex` would not be found. Like VS Code, agentz asks the user's login
// shell for its environment once at start and uses that for everything.

import Darwin
import Foundation

public enum ShellEnvironment {
    /// Variables no child should see. The terminal is Ghostty, which sets
    /// its own `TERM_PROGRAM`; the others would tell an agent that it runs
    /// inside another terminal or inside Claude Code.
    public static let hidden: [String] = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LC_TERMINAL", "LC_TERMINAL_VERSION",
        "ITERM_SESSION_ID", "KITTY_WINDOW_ID", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR",
        "GHOSTTY_BIN_DIR", "TMUX", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", userStatusLineVar(),
    ]

    /// Variables that describe the shell we asked, not the user's session.
    private static let skipped: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM", "COLORTERM", "PS1", "PS2",
    ]

    /// The account's login shell (what `chsh` sets), then `$SHELL`, then
    /// `/bin/zsh`, the macOS default. An app gets `$SHELL` from launchd,
    /// which may not match the account.
    public static var shell: String {
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell {
            let shell = String(cString: s)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return Paths.env("SHELL") ?? "/bin/zsh"
    }

    /// Asks the login shell for its environment and applies it to this
    /// process, so every child inherits it. Then removes `hidden`. Call it
    /// before creating any terminal.
    public static func load(timeout: TimeInterval = 5) {
        if let env = resolve(shell: shell, timeout: timeout) {
            for (key, value) in env where !skipped.contains(key) && !hidden.contains(key) {
                setenv(key, value, 1)
            }
        }
        for key in hidden { unsetenv(key) }
        setenv("SHELL", shell, 1)
    }

    /// Runs `shell -l -i -c env`. Interactive, so settings from `.zshrc`
    /// and `config.fish` count too. nil if the shell fails or takes too long.
    static func resolve(shell: String, timeout: TimeInterval) -> [String: String]? {
        let marker = "__AGENTZ_ENV_\(UUID().uuidString)__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "printf '%s' '\(marker)'; /usr/bin/env -0"]
        p.currentDirectoryURL = URL(fileURLWithPath: Paths.home)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()

        guard let start = data.range(of: Data(marker.utf8)) else { return nil }
        var env: [String: String] = [:]
        for entry in data[start.upperBound...].split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}

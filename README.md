# agentz

A terminal UI that holds your Claude Code and Codex sessions in one place.

- The left sidebar lists sessions from both agents, newest first. By default it only shows sessions of the project you started agentz in: in a git repo, that is the main checkout and all its worktrees (and their subfolders). Outside a repo, it is only that exact folder. Press `a` to see sessions from all repos.
- Clicking a session (or pressing Enter) resumes it in the right pane with the right agent.
- Every agent runs in its own PTY. When you switch to another session, the previous agent keeps running in the background.
- Selecting a session that is already running just switches to it. It is not restarted.

```
make install   # cargo install --path .
agentz
```

Each agent's screen is kept by [libghostty-vt](https://github.com/Uzaaft/libghostty-rs), Ghostty's terminal emulator as a library. Building it needs [Zig](https://ziglang.org) 0.16 on your PATH (`brew install zig`), and the first build downloads the Ghostty source.

Other targets: `make build`, `make release`, `make run`, `make check` (fmt + clippy), `make fmt`, `make test`, `make integration`, `make clean`, `make uninstall`.

## Keys

In the sidebar:

| Key | Action |
| --- | --- |
| `↑` `↓` / `j` `k` | move |
| `Enter` / click | open: switch to it if it is running, otherwise resume it |
| `n` / `N` | new Claude / Codex session in the active shell's folder if it is idle; otherwise in the project root (the top of the git repo you started agentz in, or that folder outside a repo) |
| `t` | new plain shell (no agent) in the same folder, like a terminal tab |
| `/` | filter by title or folder (`Esc` clears) |
| `a` | show sessions from all repos / only this repo |
| `i` | show / hide inactive sessions (those with no running agent or shell). Hidden at start. |
| `x` | stop the selected agent or shell |
| `q` | quit. Refused while an agent is working (wait, or stop it with `x`). Press twice if an agent is idle or a shell is running a command. Quits at once if only idle shells are open. |

Anywhere:

| Key | Action |
| --- | --- |
| `Ctrl+\` | toggle focus between the sidebar and the agent |
| `Ctrl+T` | new plain shell, same as `t`, without going back to the sidebar first |
| mouse wheel over the agent | scroll back through its output |

Double-click blank space in the sidebar session list to open a new plain shell.

Sessions with a running agent or shell always stay in the list, even when `a` or `i` would hide them, so a running agent can't get lost.

In the sidebar, a green `●` means the agent is running and waiting for you. A spinner means it is working right now.

When an agent stops working after you asked it something (it finished, or it waits at a permission prompt), agentz shows a desktop notification with the session title. If the agent sent its own notification, its text is added, e.g. Codex's last reply. You get at most one notification per question, and only when you are not looking at that agent: the terminal window is in the background, or another session is shown. The notification uses OSC 777, which Ghostty supports.

agentz knows an agent is working because the agent says so:

- Claude reports progress (OSC 9;4) while it works. It does this because agentz runs it with `TERM_PROGRAM=ghostty`, which is true: the emulator is Ghostty's.
- Codex shows a spinner in the window title while it works. agentz also tells Codex when you look away (focus reporting), and then Codex sends a notification when it is done.
- For anything else, "working" means it kept printing for at least 3 seconds after your last key press, so typing and short redraws don't count.

## Rate limits

The bottom of the sidebar shows the last reported limits for Claude and Codex, one line per agent when data is available. A session does not need to be running in agentz:

```
 ✻ 58% left · resets 2h10m · week 88%
 ◆ 75% left · resets 4h02m · week 96%
```

The first number is the 5-hour window and when it starts over. The second is the weekly window. The numbers turn yellow below 20%.

- Codex writes its limits into the rollout file after each turn. agentz reads the newest one.
- Claude gives its limits to its status line command after the first reply (with a Claude subscription). Agentz starts its own Claude sessions with `--settings` to run `agentz statusline`. To collect limits from a `claude` you start by hand, install the status line once:

  ```sh
  agentz statusline install
  ```

  This adds the command to your Claude user settings (`$CLAUDE_CONFIG_DIR/settings.json` or `~/.claude/settings.json`). Agentz saves any existing status line in `agentz-statusline.json` in that directory and runs it after recording limits. Manual launches in shell panels and other terminals then update the limits. Run `agentz statusline uninstall` to restore the earlier setting. A project status line can override the user setting; agentz-started sessions still use `--settings`. Limits are saved in `~/Library/Caches/agentz/claude-rate-limits.json` (`~/.cache/agentz` on Linux).

A shell tab follows `cd`: its folder in the sidebar, and the folder `t` opens a new shell in, is the one the shell reports (OSC 7). fish does this by default; zsh and bash on macOS don't, so their tabs keep the folder they started in.

A shell tab shows the foreground process name in its sidebar row and pane header while a command runs (for example, `sleep`). At the prompt it shows the shell name again. Background jobs do not change the title. Process names refresh with the session list every 3 seconds, so very short commands may finish before their name appears.

Starting a new Claude or Codex session, or resuming one from the list, replaces the shell shown in the right pane if that shell is idle. A new session starts in the shell's current folder, even if the shell did not report its `cd` to the sidebar. A resumed session starts in its own folder. A shell running a command stays open.

When the agent you are looking at exits, agentz opens a plain shell in its folder, so you can start `claude` or `codex` by hand. If you switch to another session before typing anything in that shell, the shell is closed and removed from the list. Typing `exit` in a shell closes it, like a terminal tab.

If you start `claude` or `codex` by hand in a shell, agentz links the shell to that session within a few seconds. The session's row shows as running, clicking it switches to the shell (no second copy is started), and the shell's own row is hidden until the agent exits. agentz finds the session from `~/.claude/sessions/<pid>.json` for Claude, and from the rollout file Codex keeps open for Codex (via `lsof` on macOS, `/proc` on Linux). A new Codex session is only linked after its first message, since Codex creates the file then.

Because agentz captures the mouse, use your terminal's selection modifier to select text (`Option`+drag in iTerm2, `Shift`+drag in most other terminals).

## Extra agent flags

```
AGENTZ_CLAUDE_ARGS="--model opus" AGENTZ_CODEX_ARGS="-c model_reasoning_effort=high" agentz
```

## Where sessions come from

- Claude Code: `~/.claude/projects/*/*.jsonl` (or `$CLAUDE_CONFIG_DIR/projects`). The title is the `/rename` name, then Claude's generated title, then the first prompt.
- Codex: `~/.codex/sessions/**/rollout-*.jsonl` (or `$CODEX_HOME`). The title comes from `session_index.jsonl`, then the first prompt. Sub-agent threads are hidden.

The list refreshes every 3 seconds. `agentz --list` prints it and exits.

## Integration tests

agentz depends on details of Claude Code and Codex that can change in any update: the `--session-id`, `--resume` and `resume` arguments, where transcripts are stored and what is in them, `~/.claude/sessions/<pid>.json`, and Codex keeping its rollout file open. After updating either agent, run:

```
make integration
```

The tests start the real `claude` and `codex` in a PTY, the same way agentz does, answer the "trust this folder?" question, and type a short prompt. They check that:

- a new session shows up in the list with the right id, folder and first prompt,
- resuming it adds to the same transcript instead of starting a new session,
- a `/rename` name becomes the Claude session's title,
- an agent started by hand in a shell is linked to that shell,
- Codex's own session list (`thread/list` from `codex app-server`) has the same Codex sessions as agentz, with the same folder, title and start time.

Each prompt goes to the model, so they use your normal login and cost a little. They are skipped by `make test`. They run in fixed folders under the temp dir and delete the sessions they create. A failed test prints the agent's screen, which usually shows what changed. `AGENTZ_CLAUDE_ARGS` and `AGENTZ_CODEX_ARGS` apply here too, e.g. `AGENTZ_CLAUDE_ARGS="--model haiku" make integration`.

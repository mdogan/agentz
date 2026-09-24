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

Other targets: `make build`, `make release`, `make run`, `make check` (fmt + clippy), `make fmt`, `make test`, `make integration`, `make clean`, `make uninstall`.

## Keys

In the sidebar:

| Key | Action |
| --- | --- |
| `↑` `↓` / `j` `k` | move |
| `Enter` / click | open: switch to it if it is running, otherwise resume it |
| `n` / `N` | new Claude / Codex session in the project root (the top of the git repo you started agentz in, or that folder outside a repo) |
| `t` | new plain shell (no agent) in the same folder, like a terminal tab |
| `/` | filter by title or folder (`Esc` clears) |
| `a` | show sessions from all repos / only this repo |
| `i` | hide / show inactive sessions (those with no running agent or shell) |
| `x` | stop the selected agent or shell |
| `q` | quit. Refused while an agent is running (stop it with `x` first). Press twice if only shells are open. |

Anywhere:

| Key | Action |
| --- | --- |
| `Ctrl+\` | toggle focus between the sidebar and the agent |
| mouse wheel over the agent | scroll back through its output |

Sessions with a running agent or shell always stay in the list, even when `a` or `i` would hide them, so a running agent can't get lost.

In the sidebar, a green `●` means the agent is running and waiting for you. A spinner means it is working right now.

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
- an agent started by hand in a shell is linked to that shell.

Each prompt goes to the model, so they use your normal login and cost a little. They are skipped by `make test`. They run in fixed folders under the temp dir and delete the sessions they create. A failed test prints the agent's screen, which usually shows what changed. `AGENTZ_CLAUDE_ARGS` and `AGENTZ_CODEX_ARGS` apply here too, e.g. `AGENTZ_CLAUDE_ARGS="--model haiku" make integration`.

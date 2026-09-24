# agentz

A terminal UI that holds your Claude Code and Codex sessions in one place.

- The left sidebar lists sessions from both agents, newest first.
- Clicking a session (or pressing Enter) resumes it in the right pane with the right agent.
- Every agent runs in its own PTY. When you switch to another session, the previous agent keeps running in the background.
- Selecting a session that is already running just switches to it. It is not restarted.

```
make install   # cargo install --path .
agentz
```

Other targets: `make build`, `make release`, `make run`, `make check` (fmt + clippy), `make fmt`, `make test`, `make clean`, `make uninstall`.

## Keys

In the sidebar:

| Key | Action |
| --- | --- |
| `↑` `↓` / `j` `k` | move |
| `Enter` / click | open: switch to it if it is running, otherwise resume it |
| `n` / `N` | new Claude / Codex session in the folder you started agentz from |
| `/` | filter by title or folder (`Esc` clears) |
| `x` | stop the selected agent |
| `q` | quit (press twice if agents are running; this stops them) |

Anywhere:

| Key | Action |
| --- | --- |
| `Ctrl+\` | toggle focus between the sidebar and the agent |
| mouse wheel over the agent | scroll back through its output |

In the sidebar, a green `●` means the agent is running and waiting for you. A spinner means it is working right now.

When an agent exits, its last screen stays visible. Press `Enter` to resume it again.

Because agentz captures the mouse, use your terminal's selection modifier to select text (`Option`+drag in iTerm2, `Shift`+drag in most other terminals).

## Extra agent flags

```
AGENTZ_CLAUDE_ARGS="--model opus" AGENTZ_CODEX_ARGS="-c model_reasoning_effort=high" agentz
```

## Where sessions come from

- Claude Code: `~/.claude/projects/*/*.jsonl` (or `$CLAUDE_CONFIG_DIR/projects`). The title is the `/rename` name, then Claude's generated title, then the first prompt.
- Codex: `~/.codex/sessions/**/rollout-*.jsonl` (or `$CODEX_HOME`). The title comes from `session_index.jsonl`, then the first prompt. Sub-agent threads are hidden.

The list refreshes every 3 seconds. `agentz --list` prints it and exits.

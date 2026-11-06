# agentz

A native macOS app that holds your Claude Code and Codex sessions in one place: a list of sessions, and the selected one running next to it in a [Ghostty](https://ghostty.org) terminal. Resume any session with one click, keep several agents running, and get a notification when one is done.

See [macos/README.md](macos/README.md) for how to use it. The Rust core it uses is in `core/`.

## Screenshots

**Sessions and status.** Keep Claude Code and Codex sessions together, see which agents are working or need you, and track context usage and rate limits. The Changes panel shows changed files beside the terminal.

![Session list, Codex terminal, and Changes panel](docs/screenshots/sessions.png)

**Split panes.** Work with two sessions side by side, including agents in separate git worktrees.

![Claude Code and Codex sessions in split panes](docs/screenshots/split-panes.png)

**Git changes.** Open a repository's Git tab to review diffs, stage files, hunks, or lines, and commit changes.

![Git tab with staged and unstaged files and a file diff](docs/screenshots/git-changes.png)

**Git history.** Browse the commit graph, branches, and worktrees, and inspect a commit's changes.

![Git tab with branches, worktrees, commit history, and a commit diff](docs/screenshots/git-history.png)

## Build

```sh
make            # build the app: macos/.build/Agentz.app
make install    # copy it to ~/Applications/Agentz.app
make test       # unit tests of everything
make check      # formatting and lints
make smoke      # open the app with real terminals and check it
```

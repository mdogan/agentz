# agentz for macOS

A native macOS app that holds your Claude Code and Codex sessions in one place: the list on the left, the selected session on the right, each in a real [Ghostty](https://ghostty.org) terminal.

## Build and install

Needs Xcode (Swift 6), Rust and macOS 14 or later. The first build downloads a prebuilt Ghostty library.

```sh
cd macos
make run        # build a debug app and open it for this repo
make app        # release build: .build/Agentz.app
make install    # copy to ~/Applications/Agentz.app
make link       # link `agentz` into /usr/local/bin (may need sudo)
make test       # unit tests
make smoke      # opens the app with real terminals and checks it (~40 s)
```

`make install` in the repo root does the same install. After `make link`, `agentz` in a terminal opens the app for the current folder, like `code .`. `agentz ~/some/repo` opens that folder: ⌘N, ⇧⌘N and ⌘T start sessions there. **File › Open Folder…** (⌘O) does the same from the app.

To put the link somewhere else, use `make link PREFIX=...`.

## Using it

The list shows sessions from all repos. At start it shows only sessions with a running agent or shell. The filter button at the top right limits the list to one recent repo (its main checkout and all its worktrees; outside a repo, only that folder), and shows or hides inactive sessions.

**Claude**, **Codex** and **Shell** at the top of the list start a new session. Each opens a menu of recent folders, the one you used last first, and **Open Folder…**. A git repo in it has a submenu of its worktrees: the session starts in the one you pick. **New Worktree…** checks out an existing branch, or makes a new branch from a worktree, in `<repo>.worktrees/<branch>` next to the repo. It copies git-ignored files like `.env` and `node_modules` into the new worktree as APFS clones (instant, no extra disk space until a file changes), and, if you ask, the uncommitted changes too, then starts the session in it.

- **Click** a running session to show it. **Double-click** or press **Return** on any session to open it: it switches to it if it runs, otherwise it resumes it.
- A spinner means the agent is working. A green dot means it waits for you. A bell means it finished while you were away. The Dock icon shows how many are waiting.
- Right-click a session to close it, show its folder, or copy its id.

| Shortcut | Action |
| --- | --- |
| ⌘N / ⇧⌘N | new Claude / Codex session, in place of the shown shell if it is idle |
| ⌘T | new shell |
| ⌘W | close the shown session (asks first if it is working) |
| ⌘] / ⌘[ | next / previous running session |
| ⌘L / ⌘J | go to the session list / the terminal |
| ⌘F | filter sessions |
| ⇧⌘I | show inactive sessions too |
| ⌃⌘S | hide or show the session list |
| ⌘+ / ⌘- / ⌘0 | font size |
| ⌘K | clear the screen |
| ⌘/ | list all shortcuts (**Help › Keyboard Shortcuts**) |

When an agent finishes or waits for your permission while you are not looking at it, you get a notification. Click it to go to that session. If notifications are off, the session list shows a button to turn them on.

**Quit** (⌘Q) asks first if an agent or a command is still running. The open tabs come back on the next launch.

Rate limits for Claude and Codex show at the bottom of the list. To also get Claude's limits from a `claude` you start by hand, use **Agentz › Install Claude Status Line**.

## Settings

- The app uses your login shell's environment, so `PATH` and variables from your shell config work. `AGENTZ_CLAUDE_ARGS` and `AGENTZ_CODEX_ARGS` add flags to the agents, e.g. `AGENTZ_CLAUDE_ARGS="--model opus"`.
- Terminals use your Ghostty config (`~/.config/ghostty/config`), including themes from Ghostty.app or `~/.config/ghostty/themes`. The session list takes its colors from the same theme. `AGENTZ_GHOSTTY_CONFIG` points to another file (empty for none).
- Terminals have Ghostty's macOS keybindings for editing, selecting and scrolling (⌘←, ⌥←, ⌘⌫, ⌘↑, ⇧→, …). Those for windows, tabs, splits and search are off, so ⌘N, ⌘T and ⌘W reach the menu. Your own keybinds still work.
- Dropping files on a terminal types their paths, as in Ghostty.

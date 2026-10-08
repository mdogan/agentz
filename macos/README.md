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

The list shows sessions from all repos. At start it shows today's sessions. The filter button at the top right limits the list to one recent repo (its main checkout and all its worktrees; outside a repo, only that folder), and picks which sessions to show: only active ones, today's, the last 7 or 30 days', or all. Sessions with a running agent or shell always show.

**Claude**, **Codex** and **Shell** at the top of the list start a new session. Each opens a menu of recent folders, the one you used last first, and **Open Folder…**. A git repo in it has a submenu of its worktrees: the session starts in the one you pick. **New Worktree…** checks out an existing branch, or makes a new branch from a worktree, in `<repo>.worktrees/<branch>` next to the repo. It copies git-ignored files like `.env` and `node_modules` into the new worktree as APFS clones (instant, no extra disk space until a file changes), and, if you ask, the uncommitted changes too, then starts the session in it.

**Clean Up Worktrees…** in the same submenu lists the repo's other worktrees and says which can go without losing anything: nothing uncommitted, its commits in the main checkout's branch (or its upstream, also when they were squashed into one commit there), and no program working in it. Only those can be picked, and they are picked already. Removing one deletes its folder, with ignored files like `node_modules`; its branch stays. A worktree whose folder is gone is only forgotten. The others say why they stay, e.g. "2 commits not in main" or "claude runs in it".

- **Click** a running session to show it. **Double-click** or press **Return** on any session to open it: it switches to it if it runs, otherwise it resumes it.
- A spinner means the agent is working. A green dot means it waits for you.
- While an agent works, its second line says what it does and how long it has been at it since your last prompt, e.g. "Run the tests · 3m" with a terminal icon: the command it runs (or what Claude says the command does), the file it reads or edits, what it searches for, or the tool it uses. Hover over it for more. It comes from the agent's transcript, so Claude sessions working outside agentz show it too.
- A session that finished, asks for something or quit while you were away gets a colored row with a badge, and its second line says what the agent said, e.g. "Claude needs your permission to use Bash". The count at the top of the list and the pill in the title bar ("2 need you") say how many there are. Click either one, or press ⇧⌘A, to go to the next one. The Dock icon shows the same number. All of these count sessions the list's filters hide, too. Once you look at it, it no longer needs you.
- You count as away when agentz is not in front, and also when nobody used the keyboard or mouse for 5 minutes, though agentz is in front. So a session on screen that finishes while you are at lunch still gets marked, and notifies you.
- Right-click a session that needs you and pick **Remind Me Later** to put it off for 15 minutes, 1 or 3 hours, or until 9:00. Until then it looks like any other row, with a moon, and does not count. Then it needs you again and you get a notification. **Remind Me Now** ends that early, and so does looking at it. Reminders do not outlast quitting agentz.
- Each row shows the branch the session last worked on, unless its worktree is named after it. Once Claude opened or linked a pull request, the row shows its number: click it to open the pull request in your browser.
- Claude sessions running outside agentz (in another terminal, your editor or another agentz window) show in the list whatever its filter, with a gray spinner while they work and a window icon otherwise. Opening one here offers to fork it: a new session starts with a copy of the conversation, and the one outside goes on as it is. Two Claude processes never write to the same conversation that way. To continue the session itself here, quit it there first. For the same reason, a saved tab whose session now runs elsewhere is not resumed at launch; the next launch tries again.
- When an agent stops at its plan's rate limit, its row says when the limit resets, e.g. "Rate limit · resets in 1h20m", from what the agent said (or, if it said no time, from the rate limits at the bottom of the list). Click **Continue then** on that line, or right-click and pick **Continue When the Rate Limit Resets**, and agentz types `continue` into the session a minute after that time. It does so once per stop, only while the agent runs here and is not working, and not in its first seconds after a resume. If the limit stops it again, it continues after the next reset too. This choice is kept across launches, until the session goes on or you close it.
- Programs that were started in the background and outlived what started them, like a dev server an agent ran with `nohup … &`, show on the row of the session that ran in their folder when they started, with the memory they use, e.g. "1.2 GB". The bottom of the list adds them up ("2 programs left running · 1.4 GB"); click it to stop one or all. Right-click a session to stop the ones from its folder. agentz asks first, then asks them to quit and stops them if they still run 3 seconds later, with what they started. It never stops anything by itself. Programs in an app or in your home folder, and Codex's background server (`codex app-server`), are not counted.
- Right-click a session to open it in a split, close it, pin it, show its folder, or copy its id.
- A pinned session stays at the top of the list and can't be closed until you unpin it (right-click, or **File › Unpin Session**). A line separates pinned and active sessions from other sessions when both are shown. If its agent or shell ends, its row stays; open it to start it again. Pinned sessions come back on every launch, even after a crash.

To see two sessions at once, split the pane: ⌘D puts a second pane to the right, ⇧⌘D puts it below. The two buttons at the right end of the title bar do the same. The new pane opens a shell in the same folder as the shown session; press ⌘N or ⇧⌘N there to start an agent in its place. To put a session from the list there instead, right-click it and pick **Open in Split Right** or **Open in Split Down**: it moves there if it runs, and is resumed there if not. If it was in another split, that split ends.

You can also drag a session from the list onto the terminal. With one pane, it goes to the edge you drop it near (left, right, top or bottom) and the pane splits that way. In a split, it goes into the pane you drop it on. A highlight shows where it will land.

- A split works like a tab with two panes: what its panes show changes only when you put a session there yourself. Picking another session in the list, going to it with ⌘] or ⌘[, or starting one with ⌘T shows it on its own. The split waits, as it was, until you pick one of its sessions again. You can keep several splits this way.
- One pane is the focused one; the other is faded. Click a pane, or press ⌥⌘J, to work in it. ⌘N there starts an agent in place of an idle shell, and ⌘W closes its session. An empty pane shows the session you pick in the list.
- A session already in a split is not opened twice: picking it shows its split and moves you to its pane.
- In the list, the two sessions of a split sit next to each other in a box, and an icon shows which half each one is in. The box of the split on screen is colored. The focused pane's session has a colored bar, and the other pane's session a gray one.
- Drag the line between the panes to resize them. Double-click it to make them even again. Each split keeps its own size.
- ⌘D or ⇧⌘D turns the split the other way, and the same key again unsplits it. The title bar button for the current split is filled in; click it to unsplit. **View › Unsplit** does the same. The session that goes off screen keeps running in the list. A shell the split opened and you never typed in is closed.
- Closing the session in a pane (⌘W), or exiting its shell, also ends the split, and the other pane takes the space. A hidden split ends the same way, and also when one of its agents quits.
- The splits come back on the next launch with the open tabs, hidden ones too.

**View › Auto-Hide Session List** gives the terminal the whole window. Rest the mouse at the window's left edge and the list slides in over the terminal; it slides away once the mouse leaves it. While you type in its filter, it stays. ⌘L, ⌘F and ⌃⌘S show it too, and then it stays until you go back to the terminal (⎋, ⌘J, or opening a session). A click outside it always hides it. The terminal keeps its size while the list comes and goes. Turn the setting off to put the list back next to the terminal.

| Shortcut | Action |
| --- | --- |
| ⌘N / ⇧⌘N | new Claude / Codex session, in place of the shown shell if it is idle |
| ⌘T | new shell |
| ⌘W | close the shown session (asks first if it is working) |
| ⌘] / ⌘[ | next / previous running session |
| ⇧⌘A | next session that needs you |
| ⌘L / ⌘J | go to the session list / the terminal |
| ⌘D / ⇧⌘D | split the pane right / down; again to unsplit |
| ⌥⌘J | go to the other pane of a split |
| ⌘F | filter sessions |
| ⇧⌘I | show all sessions, or only today's again |
| ⌃⌘S | hide or show the session list |
| ⌘+ / ⌘- / ⌘0 | font size |
| ⌘K | clear the screen |
| ⌘/ | list all shortcuts (**Help › Keyboard Shortcuts**) |

When an agent finishes or waits for your permission while you are not looking at it, you get a notification. Click it to go to that session. Several at the same moment become one notification ("3 sessions need you"), and a click on it goes to the next one. A notification goes away once you looked at its sessions. If notifications are off, the session list shows a button to turn them on.

An agent only quits when you tell it to, in its own tab. If one quits while you are looking elsewhere (it crashed, or something killed it), you get a notification and its row shows a red warning sign until you resume or close it.

A shell can tell you when a long command ends, as Ghostty does: set `notify-on-command-finish` (`unfocused` or `always`) in your Ghostty config. `notify-on-command-finish-after` sets how long a command must run (5s by default). `notify-on-command-finish-action` picks `bell` (bounce the Dock icon and mark the row), `notify` (a notification), or both. Like in Ghostty, `bell` is on unless you write `no-bell`. The shell has to mark its commands: fish 4 does this by itself, and Ghostty's shell integration does it for zsh and bash.

**Quit** (⌘Q) asks first if an agent or a command is still running. The open tabs come back on the next launch.

Rate limits for Claude and Codex show at the bottom of the list. To also get Claude's limits from a `claude` you start by hand, use **Agentz › Install Claude Status Line**.

## Settings

- The app uses your login shell's environment, so `PATH` and variables from your shell config work. `AGENTZ_CLAUDE_ARGS` and `AGENTZ_CODEX_ARGS` add flags to the agents, e.g. `AGENTZ_CLAUDE_ARGS="--model opus"`.
- Terminals use your Ghostty config (`~/.config/ghostty/config`), including themes from Ghostty.app or `~/.config/ghostty/themes`. The session list takes its colors from the same theme. View > Theme picks any other Ghostty theme instead, and keeps it until you pick Follow Ghostty. Without Ghostty.app, the themes that come with the Ghostty library are used instead. `AGENTZ_GHOSTTY_CONFIG` points to another file (empty for none). Split panes follow Ghostty's `unfocused-split-opacity`, `unfocused-split-fill` and `split-divider-color`.
- Terminals have Ghostty's macOS keybindings for editing, selecting and scrolling (⌘←, ⌥←, ⌘⌫, ⌘↑, ⇧→, …). Those for windows, tabs, splits and search are off, so ⌘N, ⌘T and ⌘W reach the menu. Your own keybinds still work.
- Dropping files on a terminal types their paths, as in Ghostty.

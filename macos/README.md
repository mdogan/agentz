# agentz for macOS

A native macOS app that holds your Claude Code and Codex sessions in one place: the list on the left, the selected session on the right, each in a real [Ghostty](https://ghostty.org) terminal.

## Build and install

Needs Xcode (Swift 6.2 or later), Rust and macOS 14 or later. The first build downloads a prebuilt Ghostty library.

```sh
cd macos
make run        # build a debug app and open it for this repo
make app        # release build: .build/Agentz.app
make install    # copy to ~/Applications/Agentz.app
make link       # link `agentz` into /usr/local/bin (may need sudo)
make test       # unit tests
make smoke      # opens the app with real terminals and checks it (~40 s)
```

`make install` in the repo root does the same install. After `make link`, `agentz` in a terminal opens the app for the current folder, like `code .`. `agentz ~/some/repo` opens that folder: it goes to the top of the recent folders, and ⌘N, ⇧⌘N and ⌘T pick it while no session is shown. **File › Open Folder…** (⌘O) does the same from the app.

To put the link somewhere else, use `make link PREFIX=...`.

## Using it

The list shows sessions from all repos. At start it shows today's sessions. The filter button at the top right limits the list to one recent repo (its main checkout and all its worktrees; outside a repo, only that folder), and picks which sessions to show: only active ones, today's, the last 7 or 30 days', or all. Sessions with a running agent or shell always show.

**Claude**, **Codex** and **Shell** at the top of the list start a new session. Each opens a menu of recent folders, the one you used last first, **Open Folder…**, and **Create Folder…**, which makes a new folder and starts the session in it. A git repo in it has a submenu of its worktrees: the session starts in the one you pick. **New Worktree…** checks out an existing branch, or makes a new branch from a worktree, in `<repo>.worktrees/<branch>` next to the repo. It copies git-ignored files like `.env` and `node_modules` into the new worktree as APFS clones (instant, no extra disk space until a file changes), and, if you ask, the uncommitted changes too, then starts the session in it. **Git**, next to them, opens a repo's git tab (see below) the same way: its menu has the recent repos with their worktrees, and **Open Folder…**.

**Clean Up Worktrees…** in the same submenu lists the repo's other worktrees and says which can go without losing anything: nothing uncommitted, its commits in the main checkout's branch (or its upstream, also when they were squashed into one commit there), and no program working in it. Only those can be picked, and they are picked already. Removing one deletes its folder, with ignored files like `node_modules`; its branch stays. A worktree whose folder is gone is only forgotten. The others say why they stay, e.g. "2 commits not in main" or "claude runs in it".

⌘N, ⇧⌘N and ⌘T ask where to start in a sheet: one list of the recent folders, each repo with its worktrees under it and **New Worktree…**, then **Open Folder…** and **Create Folder…**. The shown session's folder is picked already, so ⌘N and ↩ start Claude in the same folder. A folder that is not in the list, like a subfolder a shell went to, gets a row of its own on top. Type to narrow the list by folder, repo, branch or path (`api fix` finds the worktrees of `api` on a `fix/…` branch), ↑ ↓ to pick, ↩ to start, ⎋ to cancel. An agent started this way takes the place of the shown shell if it is idle.

- **Click** a running session to show it. **Double-click** or press **Return** on any session to open it: it switches to it if it runs, otherwise it resumes it.
- A spinner means the agent is working. A green dot means it waits for you.
- While any agent is working, agentz keeps the Mac awake, including for sessions off screen or Claude sessions running in another app. Once all agents are idle or have quit, normal sleep resumes. The display can still sleep.
- While an agent works, its second line says what it does and how long it has been at it since your last prompt, e.g. "Run the tests · 3m" with a terminal icon: the command it runs (or what Claude says the command does), the file it reads or edits, what it searches for, or the tool it uses. Hover over it for more. It comes from the agent's transcript, so Claude sessions working outside agentz show it too.
- The second line also shows how full the agent's context window is, e.g. "54%" with a ring: the tokens the model read for its last answer, out of what fits. It turns yellow at 80% and red at 90%. Hover over it for the tokens, e.g. "538k of 1M tokens". After a compaction it shows what was kept. Claude tells the window's size only to its status line, so a Claude session that did not run agentz's status line shows only the tokens, e.g. "538k".
- A session that finished, asks for something or quit while you were away gets a colored row with a badge, and its second line says what the agent said, e.g. "Claude needs your permission to use Bash". The count at the top of the list and the pill in the title bar ("2 need you") say how many there are. Click either one, or press ⇧⌘A, to go to the next one. The Dock icon shows the same number. All of these count sessions the list's filters hide, too. Once you look at it, it no longer needs you.
- You count as away when agentz is not in front, and also when nobody used the keyboard or mouse for 5 minutes, though agentz is in front. So a session on screen that finishes while you are at lunch still gets marked, and notifies you.
- Right-click a session that needs you and pick **Remind Me Later** to put it off for 15 minutes, 1 or 3 hours, or until 9:00. Until then it looks like any other row, with a moon, and does not count. Then it needs you again and you get a notification. **Remind Me Now** ends that early, and so does looking at it. Reminders do not outlast quitting agentz.
- Each row shows the branch the session last worked on, unless its worktree is named after it. Once Claude opened or linked a pull request, the row shows its number: click it to open the pull request in your browser.
- Claude sessions running outside agentz (in another terminal, your editor or another agentz window) show in the list whatever its filter, with a gray spinner while they work and a window icon otherwise. Opening one here offers to fork it: a new session starts with a copy of the conversation, and the one outside goes on as it is. Two Claude processes never write to the same conversation that way. To continue the session itself here, quit it there first. For the same reason, a saved tab whose session now runs elsewhere is not resumed at launch; the next launch tries again.
- When an agent stops at its plan's rate limit, its row says when the limit resets, e.g. "Rate limit · resets in 1h20m", from what the agent said (or, if it said no time, from the rate limits at the bottom of the list). Click **Continue then** on that line, or right-click and pick **Continue When the Rate Limit Resets**, and agentz types `continue` into the session a minute after that time. It does so once per stop, only while the agent runs here and is not working, and not in its first seconds after a resume. If the limit stops it again, it continues after the next reset too. This choice is kept across launches, until the session goes on or you close it.
- Programs that were started in the background and outlived what started them, like a dev server an agent ran with `nohup … &`, show on the row of the session that ran in their folder when they started, with the memory they use, e.g. "1.2 GB". The bottom of the list adds them up ("2 programs left running · 1.4 GB"); click it to stop one or all. Right-click a session to stop the ones from its folder. agentz asks first, then asks them to quit and stops them if they still run 3 seconds later, with what they started. It never stops anything by itself. Programs in an app or in your home folder, and Codex's background server (`codex app-server`), are not counted.
- Right-click a session to open it in a split, close it, pin it, show its folder, or copy its id.
- A pinned session stays at the top of the list and can't be closed until you unpin it (right-click, or **File › Unpin Session**). A line separates pinned and active sessions from other sessions when both are shown. If its agent or shell ends, its row stays; open it to start it again. Pinned sessions come back on every launch, even after a crash.

To see two sessions at once, split the pane: ⌘D puts a second pane to the right, ⇧⌘D puts it below. The two buttons at the right end of the title bar do the same. The new pane opens a shell in the same folder as the shown session; press ⌘N or ⇧⌘N and ↩ there to start an agent in its place. To put a session from the list there instead, right-click it and pick **Open in Split Right** or **Open in Split Down**: it moves there if it runs, and is resumed there if not. If it was in another split, that split ends.

You can also drag a session from the list onto the terminal. With one pane, it goes to the edge you drop it near (left, right, top or bottom) and the pane splits that way. In a split, it goes into the pane you drop it on. A highlight shows where it will land.

- A split works like a tab with two panes: what its panes show changes only when you put a session there yourself. Picking another session in the list, going to it with ⌘] or ⌘[, or starting one with ⌘T shows it on its own. The split waits, as it was, until you pick one of its sessions again. You can keep several splits this way.
- One pane is the focused one; the other is faded. Click a pane, or press ⌥⌘J, to work in it. ⌘N there starts an agent in place of an idle shell, and ⌘W closes its session. An empty pane shows the session you pick in the list.
- A session already in a split is not opened twice: picking it shows its split and moves you to its pane.
- In the list, the two sessions of a split sit next to each other in a box, and an icon shows which half each one is in. The box of the split on screen is colored. The focused pane's session has a colored bar, and the other pane's session a gray one.
- Drag the line between the panes to resize them. Double-click it to make them even again. Each split keeps its own size.
- ⌘D or ⇧⌘D turns the split the other way, and the same key again unsplits it. The title bar button for the current split is filled in; click it to unsplit. **View › Unsplit** does the same. The session that goes off screen keeps running in the list. A shell the split opened and you never typed in is closed.
- Closing the session in a pane (⌘W), or exiting its shell, also ends the split, and the other pane takes the space. A hidden split ends the same way, and also when one of its agents quits.
- The splits come back on the next launch with the open tabs, hidden ones too.

**View › Auto-Hide Session List** gives the terminal the whole window. Rest the mouse at the window's left edge and the list slides in over the terminal; it slides away once the mouse leaves it. While you type in its filter, it stays. ⌘L, ⇧⌘F and ⌃⌘S show it too, and then it stays until you go back to the terminal (⎋, ⌘J, or opening a session). A click outside it always hides it. The terminal keeps its size while the list comes and goes. Turn the setting off to put the list back next to the terminal.

**View › Changes Panel** (⇧⌘C), or the ± button at the right end of the title bar, shows the Changes panel on the right: the staged and unstaged changes in the repository of the shown session, or with no session shown, of the one picked in the list. It follows the sessions; there is no other way to pick a repository.

- At its top: the branch (click it to switch to another; see below), the repository, a button that opens its git tab (see below), and refresh.
- The staged and unstaged files, as a folder tree. A folder that only wraps all the others is left out: with changes only below `crates/a` and `crates/b`, the tree starts at `a` and `b`. Hover over a file or folder for its buttons: + or − stages or unstages it, or every file below the folder. ↩ and ⌫ do the same for the selected files, and **Stage All** and **Unstage All** for all of them; right-click to discard. A file in a merge conflict can be resolved with ours or theirs, or marked resolved.
- To see a file's diff, click the button next to its + or −, or double-click the file: the repository's git tab opens with that diff, where you can also stage single hunks or lines. Space opens the diff side by side in a window of its own.
- **Commit** (⌘↩) commits the staged files, also as an amend or signed.
- It reads the repository again by itself when files in it or in its git folder change, at most once a second, and only while the panel is shown and the window can be seen. Its own reads write nothing in `.git`.

**Git › Open Git** (⌥⌘G) opens a git tab for the shown session's repository: GitFork's git client, moved into agentz, in a pane like a terminal. Hover over a session and click its Git icon, right-click it and pick **Open Git Here**, or use **Git** at the top of the list. A git tab is a session like the others: it has a row in the list, named after its branch, with how far it is from its upstream and what is uncommitted, e.g. `↑2 ↓1 · 3 changes · 1 conflict` (as of when the tab last read the repository), comes back on the next launch, and closes with ⌘W. Unlike the others, it always shows on its own, never in a split: ⌘D and ⇧⌘D do nothing while it shows, and opening it from a split hides the split, which waits as it is. There is one per worktree; opening it again shows the one there is. While a git tab is on screen, the Changes panel stays hidden, since the git tab has the changes itself; it comes back after.

- At its top: where HEAD is (click it to switch to another branch); the tabs **Changes** and **History**, which pick what the left side shows; fetch, pull, push, new branch and refresh; open the repository in Zed or Finder; and the repository.
- **Changes**: the changes, as in the Changes panel, with stashing. **History**: the commits, with their graph and a search, and next to them a column with the local and remote branches, tags, stashes and worktrees, and the unreachable commits. The button next to the search hides or shows that column, and it stays hidden in a window too narrow for it; drag the line at its edge to change its width. While it is hidden, a menu next to the search picks the branch. Click a branch, tag or stash in the column to narrow the commits to it; **All Branches** on top shows all commits again. To switch to a branch, right-click it, or use **Git › Switch Branch…**. The **+** next to **Branches** makes a new branch from the picked one, or from HEAD if none is picked. Right-click one for what it can do: switch to a branch, make a new branch from it, rename, delete (also on the remote), push, or move it into a folder; apply or drop a stash; delete or prune a worktree, or start a session or a git tab in it.
- On the right: the picked commit's files and diffs, or the picked file's diff, to stage, unstage or discard a hunk, or select lines and stage, unstage or discard just those. A file in a merge conflict shows its conflicts, to resolve by hand.
- It reads the repository again when files change, like the Changes panel, while it is in a pane on screen. It has its own view of the repository: what it shows does not change the Changes panel.

**Git › Switch Branch…** (⌘B), or a click on the branch at the top of the Changes panel or the git tab, picks a branch to switch to: type to narrow the list, ↑ ↓ to pick, ↩ or a double-click to switch. In a git tab, ⌘↩ shows the picked branch's commits instead. Switching to a remote branch switches to the local branch of that name, and makes it first if there is none. **New Branch…** makes a new branch from the picked one.

A new branch asks for a name, and whether to check it out. Unchecked, you stay where you are. Checked, it is a switch like any other, and asks first in the same cases. A new branch made from a remote branch does not track it: its first push gives it an upstream of its own.

Uncommitted changes come along to the other branch, as with `git switch`, as long as that branch does not change the same files. If it does, agentz asks first: **Stash and Switch** puts all your changes in a stash, untracked files too, and switches. The stash stays until you apply or drop it, under Stashes in the git tab's History.

While an agent works in that worktree, here or in another app, agentz asks before it switches: the agent's files would change under it, and it would not be told. An agent that waits for you does not count, and neither do other worktrees of the repo.

The **Git** menu works on the git tab in the focused pane, or else on the Changes panel's repository, with GitFork's keys where agentz has no other use for them. **Git › Git Command Log** (⇧⌘L), or the terminal button in the git tab's bar, lists every git command they ran and how each went.

**View › Quick Terminal**, or its global key (see below), slides a shell of its own in from the edge of the screen (the top, unless set otherwise), over any app, like Ghostty's quick terminal. Do it again and it slides away, and the app you were in gets the keyboard back. Its shell keeps running while it is hidden. It also slides away when you click another window. When its shell exits, or you press ⌘W in it, it closes; the next one starts a new shell in your home folder.

- It is not a session: the list does not show it, and it does not come back after quitting. While it has the keyboard, the menu items for sessions and the list are off.
- A Claude you start in it shows in the list as running in the quick terminal, like one in another app. Opening it in agentz offers to fork it.
- It follows Ghostty's `quick-terminal-position`, `quick-terminal-size`, `quick-terminal-screen`, `quick-terminal-animation-duration`, `quick-terminal-autohide` and `quick-terminal-space-behavior`.
- A global key for `toggle_quick_terminal` in your Ghostty config, e.g. `keybind = global:ctrl+grave_accent=toggle_quick_terminal`, shows and hides it from any app. The menu item shows it. Ghostty needs the Accessibility permission for global keys; agentz does not. agentz and Ghostty.app read the same config, so with both running, both want the key. To give agentz a key of its own, point `AGENTZ_GHOSTTY_CONFIG` at another file.

| Shortcut | Action |
| --- | --- |
| ⌘N / ⇧⌘N | new Claude / Codex session: asks where, and takes the place of the shown shell if it is idle |
| ⌘T | new shell: asks where |
| ⌘W | close the shown session (asks first if it is working) |
| ⌘] / ⌘[ | next / previous running session |
| ⇧⌘A | next session that needs you |
| ⌘L / ⌘J | go to the session list / the terminal |
| ⌘D / ⇧⌘D | split the pane right / down; again to unsplit |
| ⌥⌘J | go to the other pane of a split |
| ⌘F | find in the terminal |
| ⌘G / ⇧⌘G | next / previous match |
| ⇧⌘F | filter sessions |
| ⇧⌘I | show all sessions, or only today's again |
| ⌃⌘S | hide or show the session list |
| ⇧⌘C | show or hide the Changes panel |
| ⌥⌘G | open the git tab of the shown session's repository |
| ⌘P / ⌘B | the changes / switch to another branch |
| ⌘R / ⇧⌘L | read the repository again / the git command log |
| ⌘+ / ⌘- / ⌘0 | font size |
| ⌘K | clear the screen |
| ⌘/ | list all shortcuts (**Help › Keyboard Shortcuts**) |

**Edit › Find…** (⌘F) finds text in the terminal you work in, as in Ghostty: a bar at its top right takes the text, and Ghostty highlights every match on the screen and in the scrollback. ↩ or ⌘G goes up to the next match, starting at the newest, and scrolls there; ⇧↩ or ⇧⌘G goes back down. Short text waits a moment before it is searched for. ⎋ closes the bar and ends the search; ⌘F brings it back with the same text. Each terminal has its own bar, the quick terminal too. Only what is in the terminal's buffer can be found: a program that draws a screen of its own, like an editor, keeps the rest of its text to itself.

When an agent finishes or waits for your permission while you are not looking at it, you get a notification. Click it to go to that session. Several at the same moment become one notification ("3 sessions need you"), and a click on it goes to the next one. A notification goes away once you looked at its sessions. If notifications are off, the session list shows a button to turn them on.

An agent only quits when you tell it to, in its own tab. If one quits while you are looking elsewhere (it crashed, or something killed it), you get a notification and its row shows a red warning sign until you resume or close it.

A shell can tell you when a long command ends, as Ghostty does: set `notify-on-command-finish` (`unfocused` or `always`) in your Ghostty config. `notify-on-command-finish-after` sets how long a command must run (5s by default). `notify-on-command-finish-action` picks `bell` (bounce the Dock icon and mark the row), `notify` (a notification), or both. Like in Ghostty, `bell` is on unless you write `no-bell`. The shell has to mark its commands: fish 4 does this by itself, and Ghostty's shell integration does it for zsh and bash.

**Quit** (⌘Q) asks first if an agent or a command is still running. The open tabs come back on the next launch.

Rate limits for Claude and Codex show at the bottom of the list. To also get Claude's limits, and the size of its context window, from a `claude` you start by hand, use **Agentz › Install Claude Status Line**.

## Settings

- The app uses your login shell's environment, so `PATH` and variables from your shell config work. `AGENTZ_CLAUDE_ARGS` and `AGENTZ_CODEX_ARGS` add flags to the agents, e.g. `AGENTZ_CLAUDE_ARGS="--model opus"`.
- Terminals use your Ghostty config (`~/.config/ghostty/config`), including themes from Ghostty.app or `~/.config/ghostty/themes`. The session list takes its colors from the same theme. View > Theme picks another Ghostty theme instead, and keeps it until you pick Follow Ghostty. A theme shows across the app while it is highlighted in the menu, so you can try it before picking it. The menu leaves out themes that look the same as another one in agentz; your own themes always show, and a left-out theme still works when your config names it. Without Ghostty.app, the themes that come with the Ghostty library are used instead. `AGENTZ_GHOSTTY_CONFIG` points to another file (empty for none). Split panes follow Ghostty's `unfocused-split-opacity`, `unfocused-split-fill` and `split-divider-color`.
- Terminals have Ghostty's macOS keybindings for editing, selecting and scrolling (⌘←, ⌥←, ⌘⌫, ⌘↑, ⇧→, …). Those for windows, tabs, splits and search are off, so ⌘N, ⌘T, ⌘W and ⌘F reach the menu. Your own keybinds still work.
- Dropping files on a terminal types their paths, as in Ghostty.

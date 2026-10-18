@testable import AgentzCore
import Foundation
import XCTest

// The core's logic is tested in Rust (core/). These check the
// Swift helpers and that calls through the generated bindings work.

final class BridgeTests: XCTestCase {
    func testTurnTrackerThroughRust() {
        let t = TurnTracker()
        t.userInput()
        t.receive(.progress(true))
        let busy = t.update(true)
        XCTAssertNil(busy.notice)
        XCTAssertTrue(busy.busy)
        XCTAssertTrue(t.isBusy())
        t.receive(.notify(title: "Codex", body: "Done: OK"))
        t.receive(.pwd("file://h/done%20x"))
        let update = t.update(true)
        XCTAssertEqual(update.notice, Notice(message: "Done: OK"))
        XCTAssertEqual(update.cwd, "/done x")
    }

    func testProjectRootOutsideARepoIsTheFolder() throws {
        let dir = NSTemporaryDirectory() + "agentz-project-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertEqual(projectRoot(dir), dir)
    }

    func testValuesCrossTheBridge() {
        XCTAssertEqual(Window(used: 42, resetsAt: 100).left(0), 58)
        XCTAssertEqual(Window(used: 42, resetsAt: 100).left(100), 100)
        XCTAssertEqual(shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(workingDirectory(getpid()), realPath(FileManager.default.currentDirectoryPath))
        XCTAssertEqual(SessionKey(.codex, "x").description, "codex:x")
        XCTAssertEqual(SessionKey(parsing: "claude:a:b"), SessionKey(.claude, "a:b"))
        XCTAssertNil(SessionKey(parsing: "vim:x"))
        XCTAssertNil(SessionKey(parsing: "shell:"))
        XCTAssertNil(SessionKey(parsing: "shell"))
        XCTAssertEqual(Agent(name: "shell"), .shell)
        XCTAssertNil(Agent(name: "vim"))
        XCTAssertEqual(Limits(), Limits(claude: nil, codex: nil))
    }
}

final class FormatTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(until(0), "0m")
        XCTAssertEqual(until(61), "2m")
        XCTAssertEqual(until(3600 + 600), "1h10m")
        XCTAssertEqual(until(3 * 86400 + 4 * 3600), "3d4h")
        let now = Date()
        XCTAssertEqual(age(now: now, now), "now")
        XCTAssertEqual(age(now: now, now - 300), "5m ago")
        XCTAssertEqual(age(now: now, now - 3 * 86400), "3d ago")
        XCTAssertEqual(goingOn(-5), "0s")
        XCTAssertEqual(goingOn(40), "40s")
        XCTAssertEqual(goingOn(185), "3m")
        XCTAssertEqual(goingOn(3600 + 5 * 60 + 59), "1h 5m")
    }

    func testShownBranch() {
        XCTAssertEqual(shownBranch("fix/x", place: "app"), "fix/x")
        XCTAssertNil(shownBranch("fix/x", place: "app/fix-x"))
        XCTAssertNil(shownBranch("fix/x", place: "app/x"))
        XCTAssertEqual(shownBranch("fix/x", place: "app/y"), "fix/x")
        XCTAssertEqual(shownBranch("main", place: "app/fix-x"), "main")
        XCTAssertNil(shownBranch(nil, place: "app"))
    }

    func testWhereASessionRuns() {
        XCTAssertEqual(RunningElsewhere(id: "x", busy: false, app: "Ghostty").appName, "Ghostty")
        XCTAssertEqual(RunningElsewhere(id: "x", busy: false, app: "Agentz").appName, "another agentz window")
        XCTAssertEqual(RunningElsewhere(id: "x", busy: false, app: nil).appName, "another app")
        XCTAssertEqual(RunningElsewhere(id: "x", busy: false, app: "Quick Terminal").appName, "the quick terminal")
        // No process outside this one has a made-up session open.
        XCTAssertNil(claudeRunningElsewhere(UUID().uuidString.lowercased(), nil))
    }
}

final class PathTests: XCTestCase {
    func testPathStarts() {
        XCTAssertTrue(pathStarts("/a/b", with: "/a"))
        XCTAssertTrue(pathStarts("/a", with: "/a/"))
        XCTAssertFalse(pathStarts("/ab", with: "/a"))
        XCTAssertTrue(pathStarts("/x", with: "/"))
    }

    func testShellEscape() {
        XCTAssertEqual(shellEscape("/tmp/a.png"), "/tmp/a.png")
        XCTAssertEqual(shellEscape("/tmp/Screen Shot (2).png"), #"/tmp/Screen\ Shot\ \(2\).png"#)
        XCTAssertEqual(shellEscape(#"it's $x"#), #"it\'s\ \$x"#)
    }
}

final class CommandFinishTests: XCTestCase {
    func testDefaultsAreOff() {
        let settings = CommandFinishSettings(config: "")
        XCTAssertEqual(settings, CommandFinishSettings())
        XCTAssertFalse(settings.applies(seconds: 60, looking: false))
    }

    func testReadsTheConfig() {
        let settings = CommandFinishSettings(config: """
        notify-on-command-finish = always
        notify-on-command-finish = unfocused
        notify-on-command-finish-action = notify
        notify-on-command-finish-after = 1m 30s
        """)
        XCTAssertEqual(settings.when, .unfocused)
        // Like Ghostty, `notify` alone keeps the bell.
        XCTAssertTrue(settings.bell)
        XCTAssertTrue(settings.notify)
        XCTAssertEqual(settings.after, 90)
        XCTAssertTrue(settings.applies(seconds: 90, looking: false))
        XCTAssertFalse(settings.applies(seconds: 89, looking: false))
        XCTAssertFalse(settings.applies(seconds: 90, looking: true))
    }

    func testAlwaysAppliesWhileLooking() {
        let settings = CommandFinishSettings(config: "notify-on-command-finish = always")
        XCTAssertTrue(settings.applies(seconds: 5, looking: true))
        XCTAssertFalse(settings.applies(seconds: 4.9, looking: true))
    }

    func testActions() {
        XCTAssertTrue(CommandFinishSettings.actions("no-bell,notify") == (false, true))
        XCTAssertTrue(CommandFinishSettings.actions("bell, no-notify") == (true, false))
        XCTAssertTrue(CommandFinishSettings.actions("false") == (false, false))
        XCTAssertTrue(CommandFinishSettings.actions("true") == (true, true))
        XCTAssertTrue(CommandFinishSettings.actions("") == (true, false))
    }

    func testDurations() {
        XCTAssertEqual(parseDuration("45s"), 45)
        XCTAssertEqual(parseDuration("1h30m"), 5400)
        XCTAssertEqual(parseDuration("1m 30s"), 90)
        XCTAssertEqual(parseDuration("1m1m"), 120)
        XCTAssertEqual(parseDuration("1d"), 86400)
        XCTAssertEqual(parseDuration("1w"), 7 * 86400)
        XCTAssertEqual(parseDuration("250ms")!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(parseDuration("5µs")!, 5e-6, accuracy: 1e-12)
        XCTAssertNil(parseDuration(""))
        XCTAssertNil(parseDuration("5"))
        XCTAssertNil(parseDuration("s"))
        XCTAssertNil(parseDuration("5 minutes"))
        XCTAssertEqual(CommandFinishSettings(config: "notify-on-command-finish-after = soon").after, 5)
    }

    func testElapsed() {
        XCTAssertEqual(elapsed(4.6), "5s")
        XCTAssertEqual(elapsed(60), "1m")
        XCTAssertEqual(elapsed(63), "1m 3s")
        XCTAssertEqual(elapsed(7500), "2h 5m")
        XCTAssertEqual(elapsed(7200), "2h")
    }
}

final class SplitLookTests: XCTestCase {
    func testGhosttyDefaults() {
        let look = SplitLook(config: "")
        XCTAssertEqual(look, SplitLook())
        XCTAssertEqual(look.unfocusedOpacity, 0.7)
        XCTAssertNil(look.unfocusedFill)
        XCTAssertNil(look.divider)
    }

    func testReadsTheConfig() {
        let look = SplitLook(config: """
        unfocused-split-opacity = 0.5
        unfocused-split-opacity = 0.9
        unfocused-split-fill = #102030
        split-divider-color = 405060
        """)
        XCTAssertEqual(look.unfocusedOpacity, 0.9)
        XCTAssertEqual(look.unfocusedFill, RGB(hex: "102030"))
        XCTAssertEqual(look.divider, RGB(hex: "405060"))
    }

    func testOpacityStaysInGhosttysRange() {
        XCTAssertEqual(SplitLook(config: "unfocused-split-opacity = 0").unfocusedOpacity, 0.15)
        XCTAssertEqual(SplitLook(config: "unfocused-split-opacity = 2").unfocusedOpacity, 1)
        XCTAssertEqual(SplitLook(config: "unfocused-split-opacity = half").unfocusedOpacity, 0.7)
    }
}

final class QuickTerminalTests: XCTestCase {
    func testGhosttyDefaults() {
        let settings = QuickTerminalSettings(config: "")
        XCTAssertEqual(settings, QuickTerminalSettings())
        XCTAssertEqual(settings.position, .top)
        XCTAssertEqual(settings.screen, .main)
        XCTAssertEqual(settings.animationDuration, 0.2)
        XCTAssertTrue(settings.autohide)
        XCTAssertEqual(settings.spaceBehavior, .move)
        XCTAssertNil(settings.hotKey)
    }

    func testReadsTheConfig() {
        let settings = QuickTerminalSettings(config: """
        quick-terminal-position = bottom
        quick-terminal-position = right
        quick-terminal-size = 50%,500px
        quick-terminal-screen = macos-menu-bar
        quick-terminal-animation-duration = 0
        quick-terminal-autohide = false
        quick-terminal-space-behavior = remain
        keybind = global:ctrl+`=toggle_quick_terminal
        """)
        XCTAssertEqual(settings.position, .right)
        XCTAssertEqual(settings.primarySize, .percent(50))
        XCTAssertEqual(settings.secondarySize, .points(500))
        XCTAssertEqual(settings.screen, .menuBar)
        XCTAssertEqual(settings.animationDuration, 0)
        XCTAssertFalse(settings.autohide)
        XCTAssertEqual(settings.spaceBehavior, .remain)
        XCTAssertEqual(settings.hotKey, KeyTrigger(modifiers: .control, key: "`", global: true))
    }

    func testBadValuesKeepTheDefaults() {
        let settings = QuickTerminalSettings(config: """
        quick-terminal-position = middle
        quick-terminal-size = 50
        quick-terminal-screen = left
        quick-terminal-animation-duration = fast
        """)
        XCTAssertEqual(settings, QuickTerminalSettings())
        XCTAssertNil(QuickTerminalSettings(config: "quick-terminal-size = 1%,2%,3%").primarySize)
    }

    func testOnlyAGlobalKeyToggles() {
        XCTAssertNil(QuickTerminalSettings(config: "keybind = ctrl+`=toggle_quick_terminal").hotKey)
        XCTAssertNil(QuickTerminalSettings(config: "keybind = global:ctrl+t=new_tab").hotKey)
        let settings = { (lines: String) in QuickTerminalSettings(config: lines).hotKey }
        XCTAssertEqual(settings("keybind = all:global:super+shift+grave_accent=toggle_quick_terminal"),
                       KeyTrigger(modifiers: [.command, .shift], key: "grave_accent", global: true))
        // Like in Ghostty, a later line wins.
        XCTAssertNil(settings("keybind = global:ctrl+`=toggle_quick_terminal\nkeybind = clear"))
        XCTAssertNil(settings("keybind = global:ctrl+`=toggle_quick_terminal\nkeybind = ctrl+`=unbind"))
        XCTAssertNotNil(settings("keybind = global:ctrl+`=toggle_quick_terminal\nkeybind = ctrl+a=unbind"))
    }

    func testKeyTriggers() {
        XCTAssertEqual(KeyTrigger("ctrl+alt+F12"), KeyTrigger(modifiers: [.control, .option], key: "f12"))
        XCTAssertEqual(KeyTrigger("cmd++"), KeyTrigger(modifiers: .command, key: "+"))
        XCTAssertEqual(KeyTrigger("opt+control+A"), KeyTrigger(modifiers: [.option, .control], key: "a"))
        XCTAssertNil(KeyTrigger("hyper+a"))
        XCTAssertNil(KeyTrigger("ctrl+a>n"))
        XCTAssertNil(KeyTrigger("ctrl+"))
        XCTAssertEqual(KeyTrigger("global:ctrl+shift+`")?.description, "ctrl+shift+`")
        let binding = KeyTrigger.binding("super+==increase_font_size:1")
        XCTAssertEqual(binding?.0, KeyTrigger(modifiers: .command, key: "="))
        XCTAssertEqual(binding?.1, "increase_font_size:1")
    }

    func testSizes() {
        let screen = CGSize(width: 1600, height: 1000)
        let size = { (lines: String) in QuickTerminalSettings(config: lines).size(on: screen) }
        // Along its edge, then the other way; the rest is Ghostty's.
        XCTAssertEqual(size(""), CGSize(width: 1600, height: 400))
        XCTAssertEqual(size("quick-terminal-size = 50%,70%"), CGSize(width: 1120, height: 500))
        XCTAssertEqual(size("quick-terminal-position = left\nquick-terminal-size = 25%"), CGSize(width: 400, height: 1000))
        XCTAssertEqual(size("quick-terminal-position = center"), CGSize(width: 800, height: 400))
        XCTAssertEqual(size("quick-terminal-position = center\nquick-terminal-size = 60%"), CGSize(width: 800, height: 600))
        XCTAssertEqual(QuickTerminalSettings(config: "quick-terminal-position = center").size(on: CGSize(width: 1000, height: 1600)),
                       CGSize(width: 400, height: 800))
        // No bigger than the screen.
        XCTAssertEqual(size("quick-terminal-size = 3000px"), CGSize(width: 1600, height: 1000))
    }

    func testFrames() {
        // The menu bar's 30 points at the top, a 70-point Dock at the bottom.
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let visible = CGRect(x: 0, y: 70, width: 1600, height: 900)
        let top = QuickTerminalSettings(config: "quick-terminal-size = 50%,70%")
        XCTAssertEqual(top.shownFrame(visible: visible), CGRect(x: 240, y: 520, width: 1120, height: 450))
        XCTAssertEqual(top.hiddenFrame(visible: visible, frame: frame), CGRect(x: 240, y: 1000, width: 1120, height: 450))
        let left = QuickTerminalSettings(config: "quick-terminal-position = left\nquick-terminal-size = 400px,50%")
        XCTAssertEqual(left.shownFrame(visible: visible), CGRect(x: 0, y: 295, width: 400, height: 450))
        XCTAssertEqual(left.hiddenFrame(visible: visible, frame: frame), CGRect(x: -400, y: 295, width: 400, height: 450))
        let bottom = QuickTerminalSettings(config: "quick-terminal-position = bottom")
        XCTAssertEqual(bottom.shownFrame(visible: visible).minY, 70)
        XCTAssertEqual(bottom.hiddenFrame(visible: visible, frame: frame).maxY, 0)
        let center = QuickTerminalSettings(config: "quick-terminal-position = center")
        XCTAssertEqual(center.hiddenFrame(visible: visible, frame: frame), center.shownFrame(visible: visible))
    }
}

final class ThemeColorTests: XCTestCase {
    func testThemeThenOwnColors() {
        let config = """
        # comment
        theme = light:/themes/Day,dark:/themes/Night
        palette = 2=#00ff00
        foreground = "#101010"
        """
        let themes = [
            "/themes/Day": "background = #fafafa\nforeground = #000000\npalette = 1=#cc0000",
            "/themes/Night": "background = 1e1e1e\npalette = 4 = #3355ff",
        ]
        let light = TerminalColors.from(config: config, dark: false) { themes[$0] }
        XCTAssertEqual(light.background, RGB(hex: "FAFAFA"))
        XCTAssertEqual(light.foreground, RGB(hex: "101010"))
        XCTAssertEqual(light.palette[1], RGB(hex: "CC0000"))
        XCTAssertEqual(light.palette[2], RGB(hex: "00FF00"))
        XCTAssertFalse(light.isDark)

        let dark = TerminalColors.from(config: config, dark: true) { themes[$0] }
        XCTAssertEqual(dark.background, RGB(hex: "1E1E1E"))
        XCTAssertEqual(dark.palette[4], RGB(hex: "3355FF"))
        XCTAssertTrue(dark.isDark)
    }

    func testDefaultsWithoutConfig() {
        XCTAssertEqual(TerminalColors.from(config: "", dark: true) { _ in nil }, .ghostty)
        XCTAssertEqual(TerminalColors.pickTheme("Solo", dark: true), "Solo")
        XCTAssertNil(RGB(hex: "red"))
    }

    func testPickedThemeReplacesConfigColors() {
        let config = """
        font-size = 13
        theme = light:Day,dark:Night
        background = #101010
        palette = 1=#ff0000
        cursor-color=#00ff00
        """
        XCTAssertEqual(GhosttyThemes.config(config, using: "/themes/Paper"), """
        font-size = 13
        theme = /themes/Paper
        """)
        let colors = TerminalColors.from(config: GhosttyThemes.config(config, using: "/themes/Paper"), dark: true) {
            $0 == "/themes/Paper" ? "background = #fcf4dc\npalette = 1=#c94c22" : nil
        }
        XCTAssertEqual(colors.background, RGB(hex: "fcf4dc"))
        XCTAssertEqual(colors.foreground, TerminalColors.ghostty.foreground)
        XCTAssertEqual(colors.palette, [1: RGB(hex: "c94c22")!])
        XCTAssertNil(colors.cursor)
    }

    private func themeDirectories() throws -> (dirs: [String], cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentz-themes-\(UUID().uuidString)")
        let dirs = [root.appendingPathComponent("user"), root.appendingPathComponent("app")]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (dirs.map(\.path), { try? FileManager.default.removeItem(at: root) })
    }

    func testListsThemeNamesOnceInFinderOrder() throws {
        let (dirs, cleanup) = try themeDirectories()
        defer { cleanup() }
        try FileManager.default.createDirectory(atPath: dirs[0] + "/Folder", withIntermediateDirectories: true)
        for (dir, name) in [
            (dirs[0], "Theme 10"), (dirs[0], "Mine"), (dirs[0], ".hidden"),
            (dirs[1], "Theme 2"), (dirs[1], "Mine"), (dirs[1], "alabaster"),
        ] {
            try "background = #333333".write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(GhosttyThemes.names(in: dirs), ["alabaster", "Mine", "Theme 2", "Theme 10"])
        XCTAssertEqual(GhosttyThemes.path(of: "Mine", in: dirs), dirs[0] + "/Mine")
        XCTAssertNil(GhosttyThemes.path(of: "Gone", in: dirs))
    }

    func testSortsThemesIntoLightAndDark() throws {
        let (dirs, cleanup) = try themeDirectories()
        defer { cleanup() }
        for (name, text) in [
            ("Paper", "background = #f7f7f7"),
            ("Night", "background = #212121"),
            ("Bare", "foreground = #111111"),
        ] {
            try text.write(toFile: dirs[0] + "/" + name, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(GhosttyThemes.themes(named: ["Paper", "Night", "Bare"], in: dirs), [
            GhosttyTheme(name: "Paper", isDark: false),
            GhosttyTheme(name: "Night", isDark: true),
            // No background means Ghostty's dark default.
            GhosttyTheme(name: "Bare", isDark: true),
        ])
    }
}

final class WorktreeTests: XCTestCase {
    private func wt(_ path: String, _ branch: String?, head: String = "1a2b3c4d5e") -> Worktree {
        Worktree(path: path, branch: branch, head: head, isMain: false, bare: false, locked: false, missing: false)
    }

    func testFindsTheDeepestWorktree() {
        let list = [wt("/r/app", "main"), wt("/r/app/nested", "x")]
        XCTAssertEqual(worktree(containing: "/r/app/src", in: list)?.branch, "main")
        XCTAssertEqual(worktree(containing: "/r/app/nested/a", in: list)?.branch, "x")
        XCTAssertNil(worktree(containing: "/r/application", in: list))
    }

    func testLabels() {
        XCTAssertEqual(wt("/a", "feature/x").label, "feature/x")
        XCTAssertEqual(wt("/a", nil).label, "detached 1a2b3c4")
        XCTAssertEqual(Branch(name: "x", remote: "origin").ref, "origin/x")
        XCTAssertEqual(Branch(name: "x", remote: nil).ref, "x")
    }

    func testRecentFolders() {
        XCTAssertEqual(addingRecent("/b", to: ["/a", "/b", "/c"]), ["/b", "/a", "/c"])
        XCTAssertEqual(addingRecent("/d", to: ["/a", "/b", "/c"], limit: 3), ["/d", "/a", "/b"])
    }

    func testCoreErrorsSayWhatWentWrong() {
        XCTAssertThrowsError(try forkWorktree("/nonexistent-\(UUID().uuidString)", "x", false)) { error in
            XCTAssertTrue(errorMessage(error).contains("not in a git repo"), errorMessage(error))
        }
    }
}

final class CleanupTests: XCTestCase {
    func testWhatCanGo() {
        XCTAssertTrue(WorktreeState.merged.removable)
        XCTAssertTrue(WorktreeState.missing.removable)
        for kept in [WorktreeState.changes(files: 1), .notMerged(commits: 2), .locked, .inUse(program: "claude"), .unknown(problem: "x")] {
            XCTAssertFalse(kept.removable, "\(kept)")
        }
        XCTAssertEqual(WorktreeState.merged.text(into: "main"), "Merged into main, nothing uncommitted")
        XCTAssertEqual(WorktreeState.changes(files: 1).text(into: "main"), "1 uncommitted change")
        XCTAssertEqual(WorktreeState.notMerged(commits: 3).text(into: "main"), "3 commits not in main")
        XCTAssertEqual(WorktreeState.inUse(program: "claude").text(into: "main"), "claude runs in it")
    }

    func testRemovingOutsideARepoSaysWhy() {
        XCTAssertThrowsError(try removeWorktree("/nonexistent-\(UUID().uuidString)", "/x")) { error in
            XCTAssertTrue(errorMessage(error).contains("not in a git repo"), errorMessage(error))
        }
    }
}

final class LimitResetTests: XCTestCase {
    private func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testClaudeSaysWhenItResets() {
        // 12:32 in Istanbul (UTC+3).
        let at = utc("2026-09-03T09:32:07Z")
        XCTAssertEqual(limitReset("You've hit your session limit · resets 2:10pm (Europe/Istanbul)", at: at), utc("2026-09-03T11:10:00Z"))
        // Earlier in the day than the stop: tomorrow.
        XCTAssertEqual(limitReset("resets 9am (Europe/Istanbul)", at: at), utc("2026-09-04T06:00:00Z"))
        XCTAssertEqual(limitReset("resets at 4pm (UTC)", at: at), utc("2026-09-03T16:00:00Z"))
        XCTAssertEqual(limitReset("resets 12am (UTC)", at: at), utc("2026-09-04T00:00:00Z"))
        XCTAssertEqual(limitReset("resets 12pm (UTC)", at: at), utc("2026-09-03T12:00:00Z"))
        // A weekly limit names the day; a day before the stop is next year.
        XCTAssertEqual(limitReset("You've hit your weekly limit · resets Sep 5 at 6:19pm (Europe/London)", at: at), utc("2026-09-05T17:19:00Z"))
        XCTAssertEqual(limitReset("resets Aug 31 at 6pm (UTC)", at: at), utc("2027-08-31T18:00:00Z"))
        // The spend limit message names the session limit's reset.
        XCTAssertEqual(
            limitReset("You've hit your monthly spend limit · raise it at claude.ai · your session limit resets 2:10pm (Europe/Istanbul)", at: at),
            utc("2026-09-03T11:10:00Z")
        )
        // Without a zone, this Mac's.
        let local = limitReset("resets 11:30pm", at: at)!
        let c = Calendar.current.dateComponents([.hour, .minute], from: local)
        XCTAssertEqual([c.hour, c.minute], [23, 30])
        XCTAssertGreaterThan(local, at)
        XCTAssertNil(limitReset("API Error: 500 Internal server error.", at: at))
        XCTAssertNil(limitReset("resets 13pm (UTC)", at: at))
    }

    func testCodexSaysWhenToTryAgain() {
        let at = utc("2026-07-31T07:19:09Z")
        let reset = limitReset("You've hit your usage limit. Upgrade to Pro, or try again at Aug 5th, 2026 9:34 AM.", at: at)!
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reset)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 8, 5, 9, 34])
        let pm = limitReset("try again at Sep 28th, 2026 1:05 PM", at: at)!
        XCTAssertEqual(Calendar.current.component(.hour, from: pm), 13)
    }

    func testTheUsedUpWindowWhenTheAgentSaysNoTime() {
        let at = Date(timeIntervalSince1970: 1000)
        let usage = Usage(session: Window(used: 100, resetsAt: 5000), week: Window(used: 40, resetsAt: 90000))
        XCTAssertEqual(limitReset(usage, after: at), Date(timeIntervalSince1970: 5000))
        let both = Usage(session: Window(used: 100, resetsAt: 5000), week: Window(used: 100, resetsAt: 90000))
        XCTAssertEqual(limitReset(both, after: at), Date(timeIntervalSince1970: 90000))
        XCTAssertNil(limitReset(Usage(session: Window(used: 100, resetsAt: 500), week: nil), after: at))
        XCTAssertNil(limitReset(nil, after: at))
    }
}

final class NoticeTests: XCTestCase {
    private let a = SessionKey(.claude, "a"), b = SessionKey(.codex, "b"), c = SessionKey(.claude, "c")

    private func notice(_ key: SessionKey, _ message: String? = nil) -> SessionNotice {
        SessionNotice(key: key, heading: "\(key.agent == .claude ? "Claude" : "Codex") is waiting", title: "Task \(key.id)", message: message)
    }

    func testOneNoticeIsAboutItsSession() {
        var batcher = NoticeBatcher()
        XCTAssertTrue(batcher.add(notice(a, "Done:   OK")))
        let (post, replaced) = batcher.flush()
        XCTAssertEqual(post, NoticePost(id: "claude:a", title: "Claude is waiting", body: "Task a: Done: OK", keys: [a]))
        XCTAssertEqual(replaced, [])
        XCTAssertNil(batcher.flush().post)
    }

    func testNoticesAtTheSameMomentAreOne() {
        var batcher = NoticeBatcher()
        XCTAssertTrue(batcher.add(notice(a)))
        XCTAssertFalse(batcher.add(notice(b, "Needs your permission")))
        // A newer one about the same session takes the older one's place.
        XCTAssertFalse(batcher.add(notice(a, "Done")))
        let post = batcher.flush().post!
        XCTAssertEqual(post.title, "2 sessions need you")
        XCTAssertEqual(post.body, "Task b: Needs your permission\nTask a: Done")
        XCTAssertEqual(Set(post.keys), [a, b])
    }

    func testANotificationGoesOnceItsSessionsWereSeen() {
        var batcher = NoticeBatcher()
        _ = batcher.add(notice(a))
        _ = batcher.add(notice(b))
        let both = batcher.flush().post!.id
        _ = batcher.add(notice(c))
        let single = batcher.flush().post!.id
        XCTAssertEqual(batcher.seen(a), [])
        XCTAssertEqual(batcher.seen(c), [single])
        XCTAssertEqual(batcher.seen(b), [both])
        XCTAssertEqual(batcher.shown, [:])
        // Seeing it before it is shown drops it.
        _ = batcher.add(notice(a))
        XCTAssertEqual(batcher.seen(a), [])
        XCTAssertNil(batcher.flush().post)
    }

    func testANewerNotificationTakesTheOlderOnesPlace() {
        var batcher = NoticeBatcher()
        _ = batcher.add(notice(a))
        let first = batcher.flush().post!.id
        _ = batcher.add(notice(a))
        _ = batcher.add(notice(b))
        let (post, replaced) = batcher.flush()
        XCTAssertEqual(replaced, [first])
        // One about the same single session has the same id, so macOS
        // replaces it by itself.
        _ = batcher.add(notice(c))
        let one = batcher.flush().post!.id
        _ = batcher.add(notice(c))
        let again = batcher.flush()
        XCTAssertEqual(again.post?.id, one)
        XCTAssertEqual(again.replaced, [])
        XCTAssertEqual(Set(batcher.shown.keys), [post!.id, one])
    }
}

final class TextTests: XCTestCase {
    func testShortAndSizes() {
        XCTAssertEqual(short("a\n  b", 10), "a b")
        XCTAssertEqual(short("abcdef", 3), "abc…")
        // In this Mac's language: 1.2 GB, or 1,2 GB.
        let size = memorySize(1_288_490_189)
        XCTAssertTrue(size.hasPrefix("1") && size.contains("2") && size.hasSuffix("GB"), size)
    }

    func testTimesOfDay() {
        let now = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let later = now.addingTimeInterval(3600)
        let time = later.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(clockTime(later, now: now), time)
        XCTAssertEqual(atTime(later, now: now), "at \(time)")
        let tomorrow = now.addingTimeInterval(86400)
        XCTAssertEqual(atTime(tomorrow, now: now), "tomorrow at \(tomorrow.formatted(date: .omitted, time: .shortened))")
        XCTAssertTrue(atTime(now.addingTimeInterval(3 * 86400), now: now).hasPrefix("on "))
    }
}

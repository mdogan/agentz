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

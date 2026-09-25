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

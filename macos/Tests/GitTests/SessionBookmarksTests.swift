import AgentzCore
import Foundation
import Testing
@testable import agentz

@MainActor
struct SessionBookmarksTests {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentz-bookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("bookmarks.json")
    }

    @Test func bookmarksSurviveARestart() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionBookmarks(url: url)
        let claude = SessionKey(.claude, "same-id"), codex = SessionKey(.codex, "same-id")
        let added = Date(timeIntervalSince1970: 1_800_000_000)
        store.add(claude, title: "Review", folder: "/project", at: added)
        store.add(codex, title: "Fix", folder: "/other")
        // Twice is once.
        store.add(claude, title: "Again", folder: "/project")
        let restored = SessionBookmarks(url: url)
        #expect(restored.bookmarks.count == 2)
        #expect(restored.bookmark(for: claude) == SessionBookmark(session: "claude:same-id", title: "Review", folder: "/project", added: added))
        #expect(restored.contains(codex))
        restored.remove(claude)
        #expect(SessionBookmarks(url: url).bookmarks.map(\.session) == ["codex:same-id"])
    }

    @Test func onlyAgentSessionsCanBeBookmarked() {
        let store = SessionBookmarks()
        store.add(SessionKey(.shell, "1"), title: "fish", folder: "/project")
        store.add(SessionKey(.git, "2"), title: "main", folder: "/project")
        #expect(store.bookmarks.isEmpty)
    }

    @Test func aNewCodexSessionKeepsItsBookmarkWhenItGetsItsId() {
        let store = SessionBookmarks()
        let draft = SessionKey(.codex, "new-1"), real = SessionKey(.codex, "thread")
        store.add(draft, title: "New Codex session", folder: "/project")
        store.rebind(from: draft, to: real)
        #expect(!store.contains(draft))
        #expect(store.contains(real))
        // Already bookmarked under its real id: one bookmark is left.
        store.add(draft, title: "New Codex session", folder: "/project")
        store.rebind(from: draft, to: real)
        #expect(store.bookmarks.map(\.session) == ["codex:thread"])
    }

    @Test func anUnreadableFileIsLeftAlone() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("broken".utf8).write(to: url)
        let store = SessionBookmarks(url: url)
        #expect(store.isReadOnly)
        #expect(store.problem != nil)
        store.add(SessionKey(.claude, "one"), title: "Review", folder: "/project")
        #expect(store.bookmarks.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }

    @Test func bookmarkedSessionsShowWhateverTheirAge() {
        let bookmarks = SessionBookmarks()
        let workspace = Workspace(projectDir: "/tmp", bookmarks: bookmarks)
        let old = SessionKey(.claude, "old")
        bookmarks.add(old, title: "Old work", folder: "/tmp/old", at: Date(timeIntervalSince1970: 1_700_000_000))
        workspace.range = .today
        #expect(workspace.rows.isEmpty)
        // Before the scan reads it, the row shows what the bookmark kept.
        workspace.range = .bookmarked
        #expect(workspace.rows.map(\.key) == [old])
        #expect(workspace.rows.first?.title == "Old work")
        #expect(workspace.rows.first?.bookmarked == true)
        #expect(workspace.rows.first?.missing == false)
        workspace.toggleBookmarkedRange()
        #expect(workspace.range == .today)
        workspace.toggleBookmark(old)
        workspace.range = .bookmarked
        #expect(workspace.rows.isEmpty)
    }
}

import AgentzCore
import AppKit
import Testing
@testable import agentz

@MainActor
struct SessionNotesTests {
    private func location() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/codex-501/agentz-notes/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("notes.json")
    }

    @Test func roundTripKeepsProvidersSeparateAndMarkdownExact() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(url: url)
        let claude = try #require(store.create(for: SessionKey(.claude, "same-id"), title: "Review", folder: "/project"))
        let codex = try #require(store.create(for: SessionKey(.codex, "same-id"), title: "Fix", folder: "/project"))
        let markdown = "# Résumé 📝\n\n- [ ] Test sleep\n\n```swift\nlet x = 1\n```\n"
        store.update(claude, text: markdown)
        store.update(codex, text: "Different note")
        #expect(store.flush())
        let restored = SessionNotes(url: url)
        #expect(restored.note(claude)?.text == markdown)
        #expect(restored.note(codex)?.text == "Different note")
        #expect(restored.notes.count == 2)
        #expect(!restored.isReadOnly)
    }

    @Test func provisionalIDMigrationSurvivesRestartAndKeepsEditorIdentity() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(url: url)
        let old = SessionKey(.codex, "new-\(UUID())"), real = SessionKey(.codex, "thread-id")
        let id = try #require(store.create(for: old, title: "New session", folder: "/project"))
        store.update(id, text: "Before the first prompt")
        store.rebind(from: old, to: real)
        #expect(store.note(for: old) == nil)
        #expect(store.note(for: real)?.id == id)
        #expect(store.flush())
        let restored = SessionNotes(url: url)
        #expect(restored.note(for: real)?.text == "Before the first prompt")
        #expect(restored.note(for: real)?.id == id)
    }

    @Test func migrationPreservesAnExistingDestinationNote() throws {
        // Destination first exercises removal shifting the draft's index.
        let store = SessionNotes()
        let old = SessionKey(.codex, "new-draft"), real = SessionKey(.codex, "thread")
        let existing = try #require(store.create(for: real, title: "Known title", folder: "/project"))
        store.update(existing, text: "Existing note")
        let draft = try #require(store.create(for: old, title: "New session", folder: "/project"))
        store.update(draft, text: "Draft note")
        store.rebind(from: old, to: real)
        #expect(store.notes.count == 1)
        #expect(store.note(for: real)?.id == draft)
        #expect(store.note(draft)?.text == "Existing note\n\n---\n\nDraft note")
        #expect(store.note(draft)?.title == "Known title")
    }

    @Test func corruptOrFutureDocumentIsNeverOverwritten() throws {
        for content in ["{broken", "{\"version\":999,\"notes\":[]}"] {
            let url = try location()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try content.write(to: url, atomically: true, encoding: .utf8)
            let store = SessionNotes(url: url)
            #expect(store.isReadOnly)
            #expect(store.problem != nil)
            #expect(store.create(for: SessionKey(.claude, "id"), title: "Note", folder: "/") == nil)
            store.flush()
            #expect(try String(contentsOf: url, encoding: .utf8) == content)
        }
    }

    @Test func failedWriteKeepsDraftAndCanBeRetried() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(url: url)
        let id = try #require(store.create(for: SessionKey(.claude, "id"), title: "Note", folder: "/"))
        store.update(id, text: "Do not lose this")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(!store.flush())
        #expect(store.isDirty)
        #expect(store.note(id)?.text == "Do not lose this")
        try FileManager.default.removeItem(at: url)
        #expect(store.flush())
        #expect(!store.isDirty)
        #expect(store.problem == nil)
        #expect(SessionNotes(url: url).note(id)?.text == "Do not lose this")
    }

    @Test func deletingOneNotePersistsWithoutDeletingAnother() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(url: url)
        let first = try #require(store.create(for: SessionKey(.claude, "first"), title: "First", folder: "/"))
        let second = try #require(store.create(for: SessionKey(.claude, "second"), title: "Second", folder: "/"))
        store.update(second, text: "Keep")
        #expect(store.flush())
        store.delete(first)
        #expect(store.flush())
        let restored = SessionNotes(url: url)
        #expect(restored.note(first) == nil)
        #expect(restored.note(second)?.text == "Keep")
    }

    @Test func missingAndFilteredSessionsKeepNotesAndSearchMatchesText() throws {
        let workspace = Workspace(projectDir: "/tmp")
        let session = Session(agent: .claude, id: "session", title: "Fix", cwd: "/tmp", originator: nil,
                              created: Date(), updated: Date(), inProject: true, branch: nil, pr: nil,
                              limit: nil, turnStarted: nil, action: nil, context: nil)
        func scan(_ sessions: [Session]) -> Scan {
            Scan(sessions: sessions, complete: true, shells: [], codexThreads: [:], limits: Limits(),
                 worktrees: [], elsewhere: [], leftovers: [])
        }
        workspace.apply(scan([session]), dir: "/tmp")
        let id = try #require(workspace.ensureNote(session.key))
        workspace.notes.update(id, text: "Check reconnect after sleep")
        workspace.filter = "RECONNECT"
        #expect(workspace.rows.map(\.key) == [session.key])
        workspace.filter = "unmatched"
        #expect(workspace.rows.isEmpty)
        #expect(workspace.hasNoteSession(session.key))
        workspace.apply(scan([]), dir: "/tmp")
        #expect(!workspace.hasNoteSession(session.key))
        #expect(workspace.notes.note(id)?.text == "Check reconnect after sleep")
        #expect(workspace.notes.note(id)?.title == "Fix")
        #expect(workspace.notes.note(id)?.matches("sleep") == true)
        #expect(workspace.ensureNote(SessionKey(.shell, "shell")) == nil)
    }

    @Test func emptyDraftStaysEditableButIsNotSaved() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(url: url)
        let id = try #require(store.create(for: SessionKey(.claude, "empty"), title: "Empty", folder: "/"))
        store.update(id, text: " \n\t ")
        #expect(store.flush())
        #expect(store.note(id) != nil)
        #expect(SessionNotes(url: url).notes.isEmpty)
        store.update(id, text: "Kept typing")
        store.finishEditing(id)
        #expect(SessionNotes(url: url).note(id)?.text == "Kept typing")
        store.update(id, text: "\n ")
        store.finishEditing(id)
        #expect(store.note(id) == nil)
        #expect(SessionNotes(url: url).notes.isEmpty)
    }

    @Test func finishingEmptyNoteKeepsOtherDraftsAndSavedNotes() throws {
        let store = SessionNotes()
        let empty = try #require(store.create(for: SessionKey(.claude, "empty"), title: "Empty", folder: "/"))
        let draft = try #require(store.create(for: SessionKey(.claude, "draft"), title: "Draft", folder: "/"))
        let saved = try #require(store.create(for: SessionKey(.claude, "saved"), title: "Saved", folder: "/"))
        store.update(saved, text: "Keep this")
        store.finishEditing(empty)
        #expect(store.note(empty) == nil)
        #expect(store.note(draft) != nil)
        #expect(store.note(saved)?.text == "Keep this")
    }
}

@MainActor
struct NoteLiveStyleTests {
    private func styled(_ source: String, active: NSRange? = nil) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(string: source)
        NoteLiveStyle.apply(to: text, active: active)
        return text
    }

    private func font(_ text: NSAttributedString, at word: String) throws -> NSFont {
        try #require(text.attribute(.font, at: (text.string as NSString).range(of: word).location, effectiveRange: nil) as? NSFont)
    }

    private func hidden(_ text: NSAttributedString, at index: Int) -> Bool {
        (text.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize ?? 13 < 1
    }

    @Test func keepsTheSourceAndStylesHeadingsBoldItalicAndCode() throws {
        let source = "# Heading\n\n**Bold** and *italic* and `code`\n\n```swift\nlet x = 1\n```"
        let text = styled(source)
        #expect(text.string == source)
        #expect(try font(text, at: "Heading").pointSize == 22)
        #expect(NSFontManager.shared.traits(of: try font(text, at: "Bold")).contains(.boldFontMask))
        #expect(NSFontManager.shared.traits(of: try font(text, at: "italic")).contains(.italicFontMask))
        #expect(try font(text, at: "code").isFixedPitch)
        #expect(try font(text, at: "let x").isFixedPitch)
        #expect(hidden(text, at: 0))
        #expect(hidden(text, at: (source as NSString).range(of: "**Bold").location))
        #expect(!hidden(text, at: (source as NSString).range(of: "```").location))
    }

    @Test func showsMarksOnlyOnTheLineBeingEdited() {
        let source = "# One\n# Two"
        let text = styled(source, active: NSRange(location: 8, length: 0))
        #expect(hidden(text, at: 0))
        #expect(!hidden(text, at: 6))
    }

    @Test func linksOnlyWebOrMailTargets() {
        let source = "[web](https://example.com) [local](file:///tmp/private) [script](javascript:alert) https://agentz.dev"
        let text = styled(source)
        let ns = source as NSString
        #expect(text.attribute(.noteLink, at: ns.range(of: "web").location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        #expect(text.attribute(.noteLink, at: ns.range(of: "local").location, effectiveRange: nil) == nil)
        #expect(text.attribute(.noteLink, at: ns.range(of: "script").location, effectiveRange: nil) == nil)
        #expect(text.attribute(.noteLink, at: ns.range(of: "agentz.dev").location, effectiveRange: nil) as? URL == URL(string: "https://agentz.dev"))
        #expect(text.attribute(.link, at: ns.range(of: "web").location, effectiveRange: nil) == nil)
    }

    @Test func leavesSnakeCaseAndCodeContentsAlone() throws {
        let text = styled("snake_case_name and `**not bold**`")
        #expect(!NSFontManager.shared.traits(of: try font(text, at: "case")).contains(.italicFontMask))
        #expect(!NSFontManager.shared.traits(of: try font(text, at: "not bold")).contains(.boldFontMask))
    }
}

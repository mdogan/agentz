import AgentzCore
import AppKit
import Testing
@testable import agentz

@MainActor
struct SessionNotesTests {
    private func location() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/codex-501/agentz-notes/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("notes", isDirectory: true)
    }

    private func files(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test func roundTripKeepsProvidersSeparateAndMarkdownExact() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(directory: url)
        let claude = try #require(store.create(for: SessionKey(.claude, "same-id"), title: "Review", folder: "/project"))
        let codex = try #require(store.create(for: SessionKey(.codex, "same-id"), title: "Fix", folder: "/project"))
        let markdown = "# Résumé 📝\n\n- [ ] Test sleep\n\n```swift\nlet x = 1\n```\n"
        store.update(claude, text: markdown)
        store.update(codex, text: "Different note")
        #expect(store.flush())
        let restored = SessionNotes(directory: url)
        #expect(restored.note(claude)?.text == markdown)
        #expect(restored.note(codex)?.text == "Different note")
        #expect(restored.notes.count == 2)
        #expect(!restored.isReadOnly)
    }

    @Test func provisionalIDMigrationSurvivesRestartAndKeepsEditorIdentity() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(directory: url)
        let old = SessionKey(.codex, "new-\(UUID())"), real = SessionKey(.codex, "thread-id")
        let id = try #require(store.create(for: old, title: "New session", folder: "/project"))
        store.update(id, text: "Before the first prompt")
        store.rebind(from: old, to: real)
        #expect(store.note(for: old) == nil)
        #expect(store.note(for: real)?.id == id)
        #expect(store.flush())
        let restored = SessionNotes(directory: url)
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

    @Test func eachNoteIsAMarkdownFileNamedAfterItsSession() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(directory: url)
        let id = try #require(store.create(for: SessionKey(.claude, "abc"), title: "New: a/b", folder: "/project"))
        store.update(id, text: "# Plan\n\n- one")
        #expect(store.flush())
        let short = id.uuidString.prefix(8).lowercased()
        #expect(files(url) == ["New a b \(short).md"])
        let file = try String(contentsOf: url.appendingPathComponent("New a b \(short).md"), encoding: .utf8)
        #expect(file.hasPrefix("---\nid: \(id.uuidString)\nsession: \"claude:abc\"\ntitle: \"New: a/b\"\nfolder: \"/project\"\n"))
        #expect(file.hasSuffix("---\n\n# Plan\n\n- one"))

        // A new title renames the file; the old one is removed.
        store.refreshMetadata([Session(agent: .claude, id: "abc", title: "Fix parser", cwd: "/project", originator: nil,
                                       created: Date(), updated: Date(), inProject: true, branch: nil, pr: nil,
                                       limit: nil, turnStarted: nil, action: nil, context: nil)])
        #expect(store.flush())
        #expect(files(url) == ["Fix parser \(short).md"])
        #expect(SessionNotes(directory: url).note(id)?.title == "Fix parser")
    }

    @Test func caseOnlyRenameKeepsTheNoteAndAnExternalEdit() throws {
        let dir = try location()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let notes = SessionNotes(directory: dir)
        let key = SessionKey(.codex, "thread")
        let id = try #require(notes.create(for: key, title: "Parser", folder: "/project"))
        notes.update(id, text: "Draft")
        #expect(notes.flush())
        var edited = try #require(notes.note(id))
        let original = dir.appendingPathComponent(NoteFile.name(for: edited))
        edited.text = "Saved in another editor"
        try NoteFile.format(edited).write(to: original, atomically: true, encoding: .utf8)
        notes.refreshMetadata([Session(agent: .codex, id: "thread", title: "parser", cwd: "/project", originator: nil,
                                      created: Date(), updated: Date(), inProject: true, branch: nil, pr: nil,
                                      limit: nil, turnStarted: nil, action: nil, context: nil)])
        #expect(notes.flush())
        let reopened = SessionNotes(directory: dir)
        #expect(reopened.notes.count == 1)
        #expect(reopened.note(id)?.text == edited.text)
        #expect(reopened.note(id)?.title == "parser")
        #expect(files(dir).count == 1)
    }

    @Test func twoEditorsChangingOneBodyKeepBothVersions() throws {
        let dir = try location()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let first = SessionNotes(directory: dir)
        let id = try #require(first.create(for: SessionKey(.claude, "thread"), title: "Fix", folder: "/project"))
        first.update(id, text: "Original")
        #expect(first.flush())
        let second = SessionNotes(directory: dir)
        second.update(id, text: "Second draft")
        first.update(id, text: "First draft")
        #expect(first.flush())
        #expect(second.flush())
        #expect(SessionNotes(directory: dir).note(id)?.text == "Second draft")
        let recovered = dir.appendingPathComponent("Recovered")
        #expect(SessionNotes(directory: recovered).note(id)?.text == "First draft")
        #expect(second.problem?.contains("Recovered") == true)
    }

    @Test func unreadableFilesAreSkippedAndNeverOverwritten() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let broken = url.appendingPathComponent("Broken.md")
        try "no front matter".write(to: broken, atomically: true, encoding: .utf8)
        let store = SessionNotes(directory: url)
        #expect(!store.isReadOnly)
        #expect(store.problem?.contains("Broken.md") == true)
        let id = try #require(store.create(for: SessionKey(.claude, "id"), title: "Note", folder: "/"))
        store.update(id, text: "Works")
        #expect(store.flush())
        #expect(try String(contentsOf: broken, encoding: .utf8) == "no front matter")
        #expect(SessionNotes(directory: url).note(id)?.text == "Works")
    }

    @Test func unreadableFolderMakesNotesReadOnly() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "not a folder".write(to: url, atomically: true, encoding: .utf8)
        let store = SessionNotes(directory: url)
        #expect(store.isReadOnly)
        #expect(store.problem != nil)
        #expect(store.create(for: SessionKey(.claude, "id"), title: "Note", folder: "/") == nil)
        store.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "not a folder")
    }

    @Test func failedWriteKeepsDraftAndCanBeRetried() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(directory: url)
        let id = try #require(store.create(for: SessionKey(.claude, "id"), title: "Note", folder: "/"))
        store.update(id, text: "Do not lose this")
        try "blocks the folder".write(to: url, atomically: true, encoding: .utf8)
        #expect(!store.flush())
        #expect(store.isDirty)
        #expect(store.note(id)?.text == "Do not lose this")
        try FileManager.default.removeItem(at: url)
        #expect(store.flush())
        #expect(!store.isDirty)
        #expect(store.problem == nil)
        #expect(SessionNotes(directory: url).note(id)?.text == "Do not lose this")
    }

    @Test func deletingOneNotePersistsWithoutDeletingAnother() throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionNotes(directory: url)
        let first = try #require(store.create(for: SessionKey(.claude, "first"), title: "First", folder: "/"))
        let second = try #require(store.create(for: SessionKey(.claude, "second"), title: "Second", folder: "/"))
        store.update(first, text: "Remove")
        store.update(second, text: "Keep")
        #expect(store.flush())
        store.delete(first)
        #expect(store.flush())
        let restored = SessionNotes(directory: url)
        #expect(restored.note(first) == nil)
        #expect(restored.note(second)?.text == "Keep")
        store.delete(second)
        #expect(store.flush())
        #expect(files(url).isEmpty)
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
        let store = SessionNotes(directory: url)
        let id = try #require(store.create(for: SessionKey(.claude, "empty"), title: "Empty", folder: "/"))
        store.update(id, text: " \n\t ")
        #expect(store.flush())
        #expect(store.note(id) != nil)
        #expect(SessionNotes(directory: url).notes.isEmpty)
        store.update(id, text: "Kept typing")
        store.finishEditing(id)
        #expect(SessionNotes(directory: url).note(id)?.text == "Kept typing")
        store.update(id, text: "\n ")
        store.finishEditing(id)
        #expect(store.note(id) == nil)
        #expect(SessionNotes(directory: url).notes.isEmpty)
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

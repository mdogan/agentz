import CodeEditSourceEditor
import Foundation
import Testing
@testable import agentz

struct EditableTextTests {
    @Test
    func decodesUTF8AndRefusesBinaryOrOtherEncodings() {
        #expect(EditableText.decode(Data("let a = 1\n".utf8)) == .text("let a = 1\n"))
        #expect(EditableText.decode(Data([0x61, 0x00, 0x62])) == .unavailable("This is a binary file."))
        #expect(EditableText.decode(Data([0x61, 0xFF, 0xFE])) == .unavailable("This file is not UTF-8 text."))
        let large = Data(repeating: 0x61, count: EditableText.maxBytes + 1)
        #expect(EditableText.decode(large) == .unavailable("This file is too large to edit here."))
    }

    @Test
    func keepsAByteOrderMarkForSaving() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("hi\n".utf8)
        guard case .text(let text) = EditableText.decode(data) else {
            Issue.record("not text")
            return
        }
        #expect(Data(text.utf8) == data)
    }

    @Test
    func guessesTheIndent() {
        #expect(EditableText.indent(for: "a {\n\tb\n\tc\n}\n") == .tab)
        #expect(EditableText.indent(for: "a:\n  b:\n    c: 1\n  d: 2\n") == .spaces(count: 2))
        #expect(EditableText.indent(for: "def a():\n    b()\n    if c:\n        d()\n") == .spaces(count: 4))
        #expect(EditableText.indent(for: "no indent\n") == .spaces(count: 4))
    }
}

@MainActor
struct FileEditorModelTests {
    private func file(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("a.swift")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func disk(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func savesEditsAndKeepsTheFileMode() throws {
        let url = try file("one\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let model = FileEditorModel(url: url, path: "a.swift")
        #expect(model.phase == .ready && !model.isDirty)

        model.textDidChange("one\ntwo\n")
        #expect(model.isDirty)
        #expect(model.save())
        #expect(disk(url) == "one\ntwo\n" && !model.isDirty)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)

        model.textDidChange("one\ntwo\nthree\n")
        model.textDidChange("one\ntwo\n")
        #expect(!model.isDirty, "undoing back to the saved text leaves nothing to save")
    }

    @Test
    func followsTheDiskWhileUnedited() throws {
        let url = try file("one\n")
        let model = FileEditorModel(url: url, path: "a.swift")
        let generation = model.generation
        try Data("one\nfrom agent\n".utf8).write(to: url)
        model.diskDidChange()
        #expect(model.text == "one\nfrom agent\n")
        #expect(model.generation == generation + 1 && model.diskChange == nil)
    }

    @Test
    func neverSavesOverAnUnseenChange() throws {
        let url = try file("one\n")
        let model = FileEditorModel(url: url, path: "a.swift")
        model.textDidChange("mine\n")
        try Data("theirs\n".utf8).write(to: url)
        model.diskDidChange()
        #expect(model.diskChange == .modified && model.text == "mine\n")

        #expect(!model.save())
        model.saveIfPossible()
        #expect(disk(url) == "theirs\n")

        model.keepMine()
        #expect(model.diskChange == nil && model.isDirty)
        #expect(model.save())
        #expect(disk(url) == "mine\n")
    }

    @Test
    func aSaveChecksTheDiskEvenWithoutAnEvent() throws {
        let url = try file("one\n")
        let model = FileEditorModel(url: url, path: "a.swift")
        model.textDidChange("mine\n")
        try Data("theirs\n".utf8).write(to: url)
        #expect(!model.save())
        #expect(model.diskChange == .modified && disk(url) == "theirs\n")

        model.reloadFromDisk()
        #expect(model.text == "theirs\n" && !model.isDirty && model.diskChange == nil)
    }

    @Test
    func aDeletedFile() throws {
        let url = try file("one\n")
        let model = FileEditorModel(url: url, path: "a.swift")
        model.textDidChange("mine\n")
        try FileManager.default.removeItem(at: url)
        model.diskDidChange()
        #expect(model.diskChange == .deleted)

        model.keepMine()
        #expect(model.save())
        #expect(disk(url) == "mine\n")

        try FileManager.default.removeItem(at: url)
        model.diskDidChange()
        #expect(model.phase == .unavailable("This file was deleted."), "with nothing unsaved, there is nothing to keep")
    }
}

struct WordIndexTests {
    @Test
    func findsTheWordAroundTheCursor() {
        let text = "let fooBar = baz_1" as NSString
        #expect(WordIndex.wordStart(in: text, before: 7) == 4)
        #expect(WordIndex.wordEnd(in: text, after: 7) == 10)
        #expect(WordIndex.wordStart(in: text, before: 18) == 13)
        #expect(WordIndex.wordStart(in: text, before: 4) == 4)
    }

    @Test
    func countsWordsOfThreeOrMore() {
        let counts = WordIndex.counts(in: "a ab abc abc _id 9lives émoji")
        #expect(counts == ["abc": 2, "_id": 1, "lives": 1, "émoji": 1])
    }

    @Test
    func ranksSameCaseThenUseThenLength() {
        let counts = ["Repository": 1, "repositoryURL": 5, "repository": 2, "rep": 9, "report": 1]
        #expect(WordIndex.ranked(counts, prefix: "repo") == ["repositoryURL", "repository", "report", "Repository"])
        #expect(WordIndex.ranked(counts, prefix: "rep", limit: 2) == ["repositoryURL", "repository"])
    }
}

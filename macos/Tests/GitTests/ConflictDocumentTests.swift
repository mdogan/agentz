import Foundation
import Testing
@testable import agentz

struct ConflictDocumentTests {
    @Test
    func resolvesStandardBlocksIndependently() throws {
        let source = "before\n<<<<<<< HEAD\nours one\n=======\ntheirs one\n"
            + ">>>>>>> incoming\nbetween\n<<<<<<< HEAD\nours two\n=======\n"
            + "theirs two\n>>>>>>> incoming\nafter\n"
        let document = ConflictDocument(source)

        #expect(document.conflicts.count == 2)
        #expect(document.conflicts[0].oursLabel == "HEAD")
        #expect(document.conflicts[0].theirsLabel == "incoming")
        #expect(document.conflicts[0].oursLines == ["ours one"])
        #expect(document.conflicts[0].theirsLines == ["theirs one"])
        #expect(!document.hasUnparsedMarkers)

        let afterSecond = try #require(
            document.resolving(
                blockID: document.conflicts[1].id,
                using: .theirs
            )
        )
        #expect(afterSecond.contains("<<<<<<< HEAD\nours one\n=======\ntheirs one"))
        #expect(afterSecond.contains("between\ntheirs two\nafter\n"))

        let remaining = ConflictDocument(afterSecond)
        #expect(remaining.conflicts.count == 1)
        let fullyResolved = try #require(
            remaining.resolving(
                blockID: remaining.conflicts[0].id,
                using: .ours
            )
        )
        #expect(fullyResolved == "before\nours one\nbetween\ntheirs two\nafter\n")
    }

    @Test
    func parsesDiff3WithCustomMarkerSizeAndRemovesTheBaseSection() throws {
        let source = "<<<<<<<<<< ours\nour value\n|||||||||| base\nbase value\n"
            + "==========\ntheir value\n>>>>>>>>>> theirs"
        let document = ConflictDocument(source)
        let block = try #require(document.conflicts.first)

        #expect(block.markerSize == 10)
        #expect(block.baseLabel == "base")
        #expect(block.baseLines == ["base value"])
        #expect(block.oursLines == ["our value"])
        #expect(block.theirsLines == ["their value"])
        #expect(
            document.resolving(blockID: block.id, using: .theirs)
                == "their value"
        )
    }

    @Test
    func flagsUnpairedMarkersSoTheFileWillNotBeAutoResolved() throws {
        let source = "<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n"
            + "ordinary content\n<<<<<<< dangling\n"
        let document = ConflictDocument(source)

        #expect(document.conflicts.count == 1)
        #expect(document.hasUnparsedMarkers)

        let resolved = try #require(
            document.resolving(
                blockID: document.conflicts[0].id,
                using: .ours
            )
        )
        let reparsed = ConflictDocument(resolved)
        #expect(reparsed.conflicts.isEmpty)
        #expect(reparsed.hasUnparsedMarkers)
        #expect(resolved.hasSuffix("<<<<<<< dangling\n"))
    }
}

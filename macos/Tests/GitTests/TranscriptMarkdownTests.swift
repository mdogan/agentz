import AppKit
import Testing
@testable import agentz

struct TranscriptMarkdownTests {
    let palette = TranscriptMarkdown.Palette(text: .textColor, accent: .linkColor, code: .systemPurple)

    @Test func rendersReviewTextWithNumberedFindingsLinksAndCode() throws {
        let document = TranscriptMarkdown("""
        ## Findings

        1. **Wrong path.** Update `src/config.h`. [Source](https://example.org/config)
           - *Nested* detail.
        2. Check the build.

        ```sh
        echo '**literal**'
          make check
        ```
        """, palette: palette)
        let text = document.text, string = text.string as NSString
        #expect(text.string == "Findings\n1.\tWrong path. Update src/config.h. Source\n•\tNested detail.\n2.\tCheck the build.\necho '**literal**'\n  make check")
        func attribute<T>(_ key: NSAttributedString.Key, at word: String, as type: T.Type) throws -> T {
            let range = string.range(of: word)
            try #require(range.location != NSNotFound)
            return try #require(text.attribute(key, at: range.location, effectiveRange: nil) as? T)
        }
        let heading = try attribute(.font, at: "Findings", as: NSFont.self)
        let bold = try attribute(.font, at: "Wrong path.", as: NSFont.self)
        let code = try attribute(.font, at: "src/config.h", as: NSFont.self)
        let nested = try attribute(.paragraphStyle, at: "Nested", as: NSParagraphStyle.self)
        let finding = try attribute(.paragraphStyle, at: "Wrong path.", as: NSParagraphStyle.self)
        let link = try attribute(.link, at: "Source", as: URL.self)
        #expect(heading.pointSize > bold.pointSize)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(code.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(nested.headIndent > finding.headIndent)
        #expect(link.absoluteString == "https://example.org/config")
    }

    @Test func tableRowsShareAColumnLayout() throws {
        let text = TranscriptMarkdown("| Suite | Time |\n| --- | --- |\n| Build | 3s |", palette: palette).text
        func cell(_ label: String) throws -> NSTextTableBlock {
            let range = (text.string as NSString).range(of: label)
            try #require(range.location != NSNotFound)
            let style = try #require(text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            return try #require(style.textBlocks.first as? NSTextTableBlock)
        }
        let header = try cell("Time"), value = try cell("3s")
        #expect(header.table === value.table)
        #expect(header.table.numberOfColumns == 2)
        #expect(header.startingRow == 0 && value.startingRow == 1)
        #expect(header.startingColumn == 1 && value.startingColumn == 1)
    }

    @Test func separatesGeneratedSourcesAndKeepsLiteralExamples() {
        let footer = """
        <oai-mem-citation>
        <citation_entries>
        MEMORY.md:10-12|note=[build procedure]
        </citation_entries>
        <rollout_ids>
        example-id
        </rollout_ids>
        </oai-mem-citation>
        """
        for separator in ["\n", "\n\n"] {
            let reply = TranscriptMarkdown("Done." + separator + footer, palette: palette, assistant: true)
            #expect(reply.text.string == "Done.")
            #expect(reply.sources == ["MEMORY.md:10-12 — build procedure"])
        }
        for input in ["```xml\n" + footer + "\n```", String(footer.dropLast(20))] {
            let literal = TranscriptMarkdown(input, palette: palette, assistant: true)
            #expect(literal.sources.isEmpty)
            #expect(literal.text.string.contains("<oai-mem-citation>"))
        }
        #expect(TranscriptMarkdown(footer, palette: palette).text.string.contains("<citation_entries>"))
    }
}

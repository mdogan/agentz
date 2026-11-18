import AppKit
import SwiftUI

/// Read-only conversation text. Foundation parses Markdown and TextKit lays out
/// the entire message so selections can span paragraphs and list items.
struct TranscriptMarkdown {
    struct Palette: Equatable {
        let text: NSColor
        let accent: NSColor
        let code: NSColor
    }

    let text: NSAttributedString
    private(set) var sources: [String] = []

    init(_ source: String, palette: Palette, assistant: Bool = false) {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 14)
        let base: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: palette.text]
        guard var parsed = try? AttributedString(markdown: source), !parsed.characters.isEmpty else {
            text = NSAttributedString(string: source, attributes: base)
            return
        }

        // Without a blank line before the footer, Markdown makes the tags
        // inline HTML in the preceding paragraph. Keep code examples literal.
        var inlineFooter: [String] = []
        if assistant, parsed.runs.last?.inlinePresentationIntent == .inlineHTML,
           let tag = source.range(of: "\n<oai-mem-citation>", options: .backwards),
           let entries = Self.memoryEntries(String(source[tag.lowerBound...])),
           let body = try? AttributedString(markdown: String(source[..<tag.lowerBound])) {
            inlineFooter = entries
            parsed = body
        }
        var seenItems = Set<Int>()
        var tables: [Int: NSTextTable] = [:]
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let content = parsed[range]
            if assistant, intent == nil, content.runs.first?.inlinePresentationIntent?.contains(.blockHTML) == true,
               let entries = Self.memoryEntries(String(content.characters)) {
                sources += entries
                continue
            }

            let style = BlockStyle(intent, palette: palette, seenItems: &seenItems, tables: &tables)
            if !style.marker.isEmpty {
                result.append(NSAttributedString(string: style.marker + "\t", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: style.size, weight: .semibold),
                    .foregroundColor: palette.accent, .paragraphStyle: style.paragraph,
                ]))
            }
            for run in content.runs {
                let attributes = style.attributes(inline: run.inlinePresentationIntent ?? [], link: run.link, palette: palette)
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            // Foundation includes the final newline of a fenced block in its contents.
            if content.characters.last != "\n" {
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style.paragraph, .font: baseFont]))
            }
        }
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        sources += inlineFooter
        text = result
    }

    private struct BlockStyle {
        let paragraph = NSMutableParagraphStyle()
        var size: CGFloat = 14
        var weight = NSFont.Weight.regular
        var blockCode = false
        var marker = ""
        var color: NSColor

        init(_ intent: PresentationIntent?, palette: Palette, seenItems: inout Set<Int>, tables: inout [Int: NSTextTable]) {
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 9
            var ordered = false
            var indent: CGFloat = 0
            var table: NSTextTable?
            var tableRow = 0
            color = palette.text

            for part in (intent?.components ?? []).reversed() {
                switch part.kind {
                case .orderedList: ordered = true
                case .unorderedList: ordered = false
                case let .listItem(ordinal):
                    indent += 26
                    marker = seenItems.insert(part.identity).inserted ? (ordered ? "\(ordinal)." : "•") : ""
                    paragraph.paragraphSpacing = 6
                case .blockQuote:
                    indent += 16
                    color = palette.text.withAlphaComponent(0.78)
                case let .header(level):
                    size = NoteLiveStyle.headingSizes[level - 1]
                    weight = .semibold
                    paragraph.paragraphSpacingBefore = 5
                case .codeBlock:
                    blockCode = true
                    indent += 10
                    paragraph.lineSpacing = 2
                    paragraph.paragraphSpacing = 0
                case .thematicBreak: color = palette.text.withAlphaComponent(0.35)
                case let .table(columns):
                    let grid = tables[part.identity] ?? NSTextTable()
                    grid.numberOfColumns = columns.count
                    grid.collapsesBorders = true
                    tables[part.identity] = grid
                    table = grid
                case .tableHeaderRow: weight = .semibold
                case let .tableRow(rowIndex): tableRow = rowIndex
                case let .tableCell(columnIndex):
                    if let table {
                        let cell = NSTextTableBlock(table: table, startingRow: tableRow, rowSpan: 1,
                                                    startingColumn: columnIndex, columnSpan: 1)
                        cell.setWidth(5, type: .absoluteValueType, for: .padding)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(palette.text.withAlphaComponent(0.18))
                        if tableRow == 0 { cell.backgroundColor = palette.text.withAlphaComponent(0.06) }
                        paragraph.textBlocks = [cell]
                        paragraph.paragraphSpacing = 0
                    }
                default: break
                }
            }

            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = marker.isEmpty ? indent : max(0, indent - 26)
            if !marker.isEmpty {
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
        }

        func attributes(inline: InlinePresentationIntent, link: URL?, palette: Palette) -> [NSAttributedString.Key: Any] {
            let code = blockCode || inline.contains(.code)
            let fontWeight = inline.contains(.stronglyEmphasized) ? .bold : weight
            var font = code ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: fontWeight) : NSFont.systemFont(ofSize: size, weight: fontWeight)
            if inline.contains(.emphasized) {
                let descriptor = font.fontDescriptor
                font = NSFont(descriptor: descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if code {
                attributes[.foregroundColor] = blockCode ? palette.text : palette.code
                attributes[.backgroundColor] = palette.text.withAlphaComponent(0.065)
            }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link, NoteLiveStyle.webURL(link.absoluteString) != nil {
                attributes[.link] = link
                attributes[.foregroundColor] = palette.accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return attributes
        }
    }

    /// Recognize a complete Codex metadata block. Quoted examples, code
    /// and incomplete markup remain part of the message.
    private static func memoryEntries(_ source: String) -> [String]? {
        let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "<oai-mem-citation>", lines.last == "</oai-mem-citation>",
              let start = lines.firstIndex(of: "<citation_entries>"), let end = lines.firstIndex(of: "</citation_entries>"),
              end > start + 1 else { return nil }
        return lines[(start + 1)..<end].map { line in
            guard let split = line.range(of: "|note=["), line.hasSuffix("]") else { return line }
            return String(line[..<split.lowerBound]) + " — " + String(line[split.upperBound...].dropLast())
        }
    }
}

struct TranscriptText: NSViewRepresentable {
    let text: NSAttributedString
    let linkColor: NSColor

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        // SwiftUI owns the view's frame, including during native text selection.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        view.linkTextAttributes = [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        if context.coordinator.text !== text {
            view.textStorage?.setAttributedString(text)
            context.coordinator.text = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator { var text: NSAttributedString? }
    func makeCoordinator() -> Coordinator { Coordinator() }
}

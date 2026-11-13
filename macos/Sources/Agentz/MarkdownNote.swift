import AppKit
import SwiftUI

/// Foundation parses Markdown; AppKit supplies selectable, native text.
/// No web view, scripts, or remote image loads are involved.
enum NoteMarkdown {
    static func render(_ source: String, color: NSColor = .textColor) -> NSAttributedString {
        guard let markdown = try? AttributedString(markdown: source) else {
            return NSAttributedString(string: source, attributes: [.foregroundColor: color])
        }
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var listedItems = Set<Int>()
        for run in markdown.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            var size: CGFloat = 13
            var bold = false
            var code = false
            var quote = false
            var ordinal: Int?
            var itemID: Int?
            var ordered = false
            var depth = 0
            var cell = false
            for component in components {
                switch component.kind {
                case let .header(level):
                    size = [24, 20, 17, 15, 14, 13][min(max(level, 1), 6) - 1]
                    bold = true
                case .codeBlock: code = true
                case .blockQuote: quote = true
                case let .listItem(number): ordinal = number; itemID = component.identity
                case .orderedList:
                    if depth == 0 { ordered = true }
                    depth += 1
                case .unorderedList: depth += 1
                case .tableCell: cell = true
                case .tableHeaderRow: bold = true
                default: break
                }
            }
            if result.length > 0, block != previousBlock {
                result.append(NSAttributedString(string: cell ? "\t" : "\n\n"))
            }
            previousBlock = block
            let inline = run.inlinePresentationIntent ?? []
            code = code || inline.contains(.code)
            bold = bold || inline.contains(.stronglyEmphasized)
            var font = code ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: size)
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.headIndent = CGFloat(depth * 18 + (quote ? 16 : 0))
            paragraph.firstLineHeadIndent = max(0, paragraph.headIndent - (depth > 0 ? 14 : 0))
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: quote ? color.withAlphaComponent(0.7) : color,
                .paragraphStyle: paragraph,
            ]
            if code { attributes[.backgroundColor] = color.withAlphaComponent(0.07) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
            }
            if let itemID, listedItems.insert(itemID).inserted {
                result.append(NSAttributedString(string: ordered ? "\(ordinal ?? 1). " : "• ", attributes: attributes))
            }
            result.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
        }
        return result
    }
}

@MainActor
final class NoteFormatting {
    var apply: ((String, String) -> Void)?
    func insert(_ prefix: String, _ suffix: String = "") {
        apply?(prefix, suffix)
    }
}

/// Plain text editing preserves Markdown exactly, including pasted code.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    let formatting: NoteFormatting
    let look: Look
    let readOnly: Bool
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteSourceTextView.scrollableTextView()
        let editor = scroll.documentView as! NoteSourceTextView
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 12, height: 10)
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.delegate = context.coordinator
        editor.onFocus = onFocus
        editor.setAccessibilityLabel("Markdown note")
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = scroll.documentView as! NoteSourceTextView
        editor.onFocus = onFocus
        formatting.apply = { [weak editor] prefix, suffix in editor?.wrapSelection(prefix, suffix) }
        editor.isEditable = !readOnly
        editor.drawsBackground = false
        editor.textColor = NSColor(look.text)
        editor.insertionPointColor = NSColor(look.text)
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        init(_ parent: NoteTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

final class NoteSourceTextView: NSTextView {
    var onFocus: () -> Void = {}
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        return accepted
    }

    func wrapSelection(_ prefix: String, _ suffix: String) {
        guard isEditable else { return }
        let selection = selectedRange()
        let selected = (string as NSString).substring(with: selection)
        window?.makeFirstResponder(self)
        insertText(prefix + selected + suffix, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + (prefix as NSString).length, length: selection.length))
    }
}

struct NotePreview: NSViewRepresentable {
    let text: String
    let look: Look

    func makeNSView(context _: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.setAccessibilityLabel("Markdown preview")
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context _: Context) {
        let view = scroll.documentView as! NSTextView
        view.textStorage?.setAttributedString(NoteMarkdown.render(text, color: NSColor(look.text)))
        view.linkTextAttributes = [.foregroundColor: NSColor(look.accent), .underlineStyle: NSUnderlineStyle.single.rawValue]
    }
}

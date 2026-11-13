import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// A web or mail link in a note. Kept apart from `.link`, which an
    /// editable text view would follow on a plain click.
    static let noteLink = NSAttributedString.Key("agentz.noteLink")
}

/// Live Markdown styling for a note, drawn over its plain source. Only
/// attributes change; the characters stay the Markdown the user typed, so
/// saving, undo and export see exactly that text.
///
/// Lines outside `active` look rendered: headings are large, `**bold**`
/// is bold, and the Markdown marks themselves are hidden. Lines that hold
/// the cursor or selection show their marks in a faint color for editing.
enum NoteLiveStyle {
    struct Palette {
        var text: NSColor
        var faint: NSColor
        var accent: NSColor
        static let standard = Palette(text: .textColor, faint: .tertiaryLabelColor, accent: .linkColor)
    }

    static let bodySize: CGFloat = 13
    static let codeSize: CGFloat = 12
    static let headingSizes: [CGFloat] = [22, 18, 16, 14, 13, 13]

    /// The attributes text typed at the cursor gets before it is styled.
    static func baseAttributes(_ palette: Palette) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: palette.text, .paragraphStyle: paragraph()]
    }

    static func apply(to text: NSMutableAttributedString, active: NSRange?, palette: Palette = .standard) {
        let source = text.string as NSString
        let all = NSRange(location: 0, length: source.length)
        text.beginEditing()
        defer { text.endEditing() }
        text.setAttributes(baseAttributes(palette), range: all)
        var fence: String?
        source.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let shown = isActive(line, active)
            let content = source.substring(with: line)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            let opensFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if fence != nil || opensFence {
                let mono = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
                text.addAttributes([.font: mono, .backgroundColor: palette.text.withAlphaComponent(0.06)], range: line)
                if opensFence {
                    text.addAttribute(.foregroundColor, value: palette.faint, range: line)
                    let marker = String(trimmed.prefix(3))
                    if fence == nil { fence = marker } else if fence == marker { fence = nil }
                }
                return
            }
            styleBlock(text, line: line, content: content, shown: shown, palette: palette)
            styleInline(text, line: line, shown: shown, palette: palette)
        }
    }

    private static func isActive(_ line: NSRange, _ active: NSRange?) -> Bool {
        guard let active else { return false }
        if active.length == 0 {
            return active.location >= line.location && active.location <= NSMaxRange(line)
        }
        return NSIntersectionRange(line, active).length > 0
            || (line.length == 0 && line.location >= active.location && line.location < NSMaxRange(active))
    }

    private static func paragraph(indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 2
        style.headIndent = indent
        return style
    }

    // MARK: Blocks

    private static let heading = regex(#"^(#{1,6})[ \t]+"#)
    private static let task = regex(#"^([ \t]*)([-*+])[ \t]+\[([ xX])\][ \t]+"#)
    private static let bullet = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+"#)
    private static let quote = regex(#"^[ \t]*>[ \t]?"#)
    private static let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)

    private static func styleBlock(_ text: NSMutableAttributedString, line: NSRange, content: String,
                                   shown: Bool, palette: Palette) {
        let local = NSRange(location: 0, length: (content as NSString).length)
        func shift(_ range: NSRange) -> NSRange { NSRange(location: line.location + range.location, length: range.length) }
        if let match = heading.firstMatch(in: content, range: local) {
            let level = match.range(at: 1).length
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: headingSizes[level - 1], weight: .bold), range: line)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacingBefore = level <= 2 ? 6 : 3
            style.paragraphSpacing = 2
            text.addAttribute(.paragraphStyle, value: style, range: line)
            mark(text, shift(match.range), shown: shown, palette: palette)
        } else if let match = task.firstMatch(in: content, range: local) {
            let done = (content as NSString).substring(with: match.range(at: 3)) != " "
            hang(text, line: line, prefix: match.range, content: content)
            text.addAttribute(.foregroundColor, value: palette.accent, range: shift(match.range(at: 3)).insetBy(-1))
            text.addAttribute(.foregroundColor, value: palette.faint, range: shift(match.range(at: 2)))
            if done {
                let rest = NSRange(location: NSMaxRange(match.range), length: local.length - NSMaxRange(match.range))
                text.addAttributes([.foregroundColor: palette.faint, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                                   range: shift(rest))
            }
        } else if let match = bullet.firstMatch(in: content, range: local) {
            hang(text, line: line, prefix: match.range, content: content)
            text.addAttribute(.foregroundColor, value: palette.accent, range: shift(match.range(at: 2)))
        } else if let match = quote.firstMatch(in: content, range: local) {
            text.addAttribute(.foregroundColor, value: palette.text.withAlphaComponent(0.65), range: line)
            text.addAttribute(.foregroundColor, value: palette.accent.withAlphaComponent(0.6), range: shift(match.range))
            hang(text, line: line, prefix: match.range, content: content)
        } else if rule.firstMatch(in: content, range: local) != nil {
            text.addAttribute(.foregroundColor, value: palette.faint, range: line)
        }
    }

    /// Wrapped lines of a list item or quote start under its text, not under its marker.
    private static func hang(_ text: NSMutableAttributedString, line: NSRange, prefix: NSRange, content: String) {
        let marker = (content as NSString).substring(with: prefix)
        let width = (marker as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: bodySize)]).width
        text.addAttribute(.paragraphStyle, value: paragraph(indent: width), range: line)
    }

    // MARK: Inline

    private static let code = regex(#"(`+)([^`\n]+?)\1"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let bare = regex(#"(?<![(\[<])\b(https?://[^\s<>()\]]+[^\s<>()\].,;:!?'"])"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*\w])"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)

    private static func styleInline(_ text: NSMutableAttributedString, line: NSRange, shown: Bool, palette: Palette) {
        let source = text.string
        var taken: [NSRange] = []
        func free(_ range: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, range).length > 0 } }

        for match in code.matches(in: source, range: line) {
            let mono = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
            text.addAttributes([.font: mono, .backgroundColor: palette.text.withAlphaComponent(0.07)], range: match.range(at: 2))
            let open = match.range(at: 1)
            mark(text, open, shown: shown, palette: palette)
            mark(text, NSRange(location: NSMaxRange(match.range) - open.length, length: open.length), shown: shown, palette: palette)
            taken.append(match.range)
        }
        for match in link.matches(in: source, range: line) where free(match.range) {
            let label = match.range(at: 1)
            let target = (source as NSString).substring(with: match.range(at: 2))
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: palette.accent]
            if let url = webURL(target) {
                attributes[.noteLink] = url
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.toolTip] = "⌘-click to open \(target)"
            }
            text.addAttributes(attributes, range: label)
            mark(text, NSRange(location: match.range.location, length: 1), shown: shown, palette: palette)
            mark(text, NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)),
                 shown: shown, palette: palette)
            taken.append(match.range)
        }
        for match in bare.matches(in: source, range: line) where free(match.range) {
            guard let url = webURL((source as NSString).substring(with: match.range)) else { continue }
            text.addAttributes([.foregroundColor: palette.accent, .noteLink: url, .toolTip: "⌘-click to open",
                                .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            taken.append(match.range)
        }
        for (pattern, trait) in [(bold, NSFontTraitMask.boldFontMask), (italic, .italicFontMask)] {
            for match in pattern.matches(in: source, range: line) where free(match.range) {
                addTrait(trait, to: text, in: match.range(at: 2))
                wrapMarks(text, match, shown: shown, palette: palette)
            }
        }
        for match in strike.matches(in: source, range: line) where free(match.range) {
            text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 2))
            wrapMarks(text, match, shown: shown, palette: palette)
        }
    }

    private static func wrapMarks(_ text: NSMutableAttributedString, _ match: NSTextCheckingResult, shown: Bool, palette: Palette) {
        let open = match.range(at: 1)
        mark(text, open, shown: shown, palette: palette)
        mark(text, NSRange(location: NSMaxRange(match.range) - open.length, length: open.length), shown: shown, palette: palette)
    }

    private static func addTrait(_ trait: NSFontTraitMask, to text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
        }
    }

    /// A Markdown mark: faint while its line is being edited, else hidden.
    private static func mark(_ text: NSMutableAttributedString, _ range: NSRange, shown: Bool, palette: Palette) {
        guard range.length > 0 else { return }
        if shown {
            text.addAttribute(.foregroundColor, value: palette.faint, range: range)
        } else {
            text.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: range)
        }
    }

    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

private extension NSRange {
    func insetBy(_ amount: Int) -> NSRange { NSRange(location: location - amount, length: length + 2 * amount) }
}

@MainActor
final class NoteFormatting {
    var apply: ((String, String) -> Void)?
    func insert(_ prefix: String, _ suffix: String = "") {
        apply?(prefix, suffix)
    }
}

/// Edits the note's Markdown source while showing it styled, see `NoteLiveStyle`.
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
        editor.textContainerInset = NSSize(width: 14, height: 12)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Markdown note")
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = scroll.documentView as! NoteSourceTextView
        editor.onFocus = onFocus
        editor.onFocusChange = { [weak coordinator = context.coordinator, weak editor] in
            if let editor { coordinator?.restyle(editor, force: true) }
        }
        formatting.apply = { [weak editor] prefix, suffix in editor?.wrapSelection(prefix, suffix) }
        editor.isEditable = !readOnly
        editor.drawsBackground = false
        editor.insertionPointColor = NSColor(look.text)
        editor.linkTextAttributes = [:]
        let palette = NoteLiveStyle.Palette(text: NSColor(look.text), faint: NSColor(look.faint), accent: NSColor(look.accent))
        let changedLook = context.coordinator.palette.map { !($0.text == palette.text && $0.accent == palette.accent) } ?? true
        context.coordinator.palette = palette
        editor.typingAttributes = NoteLiveStyle.baseAttributes(palette)
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
            context.coordinator.restyle(editor, force: true)
        } else if changedLook {
            context.coordinator.restyle(editor, force: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        var palette: NoteLiveStyle.Palette?
        /// The lines last shown as source, to skip restyling when the
        /// cursor moves within them.
        private var shownLines: NSRange?

        init(_ parent: NoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            restyle(editor, force: true)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            restyle(editor, force: false)
        }

        func restyle(_ editor: NSTextView, force: Bool) {
            guard let storage = editor.textStorage, let palette, !editor.hasMarkedText() else { return }
            let editing = editor.isEditable && editor.window?.firstResponder === editor
            let selection = editor.selectedRange()
            let lines = editing ? (editor.string as NSString).lineRange(for: selection) : nil
            guard force || lines != shownLines else { return }
            shownLines = lines
            NoteLiveStyle.apply(to: storage, active: editing ? selection : nil, palette: palette)
            editor.typingAttributes = NoteLiveStyle.baseAttributes(palette)
        }
    }
}

final class NoteSourceTextView: NSTextView {
    var onFocus: () -> Void = {}
    var onFocusChange: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus(); DispatchQueue.main.async { [weak self] in self?.onFocusChange() } }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocusChange() } }
        return accepted
    }

    /// ⌘-click opens a link; a plain click places the cursor to edit it.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = link(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if event.modifierFlags.contains(.command), link(at: event) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    private func link(at event: NSEvent) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for i in [index, index - 1] where i >= 0 && i < storage.length {
            if let url = storage.attribute(.noteLink, at: i, effectiveRange: nil) as? URL { return url }
        }
        return nil
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

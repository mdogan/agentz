import AppKit

/// Ghostty's find bar, at the top right of a terminal: a field for the
/// text, buttons for the next and previous match, and one that closes it.
/// It only says what the user does; Ghostty searches the screen and the
/// scrollback, highlights the matches and scrolls to the picked one.
///
/// It lies inside the terminal's view, so it moves, hides and comes back
/// with it.
final class FindBar: NSView, NSTextFieldDelegate {
    /// The text to find. Empty stops the search.
    var onSearch: ((String) -> Void)?
    /// To the next match up. Ghostty starts at the newest match, at the
    /// bottom, and goes on to older ones.
    var onNext: (() -> Void)?
    /// To the previous match, down.
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    /// The field got the keyboard, e.g. from a click.
    var onFocus: (() -> Void)?

    private let field = FindField(string: "")
    /// Text that waits a moment before it is searched for.
    private var waiting: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        field.placeholderString = "Find"
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.onFocus = { [weak self] in self?.onFocus?() }
        let stack = NSStackView(views: [
            field,
            button("chevron.up", "Next Match", "Next match, up (↩ or ⌘G)", #selector(next)),
            button("chevron.down", "Previous Match", "Previous match, down (⇧↩ or ⇧⌘G)", #selector(previous)),
            button("xmark", "Close", "Close (⎋)", #selector(close)),
        ])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    var text: String {
        field.stringValue
    }

    /// The field or its editor has the keyboard.
    var hasKeyboard: Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
    }

    /// Gives the field the keyboard, with all its text selected, so typing
    /// replaces it.
    func focus() {
        window?.makeFirstResponder(field)
    }

    /// Searches right away for text that waits, e.g. before going to the
    /// next match.
    func searchNow() {
        guard let text = waiting else { return }
        waiting = nil
        onSearch?(text)
    }

    @objc private func next() { onNext?() }
    @objc private func previous() { onPrevious?() }

    @objc private func close() {
        waiting = nil
        onClose?()
    }

    private func button(_ symbol: String, _ label: String, _ help: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    // MARK: - Look

    // The window takes the theme's light or dark appearance, and these
    // colors follow it.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.borderColor = NSColor.separatorColor.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 8
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Mouse

    // Clicks between the controls stay here: the terminal under the bar
    // would take them as its own.
    override func mouseDown(with _: NSEvent) {}
    override func rightMouseDown(with _: NSEvent) {}
    override func otherMouseDown(with _: NSEvent) {}

    // The terminal's text cursor is everywhere else. The field sets its own.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_: Notification) {
        let text = field.stringValue
        // Like Ghostty: one or two letters match almost everywhere, so they
        // wait a moment for more.
        guard !text.isEmpty, text.count < 3 else {
            waiting = nil
            onSearch?(text)
            return
        }
        waiting = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.waiting == text else { return }
                self.searchNow()
            }
        }
    }

    /// ↩ and ↑ go to the next match, ⇧↩ and ↓ to the previous one, and ⎋
    /// closes the bar.
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { next() }
        case #selector(NSResponder.moveUp(_:)):
            next()
        case #selector(NSResponder.moveDown(_:)):
            previous()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }
}

/// The find bar's field, which says when it gets the keyboard, so the
/// pane it is in becomes the one the user works in.
private final class FindField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

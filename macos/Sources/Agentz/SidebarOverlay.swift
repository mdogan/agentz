import AppKit

/// The session list in auto-hide mode (View › Auto-Hide Session List). The
/// list leaves the split, so the terminal has the whole window, and slides
/// in over the terminal's left side when wanted. The terminal keeps its
/// size, so the program in it is not resized each time.
///
/// - Resting the mouse at the window's left edge shows it. It hides again
///   once the mouse has been off it for a moment, unless its filter is
///   being typed in.
/// - Shown from the keyboard (⌘L, ⌘F, ⌃⌘S), it is held: it stays until the
///   terminal gets the focus.
/// - A click outside it hides it.
@MainActor
final class SidebarOverlay {
    /// Holds the list, at the left of the pane area.
    let panel = OverlayPanel()
    /// A thin strip along the window's left edge, under the panel.
    private let edge = EdgeStrip()
    private(set) var isShown = false
    /// Shown from the keyboard, or its filter was typed in: the mouse
    /// leaving does not hide it.
    private(set) var held = false
    /// Where the mouse is, in the panel's superview. The smoke test stands
    /// in for the mouse with it.
    var mouseLocation: () -> NSPoint? = { nil }
    /// Called as it hides, with true if the keyboard focus was in the list.
    var onHide: ((_ hadFocus: Bool) -> Void)?
    private var showTimer: Timer?
    private var watchTimer: Timer?
    /// Since when the mouse is off the shown list.
    private var offSince: Date?
    private var clickMonitor: Any?
    /// Counts the slides, so a slide out hides the panel only if no other
    /// slide started since.
    private var slides = 0

    /// How wide the strip at the edge is.
    private static let edgeWidth: CGFloat = 6
    /// How long the mouse rests at the edge before the list shows, so it
    /// does not show when the mouse only passes by.
    private static let showDelay: TimeInterval = 0.15
    /// How long the mouse is off the list before it hides.
    private static let hideDelay: TimeInterval = 0.4

    init() {
        mouseLocation = { [weak self] in
            guard let panel = self?.panel, let window = panel.window, let superview = panel.superview else { return nil }
            return superview.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        edge.onEnter = { [weak self] in self?.edgeEntered() }
        edge.onExit = { [weak self] in self?.showTimer?.invalidate() }
    }

    /// Puts `list` over the other subviews of `view`, hidden, `width` wide.
    func attach(_ list: NSView, width: CGFloat, to view: NSView) {
        panel.hold(list)
        panel.frame = NSRect(x: hiddenX(width), y: 0, width: width, height: view.bounds.height)
        panel.autoresizingMask = [.height]
        panel.isHidden = true
        edge.frame = NSRect(x: 0, y: 0, width: Self.edgeWidth, height: view.bounds.height)
        edge.autoresizingMask = [.height]
        view.addSubview(edge)
        view.addSubview(panel)
        // A click outside the list hides it. The click still goes where it
        // was meant to.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.clicked(event)
            return event
        }
    }

    /// Takes the panel and the strip out again, at once. The list stays in
    /// the panel until it is put somewhere else.
    func detach() {
        showTimer?.invalidate()
        watchTimer?.invalidate()
        isShown = false
        held = false
        slides += 1
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        edge.removeFromSuperview()
        panel.removeFromSuperview()
    }

    /// Slides the list in. `held` keeps it when the mouse leaves.
    func show(held: Bool) {
        showTimer?.invalidate()
        if held { self.held = true }
        guard !isShown, panel.superview != nil else { return }
        isShown = true
        offSince = nil
        slide(in: true)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchMouse() }
        }
    }

    /// Slides the list out.
    func hide() {
        showTimer?.invalidate()
        guard isShown else { return }
        let hadFocus = hasFocus
        isShown = false
        held = false
        watchTimer?.invalidate()
        watchTimer = nil
        slide(in: false)
        onHide?(hadFocus)
    }

    /// True if the keyboard focus is in the list.
    var hasFocus: Bool {
        (panel.window?.firstResponder as? NSView)?.isDescendant(of: panel) == true
    }

    /// True while the filter is typed in.
    var editingFilter: Bool {
        hasFocus && panel.window?.firstResponder is NSText
    }

    /// The mouse came to the window's left edge.
    func edgeEntered() {
        showTimer?.invalidate()
        guard !isShown else { return }
        showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showFromEdge() }
        }
    }

    private func showFromEdge() {
        // Not while resizing the window or selecting text in the terminal.
        guard let window = panel.window, !window.inLiveResize, NSEvent.pressedMouseButtons == 0,
              let point = mouseLocation(), edge.frame.contains(point)
        else { return }
        show(held: false)
    }

    /// While shown by the mouse: hides once the mouse has been off the list
    /// for a moment. A sheet from the list keeps it, and typing in its
    /// filter holds it.
    private func watchMouse() {
        guard isShown, !held, let window = panel.window else { return }
        if window.attachedSheet != nil || mouseLocation().map(shownFrame.contains) == true {
            offSince = nil
            return
        }
        let now = Date()
        guard let offSince else {
            self.offSince = now
            return
        }
        guard now.timeIntervalSince(offSince) >= Self.hideDelay else { return }
        if editingFilter {
            held = true
        } else {
            hide()
        }
    }

    private func clicked(_ event: NSEvent) {
        guard isShown, let superview = panel.superview, event.window === panel.window else { return }
        if !shownFrame.contains(superview.convert(event.locationInWindow, from: nil)) { hide() }
    }

    /// Where the panel is while shown, also while it slides.
    private var shownFrame: NSRect {
        NSRect(x: 0, y: 0, width: panel.frame.width, height: panel.frame.height)
    }

    /// Left of the window, with room for the shadow.
    private func hiddenX(_ width: CGFloat) -> CGFloat {
        -(width + OverlayPanel.shadowRadius * 2)
    }

    private func slide(in show: Bool) {
        slides += 1
        let slide = slides
        panel.isHidden = false
        let x = show ? 0 : hiddenX(panel.frame.width)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            panel.animator().setFrameOrigin(NSPoint(x: x, y: 0))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !show, self.slides == slide else { return }
                self.panel.isHidden = true
            }
        }
    }
}

/// The box the list sits in while it is over the terminal, with a line and
/// a shadow on its right.
final class OverlayPanel: NSView {
    static let shadowRadius: CGFloat = 12

    var lineColor = NSColor.separatorColor {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = Self.shadowRadius
        layer?.shadowOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Fills the panel with `list`, but for the line.
    func hold(_ list: NSView) {
        list.translatesAutoresizingMaskIntoConstraints = true
        list.frame = NSRect(x: 0, y: 0, width: max(bounds.width - 1, 0), height: bounds.height)
        list.autoresizingMask = [.width, .height]
        addSubview(list)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    override func draw(_: NSRect) {
        lineColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    // The terminal under the panel sets its own cursor too.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// Tells when the mouse comes to the window's left edge. Clicks go through
/// to the terminal.
private final class EdgeStrip: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with _: NSEvent) { onEnter?() }
    override func mouseExited(with _: NSEvent) { onExit?() }
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

import AppKit
import SwiftUI

extension View {
    /// A tooltip that appears the moment the pointer arrives, for icon-only and
    /// compact controls whose meaning is otherwise invisible.
    ///
    /// AppKit waits roughly a second before showing `help(_:)` tooltips and that
    /// delay has no public setting, so unlabeled toolbar icons stay unexplained
    /// exactly while the pointer is asking. This keeps the same short text and
    /// the same native look, without the wait.
    func instantHelp(_ text: String) -> some View {
        modifier(InstantHelpModifier(text: text))
    }
}

private struct InstantHelpModifier: ViewModifier {
    let text: String
    @State private var owner = UUID()
    @State private var anchor = InstantTooltipAnchor()

    func body(content: Content) -> some View {
        content
            .background(
                InstantTooltipAnchorView(anchor: anchor)
                    .allowsHitTesting(false)
            )
            .onHover { isHovering in
                guard isHovering else {
                    InstantTooltipPresenter.shared.hide(owner: owner)
                    return
                }
                guard let window = anchor.window, let frame = anchor.screenFrame else {
                    return
                }
                InstantTooltipPresenter.shared.show(
                    text,
                    anchoredTo: frame,
                    in: window,
                    owner: owner
                )
            }
            .onDisappear {
                InstantTooltipPresenter.shared.hide(owner: owner)
            }
            .accessibilityHint(Text(text))
    }
}

/// Bridges the measured position of a SwiftUI view into screen coordinates.
/// Toolbar content lives in the title bar's own hosting view, so a window-space
/// overlay cannot reach it; the tooltip needs a real screen rectangle instead.
private final class InstantTooltipAnchor {
    weak var view: NSView?

    var window: NSWindow? { view?.window }

    var screenFrame: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct InstantTooltipAnchorView: NSViewRepresentable {
    let anchor: InstantTooltipAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// Owns the single tooltip panel. One panel is reused so rapid moves along a
/// row of toolbar icons read as the label following the pointer.
@MainActor
private final class InstantTooltipPresenter {
    static let shared = InstantTooltipPresenter()

    private var panel: NSPanel?
    private var label: NSHostingView<InstantTooltipLabel>?
    private var owner: UUID?
    private var dismissalMonitor: Any?

    private init() {}

    func show(_ text: String, anchoredTo anchor: NSRect, in window: NSWindow, owner: UUID) {
        let panel: NSPanel
        let label: NSHostingView<InstantTooltipLabel>
        if let existingPanel = self.panel, let existingLabel = self.label {
            panel = existingPanel
            label = existingLabel
        } else {
            label = NSHostingView(rootView: InstantTooltipLabel(text: text))
            panel = makePanel()
            panel.contentView = label
            self.panel = panel
            self.label = label
        }
        self.owner = owner

        label.rootView = InstantTooltipLabel(text: text)
        panel.appearance = window.appearance
        panel.setContentSize(label.fittingSize)
        panel.setFrameOrigin(
            origin(for: panel.frame.size, anchoredTo: anchor, on: window.screen)
        )
        panel.invalidateShadow()

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        startMonitoringDismissal()
    }

    /// Only the control that presented the tooltip may take it down, so moving
    /// between neighboring controls never leaves the pointer without a label.
    func hide(owner: UUID) {
        guard self.owner == owner else { return }
        dismiss()
    }

    private func dismiss() {
        owner = nil
        if let dismissalMonitor {
            NSEvent.removeMonitor(dismissalMonitor)
            self.dismissalMonitor = nil
        }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// A click or a scroll means the pointer stopped asking what the control is,
    /// and a sheet or menu may be about to cover the panel.
    private func startMonitoringDismissal() {
        guard dismissalMonitor == nil else { return }
        dismissalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
            return event
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    /// Centered under the control, flipped above it when the screen runs out and
    /// nudged sideways so a tooltip near the window edge stays fully readable.
    private func origin(
        for size: NSSize,
        anchoredTo anchor: NSRect,
        on screen: NSScreen?
    ) -> NSPoint {
        let gap: CGFloat = 6
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - gap - size.height

        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + gap), max(visible.maxX - size.width - gap, visible.minX))
            if y < visible.minY + gap {
                y = anchor.maxY + gap
            }
        }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }
}

private struct InstantTooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

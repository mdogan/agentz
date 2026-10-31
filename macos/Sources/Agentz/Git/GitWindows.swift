import AppKit
import SwiftUI

/// The git views' own windows. GitFork opened them as SwiftUI scenes;
/// agentz is an AppKit app, so they are plain windows here.
@MainActor
enum GitWindows {
    private static var diffs: [UUID: NSWindowController] = [:]

    /// A file's diff with the old and new side by side, wider than the
    /// panel. One window per diff; showing the same diff again brings its
    /// window forward.
    static func openSideBySideDiff(_ state: SideBySideDiffWindowState) {
        if let open = diffs[state.id] {
            open.showWindow(nil)
            return
        }
        let host = NSHostingController(rootView: SideBySideDiffWindow(state: state).lookWindowStyle())
        let window = NSWindow(contentViewController: host)
        window.title = state.path
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        diffs[state.id] = controller
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = diffs.removeValue(forKey: state.id) }
        }
        controller.showWindow(nil)
    }

    static func closeSideBySideDiff(_ state: SideBySideDiffWindowState) {
        diffs[state.id]?.close()
    }

    private static var commandLog: NSWindowController?

    /// The git commands the panel ran, and how each went.
    static func openCommandLog() {
        if commandLog == nil {
            let host = NSHostingController(rootView: GitCommandLogView().lookWindowStyle())
            let window = NSWindow(contentViewController: host)
            window.title = "Git Command Log"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 620))
            window.isReleasedWhenClosed = false
            window.center()
            commandLog = NSWindowController(window: window)
        }
        commandLog?.showWindow(nil)
    }
}

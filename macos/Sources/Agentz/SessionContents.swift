// File › Save Session Contents and Copy Session Contents, also in a
// session's right-click menu.
//
// An agent's conversation comes from its transcript: on the alternate
// screen, where Claude's fullscreen mode and Codex draw, the terminal only
// has the rows that show. A shell gives its terminal's text, with the
// scrollback, and so does an agent that has not written its transcript yet.

import AgentzCore
import AppKit
import UniformTypeIdentifiers

@MainActor
struct SessionContents {
    var title: String
    var text: String
    /// Markdown from the transcript, not the terminal's text.
    var isConversation: Bool

    /// What the status line calls it.
    var what: String { isConversation ? "the conversation" : "the terminal's text" }

    /// The title, as a file name.
    var fileName: String {
        let name = String(title.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }.prefix(80))
            .trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Session" : name) + (isConversation ? ".md" : ".txt")
    }

    init(title: String, text: String, isConversation: Bool) {
        self.title = title
        self.text = text
        self.isConversation = isConversation
    }

    /// The terminal's text; nil when it has none.
    init?(title: String, terminal: Terminal) {
        guard let text = terminal.screenText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(title: title, text: text, isConversation: false)
    }

    /// Asks where, then writes the file. Says how it went in the status line.
    func save(in workspace: Workspace) {
        let panel = NSSavePanel()
        panel.title = "Save Session Contents"
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [isConversation ? UTType(filenameExtension: "md") ?? .plainText : .plainText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            workspace.setStatus("Saved \(what) to \(tilde(url.path)).")
        } catch {
            workspace.setStatus("Could not save to \(tilde(url.path)): \(error.localizedDescription)")
        }
    }

    func copy(in workspace: Workspace) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        workspace.setStatus("Copied \(what), \(lines) \(lines == 1 ? "line" : "lines").")
    }
}

extension Workspace {
    /// True if session `key` can have contents: an agent's session, or a
    /// shell with its terminal.
    func hasContents(_ key: SessionKey) -> Bool {
        switch key.agent {
        case .claude, .codex: true
        case .shell: tabs.contains { $0.shows(key) && $0.terminal != nil }
        case .git: false
        }
    }

    /// The contents of session `key`. When it has none, says why in the
    /// status line.
    func contents(of key: SessionKey) -> SessionContents? {
        let tab = tabs.first { $0.shows(key) }
        // A shell row stands for the agent running in it, if any.
        let agentKey = key.agent == .claude || key.agent == .codex ? key : tab?.linked
        if let agentKey {
            let title = rows.first { $0.key == agentKey }?.title
                ?? sessions.first { $0.key == agentKey }?.title
                ?? tab?.title ?? agentKey.agent.displayName
            if let markdown = transcriptMarkdown(agentKey.agent, agentKey.id) {
                return SessionContents(title: title, text: "# \(title)\n\n" + markdown, isConversation: true)
            }
            if let terminal = tab?.terminal, let contents = SessionContents(title: title, terminal: terminal) {
                return contents
            }
            setStatus("\(agentKey.agent.displayName) has not written this session's transcript yet.")
            return nil
        }
        if let tab, let terminal = tab.terminal, let contents = SessionContents(title: tab.title, terminal: terminal) {
            return contents
        }
        setStatus("The terminal has no text.")
        return nil
    }
}

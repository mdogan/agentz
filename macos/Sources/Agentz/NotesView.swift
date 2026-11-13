import AgentzCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorView: View {
    let notes: SessionNotes
    let id: UUID
    let look: Look
    var close: (() -> Void)?
    var onFocus: () -> Void = {}
    @State private var formatting = NoteFormatting()
    @State private var confirmDelete = false

    var body: some View {
        if let note = notes.note(id) {
            VStack(spacing: 0) {
                Rectangle().fill(look.divider).frame(height: 1)
                HStack(spacing: 4) {
                    Group {
                        tool("Bold", symbol: "bold") { formatting.insert("**", "**") }
                        tool("Italic", symbol: "italic") { formatting.insert("*", "*") }
                        tool("Link", symbol: "link") { formatting.insert("[", "](https://)") }
                        tool("Code", symbol: "chevron.left.forwardslash.chevron.right") { formatting.insert("`", "`") }
                    }
                    .disabled(notes.isReadOnly)
                    Spacer(minLength: 8)
                    tool("Export Markdown…", symbol: "square.and.arrow.up") { export(note) }
                    tool("Delete Note…", symbol: "trash") { confirmDelete = true }
                        .disabled(notes.isReadOnly)
                }
                .frame(height: 26)
                .padding(.horizontal, 10).padding(.vertical, 6)
                Rectangle().fill(look.divider).frame(height: 1)
                NoteTextEditor(text: Binding(get: { notes.note(id)?.text ?? "" }, set: { notes.update(id, text: $0) }),
                               formatting: formatting, look: look, readOnly: notes.isReadOnly, onFocus: onFocus)
                if let problem = notes.problem {
                    HStack {
                        Text(problem).font(.caption).foregroundStyle(look.red).textSelection(.enabled)
                        if !notes.isReadOnly { Button("Retry") { notes.flush() } }
                    }.padding(8)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: notes.isDirty ? "arrow.triangle.2.circlepath" : "checkmark")
                        Text(notes.isDirty ? "Saving…" : "Saved locally")
                        Spacer()
                        Text("⌘-click opens links")
                    }
                    .font(.system(size: 10.5)).foregroundStyle(look.faint)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .foregroundStyle(look.text).background(look.sidebar).tint(look.accent)
            .onDisappear { notes.flush() }
            .alert("Delete this note?", isPresented: $confirmDelete) {
                Button("Delete Note", role: .destructive) { notes.delete(id); close?() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The session and its conversation will be kept.") }
        }
    }

    private func export(_ note: SessionNote) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = String(note.title.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }.prefix(80)) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try note.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }

    private func tool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(look.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(GitForkHoverButtonStyle(.icon))
        .instantHelp(title)
        .accessibilityLabel(title)
    }
}

@MainActor
@Observable
final class NotesSelection {
    var id: UUID?
    var query = ""
}

struct AllNotesView: View {
    let workspace: Workspace
    let look: Look
    @Bindable var selection: NotesSelection
    let showSession: (SessionKey) -> Void
    @FocusState private var searchFocused: Bool

    private var notes: [SessionNote] {
        workspace.notes.notes.filter { $0.matches(selection.query) }.sorted { $0.updated > $1.updated }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search notes", text: $selection.query)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .lookField(isFocused: searchFocused, systemImage: "magnifyingglass")
                    .padding(10)
                List(selection: $selection.id) {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title).font(.headline).lineLimit(1)
                            Text(tilde(note.folder)).font(.caption).foregroundStyle(look.secondary).lineLimit(1)
                            Text(note.preview.isEmpty ? "Empty note" : note.preview).font(.caption).lineLimit(2)
                        }.padding(.vertical, 4).tag(note.id)
                    }
                }
                .scrollContentBackground(.hidden)
                Text("\(notes.count) notes").font(.system(size: 11)).foregroundStyle(look.secondary).padding(8)
            }
            .frame(minWidth: 210, idealWidth: 260, maxWidth: 380)
            if let id = selection.id, let note = workspace.notes.note(id) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(note.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                        Text("\(note.key?.agent.displayName ?? "Session") · \(tilde(note.folder))")
                            .font(.system(size: 11)).foregroundStyle(look.secondary).lineLimit(1).textSelection(.enabled)
                        if let key = note.key, workspace.hasNoteSession(key) {
                            Button("Show Session") { showSession(key) }
                        } else {
                            Text(workspace.allLoaded ? "Session unavailable · Your note is kept" : "Looking for session…")
                                .font(.caption).foregroundStyle(look.secondary)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                    NoteEditorView(notes: workspace.notes, id: id, look: look).id(id)
                }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "note.text").font(.largeTitle)
                    Text(workspace.notes.problem ?? (notes.isEmpty ? "Add a note from a session’s menu." : "Select a note"))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(look.secondary).padding(24)
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(look.text).background(look.sidebar).tint(look.accent)
        .onChange(of: selection.id) { old, _ in workspace.notes.finishEditing(old) }
    }
}

/// Escape follows the same save-and-close path as the window's close button,
/// including when the note editor has the focus.
private final class NotesWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           attachedSheet == nil, (firstResponder as? NSTextView)?.hasMarkedText() != true {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate {
    let selection = NotesSelection()
    private let notes: SessionNotes
    private let look: Look

    init(workspace: Workspace, look: Look, showSession: @escaping (SessionKey) -> Void) {
        notes = workspace.notes
        self.look = look
        let window = NotesWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "All Notes"
        let content = NSHostingController(rootView: AllNotesView(workspace: workspace, look: look, selection: selection, showSession: showSession))
        // This resizable window owns its size. SwiftUI's fitting size must
        // not shrink it as the selected note changes.
        content.sizingOptions = []
        window.contentViewController = content
        window.contentMinSize = NSSize(width: 600, height: 340)
        window.setContentSize(NSSize(width: 850, height: 560))
        window.setFrameAutosaveName("agentz.notes")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        restyle()
    }

    private func restyle() {
        withObservationTracking { [weak self] in
            if let self, let window { look.style(window) }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.restyle() }
        }
    }

    func show(_ id: UUID? = nil) {
        if let id { selection.query = ""; selection.id = id }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        notes.finishEditing(selection.id)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

/// The selected session's note, without the library list or a terminal resize.
private struct SingleNoteView: View {
    let notes: SessionNotes
    let look: Look
    let selection: NotesSelection
    let close: () -> Void

    var body: some View {
        if let id = selection.id, let note = notes.note(id) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(note.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                    Text("\(note.key?.agent.displayName ?? "Session") · \(tilde(note.folder))")
                        .font(.system(size: 11)).foregroundStyle(look.secondary).lineLimit(1).textSelection(.enabled)
                }.padding(.horizontal, 12).padding(.vertical, 10)
                NoteEditorView(notes: notes, id: id, look: look, close: close).id(id)
            }
            .foregroundStyle(look.text).background(look.sidebar).tint(look.accent)
        }
    }
}

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    private let notes: SessionNotes
    private let look: Look
    private let selection = NotesSelection()

    init(notes: SessionNotes, look: Look) {
        self.notes = notes
        self.look = look
        let window = NotesWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.identifier = NSUserInterfaceItemIdentifier("session-note-window")
        let content = NSHostingController(rootView: SingleNoteView(notes: notes, look: look, selection: selection) { [weak self] in self?.close() })
        content.sizingOptions = []
        window.contentViewController = content
        window.contentMinSize = NSSize(width: 400, height: 300)
        window.setContentSize(NSSize(width: 600, height: 480))
        window.setFrameAutosaveName("agentz.note")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        restyle()
    }

    private func restyle() {
        withObservationTracking { [weak self] in
            guard let self, let window else { return }
            look.style(window)
            window.title = selection.id.flatMap { self.notes.note($0)?.title }.map { "Note — \($0)" } ?? "Session Note"
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.restyle() }
        }
    }

    func show(_ id: UUID) {
        if selection.id != id { notes.finishEditing(selection.id); selection.id = id }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        notes.finishEditing(selection.id)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

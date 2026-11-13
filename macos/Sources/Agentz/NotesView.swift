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
    @State private var preview = false
    @State private var formatting = NoteFormatting()
    @State private var confirmDelete = false

    var body: some View {
        if let note = notes.note(id) {
            VStack(spacing: 0) {
                Rectangle().fill(look.divider).frame(height: 1)
                HStack(spacing: 10) {
                    Label("Notes", systemImage: "note.text").font(.system(size: 12, weight: .semibold))
                    Picker("Mode", selection: $preview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: preview) { NSApp.keyWindow?.makeFirstResponder(nil) }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Export Markdown…") { export(note) }
                        Button("Delete Note…", role: .destructive) { confirmDelete = true }
                            .disabled(notes.isReadOnly)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Note actions")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                if !preview {
                    HStack(spacing: 12) {
                        format("Bold", symbol: "bold", prefix: "**", suffix: "**")
                        format("Italic", symbol: "italic", prefix: "*", suffix: "*")
                        format("Link", symbol: "link", prefix: "[", suffix: "](https://)")
                        format("Code", symbol: "chevron.left.forwardslash.chevron.right", prefix: "`", suffix: "`")
                        Spacer()
                        Text("Markdown").font(.system(size: 10)).foregroundStyle(look.secondary)
                    }
                    .disabled(notes.isReadOnly)
                    .padding(.horizontal, 12).padding(.bottom, 5)
                }
                ZStack {
                    NoteTextEditor(text: Binding(get: { notes.note(id)?.text ?? "" }, set: { notes.update(id, text: $0) }),
                                   formatting: formatting, look: look, readOnly: notes.isReadOnly, onFocus: onFocus)
                        .opacity(preview ? 0 : 1)
                        .allowsHitTesting(!preview)
                        .accessibilityHidden(preview)
                    if preview { NotePreview(text: note.text, look: look) }
                }
                if let problem = notes.problem {
                    HStack {
                        Text(problem).font(.caption).foregroundStyle(look.red).textSelection(.enabled)
                        if !notes.isReadOnly { Button("Retry") { notes.flush() } }
                    }.padding(8)
                } else {
                    HStack {
                        Text(notes.isDirty ? "Saving…" : "Saved locally")
                        Spacer()
                    }
                    .font(.system(size: 10)).foregroundStyle(look.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 6)
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

    private func format(_ title: String, symbol: String, prefix: String, suffix: String) -> some View {
        Button { formatting.insert(prefix, suffix) } label: { Image(systemName: symbol) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func export(_ note: SessionNote) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = String(note.title.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }.prefix(80)) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try note.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
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

    private var notes: [SessionNote] {
        workspace.notes.notes.filter { $0.matches(selection.query) }.sorted { $0.updated > $1.updated }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search notes", text: $selection.query).textFieldStyle(.roundedBorder).padding(10)
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
                Text("\(notes.count) notes").font(.caption).foregroundStyle(look.secondary).padding(8)
            }
            .frame(minWidth: 210, idealWidth: 260, maxWidth: 380)
            if let id = selection.id, let note = workspace.notes.note(id) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(note.title).font(.headline).textSelection(.enabled)
                        Text("\(note.key?.agent.displayName ?? "Session") · \(tilde(note.folder))")
                            .font(.caption).foregroundStyle(look.secondary).textSelection(.enabled)
                        if let key = note.key, workspace.hasNoteSession(key) {
                            Button("Show Session") { showSession(key) }
                        } else {
                            Text(workspace.allLoaded ? "Session unavailable · Your note is kept" : "Looking for session…")
                                .font(.caption).foregroundStyle(look.secondary)
                        }
                    }.padding(12)
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
/// including when a native text editor or Markdown preview has the focus.
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
                    Text(note.title).font(.headline).textSelection(.enabled)
                    Text("\(note.key?.agent.displayName ?? "Session") · \(tilde(note.folder))")
                        .font(.caption).foregroundStyle(look.secondary).textSelection(.enabled)
                }.padding(12)
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

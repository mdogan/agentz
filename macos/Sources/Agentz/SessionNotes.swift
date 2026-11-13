import AgentzCore
import Foundation
import Observation

struct SessionNote: Codable, Identifiable, Equatable {
    let id: UUID
    var session: String
    var title: String
    var folder: String
    var text: String
    var updated: Date

    var key: SessionKey? { SessionKey(parsing: session) }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var preview: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)) }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [title, folder, session, text].contains { $0.localizedStandardContains(query) }
    }
}

/// Notes have their own lifetime. A missing transcript never deletes a note.
/// The entire small document is replaced atomically, including ID migrations.
@MainActor
@Observable
final class SessionNotes {
    private struct Document: Codable {
        var version = 1
        var notes: [SessionNote]
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agentz/notes.json")
    }

    private(set) var notes: [SessionNote] = []
    private(set) var problem: String?
    private(set) var isDirty = false
    private(set) var isReadOnly = false
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?

    /// A nil URL keeps notes in memory, for tests and the smoke app.
    init(url: URL? = nil) {
        self.url = url
        guard let url else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1,
                  Set(document.notes.map(\.id)).count == document.notes.count,
                  Set(document.notes.map(\.session)).count == document.notes.count
            else { throw CocoaError(.fileReadCorruptFile) }
            notes = document.notes.filter { !$0.isEmpty }
            if notes.count != document.notes.count { changed() }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // First launch; create the file only when a note is added.
        } catch {
            isReadOnly = true
            problem = "Could not read notes. The file has been left untouched: \(error.localizedDescription)"
        }
    }

    func note(for key: SessionKey) -> SessionNote? { notes.first { $0.session == key.description } }
    func note(_ id: UUID) -> SessionNote? { notes.first { $0.id == id } }

    @discardableResult
    func create(for key: SessionKey, title: String, folder: String) -> UUID? {
        if let note = note(for: key) { return note.id }
        guard !isReadOnly else { return nil }
        let note = SessionNote(id: UUID(), session: key.description, title: title, folder: folder, text: "", updated: Date())
        notes.append(note)
        changed()
        return note.id
    }

    func update(_ id: UUID, text: String) {
        guard !isReadOnly, let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        changed()
    }

    func delete(_ id: UUID) {
        guard !isReadOnly, notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        changed()
    }

    /// Keep empty drafts alive for typing and Undo until the editor closes
    /// or moves to a different note.
    func finishEditing(_ id: UUID?) {
        if let id, note(id)?.isEmpty == true { delete(id) }
        flush()
    }

    /// Keep the draft's identity, so an open editor and its undo stack follow
    /// a new Codex tab when its real thread ID becomes known. If that thread
    /// already has a note, preserve both texts in the resulting note.
    func rebind(from old: SessionKey, to new: SessionKey) {
        guard !isReadOnly, old != new, let draft = note(for: old),
              let index = notes.firstIndex(where: { $0.id == draft.id }) else { return }
        if let existing = note(for: new) {
            notes[index].text = [existing.text, draft.text].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n---\n\n")
            notes[index].title = existing.title
            notes[index].folder = existing.folder
            notes.removeAll { $0.id == existing.id }
        }
        // Removing a destination above may have changed the array index.
        if let index = notes.firstIndex(where: { $0.id == draft.id }) {
            notes[index].session = new.description
        }
        changed()
    }

    func refreshMetadata(_ sessions: [Session]) {
        guard !isReadOnly else { return }
        let metadata = Dictionary(sessions.map { ($0.key.description, $0) }, uniquingKeysWith: { first, _ in first })
        var updated = false
        for i in notes.indices {
            guard let session = metadata[notes[i].session],
                  notes[i].title != session.title || notes[i].folder != session.cwd else { continue }
            notes[i].title = session.title
            notes[i].folder = session.cwd
            updated = true
        }
        if updated { changed() }
    }

    private func changed() {
        isDirty = true
        onChange?()
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    /// A failed write keeps the in-memory draft and stays dirty for retry.
    @discardableResult
    func flush() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty else { return true }
        guard !isReadOnly else { return false }
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(Document(notes: notes.filter { !$0.isEmpty })).write(to: url, options: .atomic)
            }
            isDirty = false
            problem = nil
            return true
        } catch {
            problem = "Could not save notes: \(error.localizedDescription)"
            return false
        }
    }
}

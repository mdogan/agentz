import AgentzCore
import Foundation
import Observation

struct SessionNote: Identifiable, Equatable {
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
/// Each nonempty note is one Markdown file in the notes folder, with its
/// session and metadata in a front matter block, so other editors can read
/// it. Files are replaced atomically, one note at a time.
@MainActor
@Observable
final class SessionNotes {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agentz/notes", isDirectory: true)
    }

    private(set) var notes: [SessionNote] = []
    /// Why a file could not be read, or why the last save failed.
    var problem: String? { saveProblem ?? loadProblem }
    var isDirty: Bool { !dirty.isEmpty }
    private(set) var isReadOnly = false
    private var saveProblem: String?
    private var loadProblem: String?
    private var dirty: Set<UUID> = []
    @ObservationIgnored private let directory: URL?
    /// The file each saved note is in now, so a renamed title moves it.
    @ObservationIgnored private var files: [UUID: String] = [:]
    /// Older copies of a note left behind by an interrupted rename.
    @ObservationIgnored private var staleFiles: Set<String> = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?

    /// A nil directory keeps notes in memory, for tests and the smoke app.
    init(directory: URL? = nil) {
        self.directory = directory
        guard let directory else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            names = []  // First launch; create the folder only when a note is added.
        } catch {
            isReadOnly = true
            loadProblem = "Could not read notes. The folder has been left untouched: \(error.localizedDescription)"
            return
        }
        var unreadable: [String] = []
        for name in names.sorted() where name.hasSuffix(".md") && !name.hasPrefix(".") {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                  let note = NoteFile.parse(text)
            else { unreadable.append(name); continue }
            if note.isEmpty { continue }
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                // The same note twice: keep the newer copy, remove the other.
                if note.updated > notes[index].updated {
                    staleFiles.insert(files[note.id]!)
                    notes[index] = note
                    files[note.id] = name
                } else {
                    staleFiles.insert(name)
                }
            } else if let index = notes.firstIndex(where: { $0.session == note.session }) {
                // Two different notes for one session: show the newer one and
                // leave the other file alone.
                if note.updated > notes[index].updated {
                    unreadable.append(files[notes[index].id]!)
                    files[notes[index].id] = nil
                    notes[index] = note
                    files[note.id] = name
                } else {
                    unreadable.append(name)
                }
            } else {
                notes.append(note)
                files[note.id] = name
            }
        }
        if !unreadable.isEmpty {
            loadProblem = "Skipped \(unreadable.sorted().joined(separator: ", ")) in the notes folder. These files have been left untouched."
        }
        if !staleFiles.isEmpty { changed() }
    }

    func note(for key: SessionKey) -> SessionNote? { notes.first { $0.session == key.description } }
    func note(_ id: UUID) -> SessionNote? { notes.first { $0.id == id } }

    @discardableResult
    func create(for key: SessionKey, title: String, folder: String) -> UUID? {
        if let note = note(for: key) { return note.id }
        guard !isReadOnly else { return nil }
        let note = SessionNote(id: UUID(), session: key.description, title: title, folder: folder, text: "", updated: Date())
        notes.append(note)
        changed(note.id)
        return note.id
    }

    func update(_ id: UUID, text: String) {
        guard !isReadOnly, let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        changed(id)
    }

    func delete(_ id: UUID) {
        guard !isReadOnly, notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        changed(id)
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
            dirty.insert(existing.id)
        }
        // Removing a destination above may have changed the array index.
        if let index = notes.firstIndex(where: { $0.id == draft.id }) {
            notes[index].session = new.description
        }
        changed(draft.id)
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
            dirty.insert(notes[i].id)
            updated = true
        }
        if updated { changed() }
    }

    private func changed(_ id: UUID? = nil) {
        if let id { dirty.insert(id) }
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
        guard isDirty || !staleFiles.isEmpty else { return true }
        guard !isReadOnly else { return false }
        guard let directory else {
            dirty.removeAll()
            return true
        }
        let manager = FileManager.default
        func remove(_ name: String) throws {
            do { try manager.removeItem(at: directory.appendingPathComponent(name)) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {}
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for id in dirty.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let note = note(id), !note.isEmpty {
                    let name = NoteFile.name(for: note)
                    try Data(NoteFile.format(note).utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
                    if let old = files[id], old != name { try remove(old) }
                    files[id] = name
                } else if let old = files[id] {
                    try remove(old)
                    files[id] = nil
                }
                dirty.remove(id)
            }
            for name in staleFiles.sorted() {
                try remove(name)
                staleFiles.remove(name)
            }
            saveProblem = nil
            return true
        } catch {
            saveProblem = "Could not save notes: \(error.localizedDescription)"
            return false
        }
    }
}

/// One note as a Markdown file:
///
///     ---
///     id: 0F1E…
///     session: "claude:3c9…"
///     title: "Fix the parser"
///     folder: "/Users/me/project"
///     updated: 2026-11-14T09:30:00Z
///     ---
///
///     The note's Markdown, exactly as written.
enum NoteFile {
    static func name(for note: SessionNote) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var title = note.title.components(separatedBy: banned).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while title.hasPrefix(".") { title.removeFirst() }
        title = String(title.prefix(60)).trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = "Note" }
        return "\(title) \(note.id.uuidString.prefix(8).lowercased()).md"
    }

    static func format(_ note: SessionNote) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quoted(_ value: String) -> String {
            // A JSON string is also a valid YAML double-quoted string.
            String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
        return """
        ---
        id: \(note.id.uuidString)
        session: \(quoted(note.session))
        title: \(quoted(note.title))
        folder: \(quoted(note.folder))
        updated: \(ISO8601DateFormatter().string(from: note.updated))
        ---


        """ + note.text
    }

    static func parse(_ file: String) -> SessionNote? {
        guard file.hasPrefix("---\n"), let end = file.range(of: "\n---\n") else { return nil }
        var fields: [String: String] = [:]
        for line in file[file.index(file.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { return nil }
                fields[key] = value
            } else {
                fields[key] = raw
            }
        }
        var text = file[end.upperBound...]
        if text.hasPrefix("\n") { text.removeFirst() }
        guard let id = fields["id"].flatMap(UUID.init(uuidString:)),
              let session = fields["session"], SessionKey(parsing: session) != nil
        else { return nil }
        let updated = fields["updated"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        return SessionNote(id: id, session: session, title: fields["title"] ?? "", folder: fields["folder"] ?? "",
                           text: String(text), updated: updated)
    }
}

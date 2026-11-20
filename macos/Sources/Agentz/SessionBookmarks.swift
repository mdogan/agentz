import AgentzCore
import Foundation
import Observation

/// A Claude or Codex session the user wants to find again later.
struct SessionBookmark: Codable, Equatable {
    /// The session's key, as `agent:id`.
    var session: String
    /// The session's title and folder when last seen, so the bookmark shows
    /// before the scan reads old sessions, and after the transcript is gone.
    var title: String
    var folder: String
    var added: Date

    var key: SessionKey? { SessionKey(parsing: session) }
}

/// The bookmarked sessions, in one JSON file. A bookmark stays until the
/// user removes it, even when its transcript is gone. The file is replaced
/// atomically on each change. If it can't be read, it is left untouched and
/// bookmarks can't be changed.
@MainActor
@Observable
final class SessionBookmarks {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agentz/bookmarks.json")
    }

    private(set) var bookmarks: [SessionBookmark] = []
    /// Why the file could not be read, or why the last save failed.
    private(set) var problem: String?
    private(set) var isReadOnly = false
    @ObservationIgnored private let url: URL?
    @ObservationIgnored var onChange: (() -> Void)?

    /// A nil `url` keeps bookmarks in memory, for tests and the smoke app.
    init(url: URL? = nil) {
        self.url = url
        guard let url else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return  // None yet; the file is made with the first bookmark.
        } catch {
            isReadOnly = true
            problem = "Could not read bookmarks: \(error.localizedDescription)"
            return
        }
        do {
            bookmarks = try Self.decoder.decode([SessionBookmark].self, from: data)
        } catch {
            isReadOnly = true
            problem = "Could not read bookmarks. The file has been left untouched: \(error.localizedDescription)"
        }
    }

    /// Only Claude and Codex sessions can be bookmarked: shells and git tabs
    /// have nothing to resume.
    static func canBookmark(_ key: SessionKey) -> Bool {
        key.agent == .claude || key.agent == .codex
    }

    func contains(_ key: SessionKey) -> Bool {
        bookmarks.contains { $0.session == key.description }
    }

    func bookmark(for key: SessionKey) -> SessionBookmark? {
        bookmarks.first { $0.session == key.description }
    }

    func add(_ key: SessionKey, title: String, folder: String, at date: Date = Date()) {
        guard !isReadOnly, Self.canBookmark(key), !contains(key) else { return }
        bookmarks.append(SessionBookmark(session: key.description, title: title, folder: folder, added: date))
        changed()
    }

    func remove(_ key: SessionKey) {
        guard !isReadOnly, contains(key) else { return }
        bookmarks.removeAll { $0.session == key.description }
        changed()
    }

    /// A new Codex session got its real id.
    func rebind(from old: SessionKey, to new: SessionKey) {
        guard !isReadOnly, old != new, let i = bookmarks.firstIndex(where: { $0.session == old.description }) else { return }
        if contains(new) {
            bookmarks.remove(at: i)
        } else {
            bookmarks[i].session = new.description
        }
        changed()
    }

    /// Keeps each bookmark's title and folder up to date with its session.
    func refreshMetadata(_ sessions: [Session]) {
        guard !isReadOnly, !bookmarks.isEmpty else { return }
        let metadata = Dictionary(sessions.map { ($0.key.description, $0) }, uniquingKeysWith: { first, _ in first })
        var updated = false
        for i in bookmarks.indices {
            guard let session = metadata[bookmarks[i].session],
                  bookmarks[i].title != session.title || bookmarks[i].folder != session.cwd else { continue }
            bookmarks[i].title = session.title
            bookmarks[i].folder = session.cwd
            updated = true
        }
        if updated { changed() }
    }

    private func changed() {
        save()
        onChange?()
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(bookmarks).write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = "Could not save bookmarks: \(error.localizedDescription)"
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

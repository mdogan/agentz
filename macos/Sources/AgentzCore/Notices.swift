import Foundation

/// Something to tell the user about one session: its agent waits or quit,
/// or a command in it finished.
public struct SessionNotice: Equatable {
    public var key: SessionKey
    /// E.g. `Claude is waiting`.
    public var heading: String
    /// The session's title.
    public var title: String
    /// What the agent itself said, if it said something.
    public var message: String?

    public init(key: SessionKey, heading: String, title: String, message: String?) {
        self.key = key
        self.heading = heading
        self.title = title
        self.message = message
    }
}

/// A notification to show.
public struct NoticePost: Equatable {
    /// One about a single session has the session's key as its id, so a
    /// newer one replaces it.
    public let id: String
    public let title: String
    public let body: String
    /// The sessions it is about.
    public let keys: [SessionKey]
}

/// Turns notices that come at the same moment, like several agents that
/// finish in the same second, into one notification. Remembers which
/// notification is about which sessions, so each can be taken back once
/// the user saw all of them.
public struct NoticeBatcher {
    /// Notices waiting for the next `flush`.
    public private(set) var pending: [SessionNotice] = []
    /// Notifications shown and not taken back, by id, with the sessions
    /// they are about that the user has not seen since.
    public private(set) var shown: [String: Set<SessionKey>] = [:]
    private var next = 1

    public init() {}

    /// Holds `notice` for the next `flush`, in place of an earlier one
    /// about the same session. True if nothing was waiting before, so the
    /// caller should flush after a moment.
    public mutating func add(_ notice: SessionNotice) -> Bool {
        let first = pending.isEmpty
        pending.removeAll { $0.key == notice.key }
        pending.append(notice)
        return first
    }

    /// One notification for what is waiting, and the ids of earlier ones it
    /// makes redundant: those about none but these sessions.
    public mutating func flush() -> (post: NoticePost?, replaced: [String]) {
        let notices = pending
        pending = []
        guard let first = notices.first else { return (nil, []) }
        let keys = notices.map(\.key)
        let post: NoticePost
        if notices.count == 1 {
            post = NoticePost(
                id: first.key.description,
                title: first.heading,
                body: first.message.map { "\(first.title): \(short($0, 200))" } ?? first.title,
                keys: keys
            )
        } else {
            post = NoticePost(
                id: "agentz-notice-\(next)",
                title: "\(notices.count) sessions need you",
                body: notices.map { short("\($0.title): \($0.message ?? $0.heading)", 120) }.joined(separator: "\n"),
                keys: keys
            )
            next += 1
        }
        let replaced = shown.filter { $0.key != post.id && $0.value.isSubset(of: Set(keys)) }.map(\.key).sorted()
        for id in replaced {
            shown[id] = nil
        }
        shown[post.id] = Set(keys)
        return (post, replaced)
    }

    /// The user saw the session. Drops a notice about it that is waiting,
    /// and returns the notifications to take back: those about no other
    /// session the user has not seen.
    public mutating func seen(_ key: SessionKey) -> [String] {
        pending.removeAll { $0.key == key }
        var done: [String] = []
        for (id, keys) in shown where keys.contains(key) {
            var left = keys
            left.remove(key)
            if left.isEmpty {
                shown[id] = nil
                done.append(id)
            } else {
                shown[id] = left
            }
        }
        return done.sorted()
    }
}

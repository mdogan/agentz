import Foundation

/// One visible line of a change section drawn as a folder tree.
enum ChangeTreeRow: Identifiable, Equatable, Sendable {
    /// A folder. `name` can hold several path parts ("src/app") when a folder
    /// only contains another folder. `path` is its full path in the repository.
    /// `entries` is every changed file below it, also those of collapsed folders.
    case folder(id: String, name: String, path: String, depth: Int, entries: [ChangeEntry], isCollapsed: Bool)
    case file(ChangeEntry, name: String, depth: Int)

    var id: String {
        switch self {
        case let .folder(id, _, _, _, _, _): "dir|" + id
        case let .file(entry, _, _): "file|\(entry.staged)|" + entry.change.path
        }
    }
}

/// Builds the folder tree for one section of the change list. Folders come
/// before files, each sorted by name, so the tree reads like a file browser.
///
/// A folder that wraps the whole section and holds no file of its own is not
/// drawn: with only `crates/a/x.rs` and `crates/b/y.rs`, the tree starts at `a`
/// and `b`. A folder that does hold a file stays, so that file does not look
/// like it sits at the top of the repository.
enum ChangeTree {
    /// Rows to draw. Files under a collapsed folder are left out.
    /// `section` keeps the same folder in "Staged" and "Unstaged" apart.
    static func rows(
        _ entries: [ChangeEntry],
        section: String,
        collapsed: Set<String> = []
    ) -> [ChangeTreeRow] {
        var items = entries.map { Item(entry: $0, parts: components(of: $0.change.path)) }
        let root = hiddenRoot(of: items)
        for index in items.indices {
            items[index].parts.removeFirst(root.count)
        }
        var rows: [ChangeTreeRow] = []
        emit(
            items,
            depth: 0,
            parent: root.joined(separator: "/"),
            section: section,
            collapsed: collapsed,
            into: &rows
        )
        return rows
    }

    /// The entries in tree order. Shift-click ranges use this order, so it
    /// must match what `rows` draws.
    static func ordered(_ entries: [ChangeEntry]) -> [ChangeEntry] {
        rows(entries, section: "").compactMap {
            if case let .file(entry, _, _) = $0 { entry } else { nil }
        }
    }

    private struct Item {
        let entry: ChangeEntry
        var parts: [String]
    }

    private static func components(of path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts.isEmpty ? [path] : parts
    }

    /// The folders every file sits below, when no file sits directly in them.
    private static func hiddenRoot(of items: [Item]) -> [String] {
        guard let first = items.first else { return [] }
        var shared = Array(first.parts.dropLast())
        for item in items.dropFirst() {
            shared = zip(shared, item.parts.dropLast()).prefix { $0 == $1 }.map(\.0)
        }
        return items.allSatisfy { $0.parts.count - 1 > shared.count } ? shared : []
    }

    private static func emit(
        _ items: [Item],
        depth: Int,
        parent: String,
        section: String,
        collapsed: Set<String>,
        into rows: inout [ChangeTreeRow]
    ) {
        var files: [Item] = []
        var folders: [String: [Item]] = [:]
        for item in items {
            if item.parts.count <= 1 {
                files.append(item)
            } else {
                var rest = item
                let head = rest.parts.removeFirst()
                folders[head, default: []].append(rest)
            }
        }

        for head in folders.keys.sorted(by: nameOrder) {
            var group = folders[head] ?? []
            var name = head
            // A folder holding only one other folder is shown as "a/b".
            while let next = group.first?.parts.first,
                  group.allSatisfy({ $0.parts.count > 1 && $0.parts[0] == next }) {
                name += "/" + next
                group = group.map {
                    var item = $0
                    item.parts.removeFirst()
                    return item
                }
            }
            let path = parent.isEmpty ? name : parent + "/" + name
            // From the full path, so a folder stays folded when a new file
            // makes the hidden root show again.
            let id = section + "/" + path
            let isCollapsed = collapsed.contains(id)
            rows.append(.folder(
                id: id,
                name: name,
                path: path,
                depth: depth,
                entries: group.map(\.entry),
                isCollapsed: isCollapsed
            ))
            if !isCollapsed {
                emit(
                    group,
                    depth: depth + 1,
                    parent: path,
                    section: section,
                    collapsed: collapsed,
                    into: &rows
                )
            }
        }

        for item in files.sorted(by: { nameOrder($0.parts[0], $1.parts[0]) }) {
            rows.append(.file(item.entry, name: item.parts[0], depth: depth))
        }
    }

    private static func nameOrder(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a < b
        }
    }
}

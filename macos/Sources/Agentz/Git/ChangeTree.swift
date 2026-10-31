import Foundation

/// One visible line of a change section drawn as a folder tree.
enum ChangeTreeRow: Identifiable, Equatable, Sendable {
    /// A folder. `name` can hold several path parts ("src/app") when a folder
    /// only contains another folder. `count` is every changed file below it.
    case folder(id: String, name: String, depth: Int, count: Int, isCollapsed: Bool)
    case file(ChangeEntry, name: String, depth: Int)

    var id: String {
        switch self {
        case let .folder(id, _, _, _, _): "dir|" + id
        case let .file(entry, _, _): "file|\(entry.staged)|" + entry.change.path
        }
    }
}

/// Builds the folder tree for one section of the change list. Folders come
/// before files, each sorted by name, so the tree reads like a file browser.
enum ChangeTree {
    /// Rows to draw. Files under a collapsed folder are left out.
    /// `section` keeps the same folder in "Staged" and "Unstaged" apart.
    static func rows(
        _ entries: [ChangeEntry],
        section: String,
        collapsed: Set<String> = []
    ) -> [ChangeTreeRow] {
        let items = entries.map { Item(entry: $0, parts: components(of: $0.change.path)) }
        var rows: [ChangeTreeRow] = []
        emit(items, depth: 0, parent: section, collapsed: collapsed, into: &rows)
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

    private static func emit(
        _ items: [Item],
        depth: Int,
        parent: String,
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
            let id = parent + "/" + name
            let isCollapsed = collapsed.contains(id)
            rows.append(.folder(
                id: id,
                name: name,
                depth: depth,
                count: group.count,
                isCollapsed: isCollapsed
            ))
            if !isCollapsed {
                emit(group, depth: depth + 1, parent: id, collapsed: collapsed, into: &rows)
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

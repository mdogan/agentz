import Foundation

/// Stable identity for a row in the working-tree change list.
///
/// Git status characters change as a file moves between the index and the
/// working tree, so `WorkingChange.id` does not survive a refresh. Selection is
/// tracked by path and side instead.
struct ChangeEntryID: Hashable, Sendable {
    let path: String
    let staged: Bool
}

/// One row in the working-tree change list: a file plus the side it is listed
/// under. A partially staged file appears on both sides.
struct ChangeEntry: Hashable, Identifiable, Sendable {
    let change: WorkingChange
    let staged: Bool

    init(_ change: WorkingChange, staged: Bool) {
        self.change = change
        self.staged = staged
    }

    var id: ChangeEntryID {
        ChangeEntryID(path: change.path, staged: staged)
    }
}

enum ChangeSelectionKey: Sendable {
    case returnKey
    case deleteKey

    /// The main Return key sends carriage return (U+000D), while the Enter
    /// key on Apple's numeric keypad sends the distinct enter character
    /// (U+0003). Treat both as the Changes list's staging key.
    static let returnCharacters = CharacterSet(charactersIn: "\r\u{3}")
}

enum ChangeSelectionAction: Sendable {
    case stage
    case unstage
}

extension Array where Element == ChangeEntry {
    /// Rows listed under "Unstaged Changes": the ones `git add` and a discard
    /// apply to.
    var unstagedSide: [ChangeEntry] {
        filter { !$0.staged && !$0.change.isConflicted }
    }

    /// Rows listed under "Staged Changes": the ones `git restore --staged`
    /// applies to.
    var stagedSide: [ChangeEntry] {
        filter(\.staged)
    }

    /// Conflict rows occupy their own Changes section. They intentionally do
    /// not participate in generic stage, unstage, or discard actions.
    var conflicted: [ChangeEntry] {
        filter { $0.change.isConflicted }
    }

    var paths: [String] {
        map(\.change.path)
    }
}

/// Multi-selection for the change list: which rows are selected, which row
/// drives the diff pane, and the anchor a shift-click extends from.
struct ChangeSelectionModel: Equatable, Sendable {
    private(set) var selected: Set<ChangeEntryID> = []
    /// The row whose diff the detail pane shows. Always a member of `selected`
    /// unless nothing is selected.
    private(set) var primary: ChangeEntryID?
    private(set) var anchor: ChangeEntryID?

    var count: Int { selected.count }
    var isEmpty: Bool { selected.isEmpty }

    func contains(_ id: ChangeEntryID) -> Bool {
        selected.contains(id)
    }

    /// Return stages from the unstaged section; Delete unstages from the staged
    /// section. Other key/section combinations intentionally do nothing.
    func keyboardAction(for key: ChangeSelectionKey) -> ChangeSelectionAction? {
        guard let primary else { return nil }
        switch (key, primary.staged) {
        case (.returnKey, false):
            return .stage
        case (.deleteKey, true):
            return .unstage
        default:
            return nil
        }
    }

    /// Replaces the selection with a single row: a plain click.
    mutating func select(_ id: ChangeEntryID?) {
        selected = id.map { [$0] } ?? []
        primary = id
        anchor = id
    }

    mutating func clear() {
        select(nil)
    }

    /// Adds or removes one row and leaves the rest alone: a Command-click.
    mutating func toggle(_ id: ChangeEntryID, in order: [ChangeEntryID]) {
        if selected.contains(id) {
            selected.remove(id)
            if primary == id {
                primary = order.first(where: selected.contains)
            }
        } else {
            selected.insert(id)
            primary = id
        }
        anchor = id
    }

    /// Selects every row between the anchor and `id`: a Shift-click.
    /// Successive shift-clicks keep pivoting on the same anchor, as in Finder.
    mutating func extend(to id: ChangeEntryID, in order: [ChangeEntryID]) {
        guard let pivot = anchor ?? primary,
              let start = order.firstIndex(of: pivot),
              let end = order.firstIndex(of: id) else {
            select(id)
            return
        }
        let bounds = start <= end ? start...end : end...start
        selected = Set(order[bounds])
        primary = id
        anchor = pivot
    }

    /// Rebuilds the selection after a repository refresh. When the primary row
    /// leaves its section, selection stays at the same relative position in
    /// that section while any rows remain. It follows the file to its new side
    /// only when the original section becomes empty.
    mutating func reconcile(
        previousOrder: [ChangeEntryID],
        order: [ChangeEntryID],
        survivor: (ChangeEntryID) -> ChangeEntryID?
    ) {
        let previousSelected = selected
        let previousPrimary = primary
        let previousAnchor = anchor
        let live = Set(order)

        func reconciled(_ id: ChangeEntryID) -> ChangeEntryID? {
            guard let candidate = survivor(id), live.contains(candidate) else {
                return nil
            }
            let originalSectionStillHasRows = order.contains {
                $0.staged == id.staged
            }
            if candidate.staged != id.staged,
               originalSectionStillHasRows {
                return nil
            }
            return candidate
        }

        selected = Set(previousSelected.compactMap(reconciled))

        if let previousPrimary,
           let survivingPrimary = reconciled(previousPrimary),
           selected.contains(survivingPrimary) {
            primary = survivingPrimary
        } else if let previousPrimary,
                  let replacement = replacement(
                      for: previousPrimary,
                      previousOrder: previousOrder,
                      order: order
                  ) {
            selected.insert(replacement)
            primary = replacement
        } else {
            primary = order.first(where: selected.contains)
        }

        if let previousAnchor,
           let survivingAnchor = reconciled(previousAnchor),
           selected.contains(survivingAnchor) {
            anchor = survivingAnchor
        } else {
            anchor = primary
        }
    }

    private func replacement(
        for id: ChangeEntryID,
        previousOrder: [ChangeEntryID],
        order: [ChangeEntryID]
    ) -> ChangeEntryID? {
        let previousSection = previousOrder.filter {
            $0.staged == id.staged
        }
        let currentSection = order.filter {
            $0.staged == id.staged
        }
        guard !currentSection.isEmpty else {
            return nil
        }
        let previousIndex = previousSection.firstIndex(of: id) ?? 0
        return currentSection[min(previousIndex, currentSection.count - 1)]
    }
}

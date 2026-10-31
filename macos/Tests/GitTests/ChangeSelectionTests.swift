import Foundation
import Testing
@testable import agentz

struct ChangeSelectionTests {
    /// The change list draws staged rows first, then working-tree rows, and a
    /// file that is partially staged appears in both sections.
    private let order: [ChangeEntryID] = [
        ChangeEntryID(path: "a.swift", staged: true),
        ChangeEntryID(path: "b.swift", staged: true),
        ChangeEntryID(path: "b.swift", staged: false),
        ChangeEntryID(path: "c.swift", staged: false),
        ChangeEntryID(path: "d.swift", staged: false)
    ]

    @Test
    func plainSelectionReplacesEverythingElse() {
        var selection = ChangeSelectionModel()
        selection.extend(to: order[0], in: order)
        selection.toggle(order[3], in: order)
        #expect(selection.count == 2)

        selection.select(order[4])

        #expect(selection.selected == [order[4]])
        #expect(selection.primary == order[4])

        selection.select(nil)

        #expect(selection.isEmpty)
        #expect(selection.primary == nil)
    }

    @Test
    func togglingAddsAndRemovesASingleRow() {
        var selection = ChangeSelectionModel()
        selection.select(order[1])
        selection.toggle(order[3], in: order)
        selection.toggle(order[4], in: order)

        #expect(selection.selected == [order[1], order[3], order[4]])
        #expect(selection.primary == order[4])

        selection.toggle(order[4], in: order)

        #expect(selection.selected == [order[1], order[3]])
        // The removed row was primary, so the diff pane falls back to the
        // first row that is still selected.
        #expect(selection.primary == order[1])
    }

    @Test
    func shiftClickSelectsAnInclusiveRangeInBothDirections() {
        var selection = ChangeSelectionModel()
        selection.select(order[1])
        selection.extend(to: order[3], in: order)

        #expect(selection.selected == [order[1], order[2], order[3]])
        #expect(selection.primary == order[3])

        // A second shift-click pivots on the same anchor rather than the row
        // that was clicked last.
        selection.extend(to: order[0], in: order)

        #expect(selection.selected == [order[0], order[1]])
        #expect(selection.primary == order[0])
    }

    @Test
    func shiftClickSpansTheStagedAndUnstagedSections() {
        var selection = ChangeSelectionModel()
        selection.select(order[0])
        selection.extend(to: order[4], in: order)

        #expect(selection.selected == Set(order))
    }

    @Test
    func shiftClickWithoutAnAnchorSelectsOnlyTheClickedRow() {
        var selection = ChangeSelectionModel()
        selection.extend(to: order[2], in: order)

        #expect(selection.selected == [order[2]])
        #expect(selection.primary == order[2])

        // A stale anchor from a row that has since disappeared behaves the
        // same way.
        var stale = ChangeSelectionModel()
        stale.select(ChangeEntryID(path: "gone.swift", staged: false))
        stale.extend(to: order[1], in: order)

        #expect(stale.selected == [order[1]])
    }

    @Test
    func keyboardActionsMatchThePrimaryRowsSection() {
        var selection = ChangeSelectionModel()

        selection.select(order[2])
        #expect(selection.keyboardAction(for: .returnKey) == .stage)
        #expect(selection.keyboardAction(for: .deleteKey) == nil)

        selection.select(order[1])
        #expect(selection.keyboardAction(for: .returnKey) == nil)
        #expect(selection.keyboardAction(for: .deleteKey) == .unstage)

        selection.clear()
        #expect(selection.keyboardAction(for: .returnKey) == nil)
        #expect(selection.keyboardAction(for: .deleteKey) == nil)
    }

    @Test
    func returnCharactersIncludeMainAndNumericKeypadKeys() {
        let characters = ChangeSelectionKey.returnCharacters

        #expect(characters.contains("\r".unicodeScalars.first!))
        #expect(characters.contains("\u{3}".unicodeScalars.first!))
        #expect(!characters.contains(" ".unicodeScalars.first!))
    }

    @Test
    func refreshFollowsMovedFileWhenOriginalSectionBecomesEmpty() {
        var selection = ChangeSelectionModel()
        selection.select(order[3])
        selection.toggle(order[4], in: order)

        // c.swift was staged and d.swift was discarded.
        let staged = ChangeEntryID(path: "c.swift", staged: true)
        let refreshed = [staged]
        selection.reconcile(previousOrder: order, order: refreshed) { id in
            switch id.path {
            case "c.swift": staged
            default: nil
            }
        }

        #expect(selection.selected == [staged])
        #expect(selection.primary == staged)
        #expect(selection.anchor == staged)
    }

    @Test
    func refreshKeepsPrimaryInItsOriginalSectionWhileRowsRemain() {
        let stagedA = ChangeEntryID(path: "a.swift", staged: true)
        let stagedB = ChangeEntryID(path: "b.swift", staged: true)
        let stagedC = ChangeEntryID(path: "c.swift", staged: true)
        let unstagedD = ChangeEntryID(path: "d.swift", staged: false)
        let previous = [stagedA, stagedB, stagedC, unstagedD]
        var selection = ChangeSelectionModel()
        selection.select(stagedB)

        let movedB = ChangeEntryID(path: "b.swift", staged: false)
        let refreshed = [stagedA, stagedC, movedB, unstagedD]
        selection.reconcile(previousOrder: previous, order: refreshed) { id in
            id == stagedB ? movedB : id
        }

        #expect(selection.selected == [stagedC])
        #expect(selection.primary == stagedC)
        #expect(selection.anchor == stagedC)
    }

    @Test
    func refreshFallsBackToPreviousRowAtTheEndOfASection() {
        var selection = ChangeSelectionModel()
        selection.select(order[4])

        let movedD = ChangeEntryID(path: "d.swift", staged: true)
        let refreshed = [order[0], order[1], movedD, order[2], order[3]]
        selection.reconcile(previousOrder: order, order: refreshed) { id in
            id == order[4] ? movedD : id
        }

        #expect(selection.selected == [order[3]])
        #expect(selection.primary == order[3])
        #expect(selection.anchor == order[3])
    }

    @Test
    func refreshKeepsUnaffectedRowsAndDropsVanishedOnes() {
        var selection = ChangeSelectionModel()
        selection.select(order[2])
        selection.extend(to: order[4], in: order)
        #expect(selection.count == 3)

        // Only d.swift still has changes; the primary row is gone.
        let refreshed = [order[4]]
        selection.reconcile(previousOrder: order, order: refreshed) { id in
            id.path == "d.swift" ? id : nil
        }

        #expect(selection.selected == [order[4]])
        #expect(selection.primary == order[4])
    }

    @Test
    func refreshClearsASelectionWhoseFilesAllDisappeared() {
        var selection = ChangeSelectionModel()
        selection.select(order[0])
        selection.extend(to: order[2], in: order)

        selection.reconcile(previousOrder: order, order: []) { _ in nil }

        #expect(selection.isEmpty)
        #expect(selection.primary == nil)
        #expect(selection.anchor == nil)
    }

    @Test
    func entryGroupingSplitsASelectionBySection() {
        let entries = [
            ChangeEntry(change("a.swift", index: "M", workTree: " "), staged: true),
            ChangeEntry(change("b.swift", index: "M", workTree: "M"), staged: true),
            ChangeEntry(change("b.swift", index: "M", workTree: "M"), staged: false),
            ChangeEntry(change("conflict.swift", index: "U", workTree: "U"), staged: false),
            ChangeEntry(change("c.swift", index: "?", workTree: "?"), staged: false)
        ]

        #expect(entries.stagedSide.paths == ["a.swift", "b.swift"])
        #expect(entries.unstagedSide.paths == ["b.swift", "c.swift"])
        #expect(entries.conflicted.paths == ["conflict.swift"])
        #expect(entries[0].id == ChangeEntryID(path: "a.swift", staged: true))
    }

    private func change(
        _ path: String,
        index: Character,
        workTree: Character
    ) -> WorkingChange {
        WorkingChange(
            path: path,
            originalPath: nil,
            indexStatus: index,
            workTreeStatus: workTree
        )
    }
}

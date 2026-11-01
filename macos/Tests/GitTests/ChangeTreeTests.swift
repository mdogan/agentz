import Foundation
import Testing
@testable import agentz

struct ChangeTreeTests {
    private func entry(_ path: String, staged: Bool = false) -> ChangeEntry {
        ChangeEntry(
            WorkingChange(path: path, originalPath: nil, indexStatus: " ", workTreeStatus: "M"),
            staged: staged
        )
    }

    private func describe(_ rows: [ChangeTreeRow]) -> [String] {
        rows.map {
            switch $0 {
            case let .folder(_, name, _, depth, entries, _):
                String(repeating: " ", count: depth) + name + "/ (\(entries.count))"
            case let .file(_, name, depth):
                String(repeating: " ", count: depth) + name
            }
        }
    }

    @Test func foldersComeBeforeFilesAndAreSorted() {
        let rows = ChangeTree.rows(
            [entry("z.txt"), entry("src/b.swift"), entry("README.md"), entry("src/a.swift"), entry("docs/x.md")],
            section: "s"
        )
        #expect(describe(rows) == [
            "docs/ (1)", " x.md",
            "src/ (2)", " a.swift", " b.swift",
            "README.md", "z.txt",
        ])
    }

    @Test func folderWithOnlyOneFolderIsJoined() {
        let rows = ChangeTree.rows(
            [entry("a/b/c/one.swift"), entry("a/b/c/two.swift")],
            section: "s"
        )
        #expect(describe(rows) == ["a/b/c/ (2)", " one.swift", " two.swift"])
    }

    @Test func folderWithFilesAndFolderIsNotJoined() {
        let rows = ChangeTree.rows([entry("a/top.swift"), entry("a/b/deep.swift")], section: "s")
        #expect(describe(rows) == ["a/ (2)", " b/ (1)", "  deep.swift", " top.swift"])
    }

    @Test func rootThatOnlyWrapsFoldersIsNotDrawn() {
        let rows = ChangeTree.rows(
            [entry("crates/exec/src/a.rs"), entry("crates/exec/tests/b.rs"), entry("crates/explain/src/c.rs")],
            section: "s"
        )
        #expect(describe(rows) == [
            "exec/ (2)", " src/ (1)", "  a.rs", " tests/ (1)", "  b.rs",
            "explain/src/ (1)", " c.rs",
        ])
    }

    @Test func rootOfSeveralPartsIsNotDrawn() {
        let rows = ChangeTree.rows([entry("x/y/a/1.rs"), entry("x/y/b/2.rs")], section: "s")
        #expect(describe(rows) == ["a/ (1)", " 1.rs", "b/ (1)", " 2.rs"])
    }

    @Test func folderStaysWhenAFileIsOutsideIt() {
        let rows = ChangeTree.rows(
            [entry("crates/a/x.rs"), entry("crates/b/y.rs"), entry("README.md")],
            section: "s"
        )
        #expect(describe(rows) == ["crates/ (2)", " a/ (1)", "  x.rs", " b/ (1)", "  y.rs", "README.md"])
    }

    @Test func folderKeepsFullPathAndIDWhenRootIsHidden() {
        let hidden = ChangeTree.rows([entry("crates/a/x.rs"), entry("crates/b/y.rs")], section: "s")
        let shown = ChangeTree.rows(
            [entry("crates/a/x.rs"), entry("crates/b/y.rs"), entry("README.md")],
            section: "s"
        )
        guard case let .folder(id, name, path, _, _, _) = hidden[0] else {
            Issue.record("expected a folder first")
            return
        }
        #expect(name == "a")
        #expect(path == "crates/a")
        #expect(shown.contains { $0.id == hidden[0].id })
        // Folded with the root hidden, it is still folded with the root shown.
        let folded = ChangeTree.rows(
            [entry("crates/a/x.rs"), entry("crates/b/y.rs"), entry("README.md")],
            section: "s",
            collapsed: [id]
        )
        #expect(describe(folded) == ["crates/ (2)", " a/ (1)", " b/ (1)", "  y.rs", "README.md"])
    }

    @Test func folderListsEveryFileBelowItEvenWhenCollapsed() {
        let entries = [entry("src/a/one.rs"), entry("src/a/b/two.rs"), entry("src/c/three.rs")]
        let open = ChangeTree.rows(entries, section: "s")
        guard case let .folder(id, _, _, _, _, _) = open[0] else {
            Issue.record("expected a folder first")
            return
        }
        guard case let .folder(_, name, _, _, below, _) = ChangeTree.rows(entries, section: "s", collapsed: [id])[0] else {
            Issue.record("expected a folder first")
            return
        }
        #expect(name == "a")
        #expect(Set(below.map(\.change.path)) == ["src/a/one.rs", "src/a/b/two.rs"])
    }

    @Test func collapsedFolderHidesItsFiles() {
        let all = ChangeTree.rows([entry("src/a.swift"), entry("main.swift")], section: "s")
        guard case let .folder(id, _, _, _, _, _) = all[0] else {
            Issue.record("expected a folder first")
            return
        }
        let rows = ChangeTree.rows([entry("src/a.swift"), entry("main.swift")], section: "s", collapsed: [id])
        #expect(describe(rows) == ["src/ (1)", "main.swift"])
    }

    @Test func orderedMatchesDrawnFileOrder() {
        let entries = [entry("z.txt"), entry("src/b.swift"), entry("src/a.swift"), entry("a.txt")]
        #expect(ChangeTree.ordered(entries).map(\.change.path) == [
            "src/a.swift", "src/b.swift", "a.txt", "z.txt",
        ])
    }

    @Test func sameFolderInTwoSectionsHasDifferentIDs() {
        let staged = ChangeTree.rows([entry("src/a.swift", staged: true)], section: "staged")
        let unstaged = ChangeTree.rows([entry("src/a.swift")], section: "unstaged")
        #expect(staged[0].id != unstaged[0].id)
    }
}

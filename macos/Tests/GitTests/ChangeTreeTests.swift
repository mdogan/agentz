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
            case let .folder(_, name, depth, count, _):
                String(repeating: " ", count: depth) + name + "/ (\(count))"
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

    @Test func collapsedFolderHidesItsFiles() {
        let all = ChangeTree.rows([entry("src/a.swift"), entry("main.swift")], section: "s")
        guard case let .folder(id, _, _, _, _) = all[0] else {
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

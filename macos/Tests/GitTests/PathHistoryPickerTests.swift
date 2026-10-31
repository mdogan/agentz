import Testing
@testable import agentz

struct PathHistoryPickerTests {
    @Test
    func normalizesSafeRelativePathsAndRejectsTraversal() {
        #expect(
            RepositoryPathSelection.normalized("  ./Sources//GitFork/  ")
                == "Sources/GitFork"
        )
        #expect(
            RepositoryPathSelection.normalizedSelection(" leading/file ")
                == " leading/file "
        )
        #expect(RepositoryPathSelection.normalized("../outside") == nil)
        #expect(RepositoryPathSelection.normalized("Sources/../../outside") == nil)
        #expect(RepositoryPathSelection.normalized("/absolute/path") == nil)
        #expect(RepositoryPathSelection.normalized(".") == nil)
    }

    @Test
    func buildsFilesAndTheirParentDirectoriesFromNulDelimitedPaths() {
        let items = GitClient.parseRepositoryPathItems(
            "README.md\0Sources/App.swift\0Sources/UI/MainView.swift\0"
        )

        #expect(
            Set(items) == Set([
                RepositoryPathItem(path: "README.md", kind: .file),
                RepositoryPathItem(path: "Sources", kind: .directory),
                RepositoryPathItem(path: "Sources/App.swift", kind: .file),
                RepositoryPathItem(path: "Sources/UI", kind: .directory),
                RepositoryPathItem(path: "Sources/UI/MainView.swift", kind: .file)
            ])
        )
        #expect(items.count == 5)
    }

    @Test
    func filtersPathsCaseInsensitively() {
        let source = RepositoryPathItem(
            path: "Sources/GitFork/RepositoryStore.swift",
            kind: .file
        )
        let tests = RepositoryPathItem(
            path: "Tests/GitForkTests/GitParserTests.swift",
            kind: .file
        )

        #expect(
            RepositoryPathPickerSearch.filter(
                [source, tests],
                query: "repository"
            ) == [source]
        )
        #expect(
            RepositoryPathPickerSearch.filter(
                [source, tests],
                query: "GITPARSER"
            ) == [tests]
        )
        #expect(
            RepositoryPathPickerSearch.filter(
                [source, tests],
                query: " "
            ) == [source, tests]
        )
    }

    @Test
    func reconcilesAndWrapsKeyboardSelection() {
        let first = RepositoryPathItem(path: "Docs", kind: .directory)
        let second = RepositoryPathItem(path: "Docs/Guide.md", kind: .file)
        let third = RepositoryPathItem(path: "README.md", kind: .file)
        let items = [first, second, third]

        #expect(
            RepositoryPathPickerNavigation.reconcile(
                selection: second,
                items: items
            ) == second
        )
        #expect(
            RepositoryPathPickerNavigation.reconcile(
                selection: second,
                items: [first, third]
            ) == first
        )
        #expect(
            RepositoryPathPickerNavigation.move(
                selection: first,
                offset: -1,
                items: items
            ) == third
        )
        #expect(
            RepositoryPathPickerNavigation.move(
                selection: third,
                offset: 1,
                items: items
            ) == first
        )
    }
}

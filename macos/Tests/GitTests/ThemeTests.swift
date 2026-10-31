import Testing
@testable import agentz

@MainActor
struct RepositoryColorTests {
    @Test
    func derivesStableColorsFromRepositoryNames() {
        #expect(
            GitForkTheme.repositoryColor(for: "GitFork")
                == GitForkTheme.repositoryColor(for: "gitfork")
        )
        #expect(
            GitForkTheme.repositoryColor(for: "GitFork")
                == GitForkTheme.identityColor(for: "GitFork")
        )
    }
}

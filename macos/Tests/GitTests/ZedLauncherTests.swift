import Foundation
import Testing
@testable import agentz

struct ZedLauncherTests {
    @Test
    func targetsStableZedApplicationWithRepositoryRoot() {
        let root = URL(fileURLWithPath: "/tmp/My Repository", isDirectory: true)
        let request = ZedLaunchRequest(repositoryRoot: root)
        let application = URL(fileURLWithPath: "/Applications/Zed.app", isDirectory: true)

        #expect(ZedLaunchRequest.bundleIdentifier == "dev.zed.Zed")
        #expect(request.repositoryRoot == root)
        #expect(request.arguments == ["--new", "/tmp/My Repository"])
        #expect(
            request.executableURL(in: application).path
                == "/Applications/Zed.app/Contents/MacOS/cli"
        )
    }

    @Test
    func describesMissingApplication() {
        #expect(
            ZedNotInstalledError().errorDescription
                == "Zed is not installed. Install Zed and try again."
        )
    }

    @Test
    func describesLaunchFailure() {
        #expect(
            ZedLaunchError(detail: "permission denied").errorDescription
                == "GitFork could not open a new Zed window: permission denied"
        )
    }
}

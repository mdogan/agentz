import AppKit
import Foundation

struct ZedLaunchRequest: Equatable, Sendable {
    static let bundleIdentifier = "dev.zed.Zed"

    let repositoryRoot: URL

    var arguments: [String] {
        ["--new", repositoryRoot.path]
    }

    func executableURL(in applicationURL: URL) -> URL {
        applicationURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent("cli")
    }
}

struct ZedNotInstalledError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Zed is not installed. Install Zed and try again."
    }
}

struct ZedLaunchError: LocalizedError, Sendable {
    let detail: String

    var errorDescription: String? {
        "GitFork could not open a new Zed window: \(detail)"
    }
}

@MainActor
struct ZedLauncher {
    func openRepository(at root: URL) async throws {
        let request = ZedLaunchRequest(repositoryRoot: root)
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ZedLaunchRequest.bundleIdentifier
        ) else {
            throw ZedNotInstalledError()
        }

        try await Task.detached(priority: .userInitiated) {
            try await request.run(withApplicationAt: applicationURL)
        }.value
    }
}

private extension ZedLaunchRequest {
    func run(withApplicationAt applicationURL: URL) async throws {
        let executableURL = executableURL(in: applicationURL)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ZedLaunchError(detail: "The Zed command-line tool is missing.")
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let outputTask = Task.detached {
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        process.waitUntilExit()
        let output = String(decoding: await outputTask.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(decoding: await errorTask.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            let detail = error.isEmpty ? output : error
            throw ZedLaunchError(
                detail: detail.isEmpty ? "The Zed command-line tool failed." : detail
            )
        }
    }
}

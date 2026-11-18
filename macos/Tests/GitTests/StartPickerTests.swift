import Foundation
import Testing
@testable import agentz

struct StartPickerTests {
    @Test func homeIsFirstWithNoRecentFoldersAndTheCurrentFolderStaysSelected() throws {
        let here = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let (places, picked) = startPlaces(here: here, recents: [])
        let home = try #require(places.first)
        guard case let .folder(dir, repo) = home.choice else {
            Issue.record("Home must start a session in a folder")
            return
        }
        #expect(dir == NSHomeDirectory())
        #expect(repo == dir)
        #expect(home.always)
        #expect(home.matches(["~"]))
        #expect(picked == here)
    }

    @Test func aRecentAliasOfHomeSelectsTheSingleHomeRow() throws {
        let fm = FileManager.default
        let alias = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = NSHomeDirectory()
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: home)
        defer { try? fm.removeItem(at: alias) }

        let (places, picked) = startPlaces(here: alias.path, recents: [home, alias.path])
        #expect(places.first?.id == home)
        #expect(picked == home)
        let homeRows = places.filter { place in
            guard case let .folder(dir, _) = place.choice else { return false }
            return URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        }
        #expect(homeRows.count == 1)
    }
}

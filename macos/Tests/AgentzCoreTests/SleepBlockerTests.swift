@testable import AgentzCore
import IOKit.pwr_mgt
import XCTest

final class SleepBlockerTests: XCTestCase {
    @MainActor
    func testWorkingCreatesOneSystemSleepAssertionAndIdleReleasesIt() async throws {
        let blocker = SleepBlocker()
        blocker.setWorking(false)
        XCTAssertFalse(blocker.isBlocking)

        blocker.setWorking(true)
        defer { blocker.setWorking(false) }
        let id = try XCTUnwrap(blocker.assertionID)
        let properties = try XCTUnwrap(IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any])
        // Verify the actual macOS assertion, including that it permits
        // display sleep, rather than only checking our stored state.
        XCTAssertEqual(properties[kIOPMAssertionTypeKey] as? String, kIOPMAssertPreventUserIdleSystemSleep)
        XCTAssertEqual(properties[kIOPMAssertionLevelKey] as? UInt32, UInt32(kIOPMAssertionLevelOn))
        blocker.setWorking(true)
        XCTAssertEqual(blocker.assertionID, id)

        blocker.setWorking(false)
        XCTAssertFalse(blocker.isBlocking)
        XCTAssertNil(IOPMAssertionCopyProperties(id))

        // Another turn gets a new assertion, which is released as well.
        blocker.setWorking(true)
        let next = try XCTUnwrap(blocker.assertionID)
        XCTAssertNotNil(IOPMAssertionCopyProperties(next)?.takeRetainedValue())
        blocker.setWorking(false)
        XCTAssertNil(IOPMAssertionCopyProperties(next))
    }

    @MainActor
    func testDestroyingTheOwnerReleasesTheAssertion() async throws {
        var blocker: SleepBlocker? = SleepBlocker()
        blocker?.setWorking(true)
        let id = try XCTUnwrap(blocker?.assertionID)
        blocker = nil
        XCTAssertNil(IOPMAssertionCopyProperties(id))
    }
}

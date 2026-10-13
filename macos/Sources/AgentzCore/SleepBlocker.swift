import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake during agent work. The display may still sleep.
@MainActor
public final class SleepBlocker {
    private(set) var assertionID: IOPMAssertionID?
    private var reportedFailure = false

    public init() {}

    public var isBlocking: Bool { assertionID != nil }

    /// Repeated updates keep one assertion, released when all agents stop
    /// working. A failed request is retried on the next update.
    public func setWorking(_ working: Bool) {
        if working {
            guard assertionID == nil else { return }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Agentz agents are working" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                if !reportedFailure { NSLog("agentz: could not prevent sleep: %d", result) }
                reportedFailure = true
                return
            }
            assertionID = id
            reportedFailure = false
        } else if let id = assertionID {
            let result = IOPMAssertionRelease(id)
            guard result == kIOReturnSuccess else {
                if !reportedFailure { NSLog("agentz: could not release sleep assertion: %d", result) }
                reportedFailure = true
                return
            }
            assertionID = nil
            reportedFailure = false
        }
    }

    deinit {
        if let id = assertionID { IOPMAssertionRelease(id) }
    }
}

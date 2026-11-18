import Foundation
import IOKit.pwr_mgt
import TriCupCore

/// `AssertionControlling` backed by IOKit power assertions.
final class AssertionPowerManager: AssertionControlling {
    private var assertionIDs: [IOPMAssertionID] = []

    func acquire() throws {
        release()
        do {
            try createAssertion(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                name: "TriCup: keep system awake"
            )
            try createAssertion(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                name: "TriCup: keep display awake"
            )
        } catch {
            release()
            throw error
        }
    }

    func release() {
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs.removeAll()
    }

    private func createAssertion(type: String, name: String) throws {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            throw PowerError("IOPMAssertionCreateWithName(\(name)) failed: \(result)")
        }
        assertionIDs.append(id)
    }

    deinit {
        release()
    }
}

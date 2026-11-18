import Foundation
import IOKit.pwr_mgt
import TriCupCore

/// Power backend for the Sleep and Awake states, using IOKit power assertions.
///
/// - `.empty` releases every assertion, allowing normal idle/display sleep.
/// - `.half` holds a system-idle assertion and a display-idle assertion so the
///   system and display stay awake while the lid may still close.
/// - `.full`, for now, holds the same assertions. The closed-lid guarantee is
///   added in T5 through the privileged helper lease; until then it must not be
///   claimed as effective.
final class AssertionPowerManager: PowerManaging {
    private var assertionIDs: [IOPMAssertionID] = []

    func apply(_ state: CupState) throws {
        switch state {
        case .empty:
            releaseAll()
        case .half, .full:
            try acquireSystemAndDisplayAwake()
        }
    }

    private func acquireSystemAndDisplayAwake() throws {
        releaseAll()
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
            releaseAll()
            throw error
        }
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

    private func releaseAll() {
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs.removeAll()
    }

    deinit {
        releaseAll()
    }
}

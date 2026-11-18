import XCTest
@testable import TriCupCore

private final class FakeAssertions: AssertionControlling {
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    var failAcquire = false

    func acquire() throws {
        acquireCount += 1
        if failAcquire { throw PowerError("assertion failed") }
    }

    func release() { releaseCount += 1 }
}

private final class FakeLid: LidSleepControlling {
    var enabled = false
    private(set) var enableCount = 0
    private(set) var disableCount = 0
    var failEnable = false
    var alive = true

    func enable() throws {
        enableCount += 1
        if failEnable { throw PowerError("lease failed") }
        enabled = true
    }

    func disable() throws {
        disableCount += 1
        enabled = false
    }

    func checkAlive() -> Bool { alive }
}

final class SystemPowerManagerTests: XCTestCase {
    func testHalfAcquiresAssertionsWithoutLease() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let system = SystemPowerManager(assertions: assertions, lid: lid)

        try system.apply(.half)

        XCTAssertEqual(system.applied, .half)
        XCTAssertGreaterThanOrEqual(assertions.acquireCount, 1)
        XCTAssertFalse(lid.enabled)
    }

    func testFullAcquiresAssertionsAndLease() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let system = SystemPowerManager(assertions: assertions, lid: lid)

        try system.apply(.full)

        XCTAssertEqual(system.applied, .full)
        XCTAssertTrue(lid.enabled)
        XCTAssertGreaterThanOrEqual(assertions.acquireCount, 1)
    }

    func testEmptyReleasesLeaseAndAssertions() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let system = SystemPowerManager(assertions: assertions, lid: lid)
        try system.apply(.full)

        try system.apply(.empty)

        XCTAssertEqual(system.applied, .empty)
        XCTAssertFalse(lid.enabled)
        XCTAssertGreaterThanOrEqual(assertions.releaseCount, 1)
    }

    func testFailedFullRollsBackToPreviousState() {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        lid.failEnable = true
        let system = SystemPowerManager(assertions: assertions, lid: lid)

        XCTAssertThrowsError(try system.apply(.full))
        XCTAssertEqual(system.applied, .empty)
        XCTAssertFalse(lid.enabled)
        XCTAssertGreaterThanOrEqual(assertions.releaseCount, 1) // rolled back to empty
    }

    func testDisconnectDropsToEmptyAndNeverReAcquires() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let system = SystemPowerManager(assertions: assertions, lid: lid)
        try system.apply(.full)
        let enablesBeforeDisconnect = lid.enableCount

        var notified = false
        system.onUnexpectedDisconnect = { state in
            notified = true
            XCTAssertEqual(state, .empty)
        }

        lid.alive = false
        system.handleLidDisconnect()

        XCTAssertEqual(system.applied, .empty)
        XCTAssertFalse(lid.enabled)
        XCTAssertTrue(notified)
        XCTAssertEqual(lid.enableCount, enablesBeforeDisconnect) // no auto re-acquire
    }

    func testDisconnectWhileNotFullIsIgnored() {
        let system = SystemPowerManager(assertions: FakeAssertions(), lid: FakeLid())
        var notified = false
        system.onUnexpectedDisconnect = { _ in notified = true }

        system.handleLidDisconnect()

        XCTAssertFalse(notified)
        XCTAssertEqual(system.applied, .empty)
    }
}

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
    var failDisable = false
    var alive = true

    func enable() throws {
        enableCount += 1
        if failEnable { throw PowerError("lease failed") }
        enabled = true
    }

    func disable() throws {
        disableCount += 1
        if failDisable { throw PowerError("release failed") }
        enabled = false
    }

    func checkAlive() -> Bool { alive }

    func leaseActive() throws -> Bool { enabled }
}

private final class FakeReader: SleepStateReading {
    var value = false
    var fail = false

    func readSleepDisabled() throws -> Bool {
        if fail { throw PowerError("read failed") }
        return value
    }
}

final class SystemPowerManagerTests: XCTestCase {
    private func makeSystem(
        _ assertions: FakeAssertions = FakeAssertions(),
        _ lid: FakeLid = FakeLid(),
        _ reader: FakeReader = FakeReader()
    ) -> SystemPowerManager {
        SystemPowerManager(assertions: assertions, lid: lid, reader: reader)
    }

    func testHalfAcquiresAssertionsWithoutLease() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let system = makeSystem(assertions, lid)

        try system.apply(.half)

        XCTAssertEqual(system.applied, .half)
        XCTAssertGreaterThanOrEqual(assertions.acquireCount, 1)
        XCTAssertFalse(lid.enabled)
    }

    func testFullAcquiresAssertionsAndLease() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(assertions, lid, reader)

        try system.apply(.full)

        XCTAssertEqual(system.applied, .full)
        XCTAssertTrue(lid.enabled)
    }

    func testEmptyReleasesLeaseAndAssertions() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(assertions, lid, reader)
        try system.apply(.full)
        reader.value = false

        try system.apply(.empty)

        XCTAssertEqual(system.applied, .empty)
        XCTAssertFalse(lid.enabled)
        XCTAssertGreaterThanOrEqual(assertions.releaseCount, 1)
    }

    func testFailedFullRollsBackToPreviousState() {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        lid.failEnable = true
        let system = makeSystem(assertions, lid)

        XCTAssertThrowsError(try system.apply(.full))
        XCTAssertEqual(system.applied, .empty)
        XCTAssertFalse(lid.enabled)
        XCTAssertGreaterThanOrEqual(assertions.releaseCount, 1)
    }

    func testReleaseFailureOnFullToEmptyIsSurfaced() {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(assertions, lid, reader)
        try? system.apply(.full)

        lid.failDisable = true
        XCTAssertThrowsError(try system.apply(.empty)) { error in
            XCTAssertEqual((error as? PowerTransitionError)?.kind, .releaseFailed)
        }
        // Must NOT claim empty while the lease is still held.
        XCTAssertEqual(system.applied, .full)
        XCTAssertTrue(lid.enabled)
    }

    func testReleaseFailureOnFullToHalfIsSurfaced() {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(assertions, lid, reader)
        try? system.apply(.full)

        lid.failDisable = true
        XCTAssertThrowsError(try system.apply(.half)) { error in
            XCTAssertEqual((error as? PowerTransitionError)?.kind, .releaseFailed)
        }
        XCTAssertEqual(system.applied, .full)
        XCTAssertTrue(lid.enabled)
    }

    func testRollbackFailureMarksUncertain() {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(assertions, lid, reader)
        try? system.apply(.full)

        lid.failDisable = true
        lid.failEnable = true
        XCTAssertThrowsError(try system.apply(.empty)) { error in
            XCTAssertEqual((error as? PowerTransitionError)?.kind, .rollbackFailed)
        }
        XCTAssertTrue(system.uncertain)
    }

    func testFullVerificationMismatchRollsBack() {
        let reader = FakeReader(); reader.value = false // SleepDisabled not actually set
        let system = makeSystem(FakeAssertions(), FakeLid(), reader)

        XCTAssertThrowsError(try system.apply(.full)) { error in
            XCTAssertEqual((error as? PowerTransitionError)?.kind, .verificationFailed)
        }
        XCTAssertEqual(system.applied, .empty)
    }

    func testOriginalSleepDisabledTrueIsPreservedAndFlagged() throws {
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(FakeAssertions(), FakeLid(), reader)
        try system.apply(.full)

        try system.apply(.empty) // "restore" remains true because it was originally true

        XCTAssertEqual(system.applied, .empty)
        XCTAssertTrue(system.externallyBlocked)
    }

    func testUncertainWhenReaderFails() throws {
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(FakeAssertions(), FakeLid(), reader)
        try system.apply(.full)
        reader.fail = true

        try system.apply(.empty) // transition itself succeeds but cannot be verified
        XCTAssertTrue(system.uncertain)
    }

    func testDisconnectDropsToEmptyAndNeverReAcquires() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(assertions, lid, reader)
        try system.apply(.full)
        let enablesBefore = lid.enableCount

        reader.value = false
        lid.alive = false
        var notified = false
        system.onUnexpectedDisconnect = { state, uncertain in
            notified = true
            XCTAssertEqual(state, .empty)
            XCTAssertFalse(uncertain)
        }

        system.handleLidDisconnect()

        XCTAssertEqual(system.applied, .empty)
        XCTAssertFalse(lid.enabled)
        XCTAssertTrue(notified)
        XCTAssertEqual(lid.enableCount, enablesBefore) // no auto re-acquire
    }

    func testDisconnectUncertainWhenCannotConfirm() throws {
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(FakeAssertions(), lid, reader)
        try system.apply(.full)

        lid.failDisable = true
        reader.fail = true
        system.onUnexpectedDisconnect = { _, uncertain in
            XCTAssertTrue(uncertain)
        }
        system.handleLidDisconnect()
        XCTAssertTrue(system.uncertain)
    }
}

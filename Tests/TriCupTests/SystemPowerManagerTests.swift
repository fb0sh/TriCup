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
    var leaseQueryFails = false

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

    func leaseActive() throws -> Bool {
        if leaseQueryFails { throw PowerError("query failed") }
        return enabled
    }
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

    // MARK: - Wake re-assert

    func testReassertEmptyReleasesAssertions() {
        let assertions = FakeAssertions()
        let system = makeSystem(assertions, FakeLid(), FakeReader())
        XCTAssertTrue(system.reassertCurrentState())
        XCTAssertGreaterThanOrEqual(assertions.releaseCount, 1)
        XCTAssertFalse(system.uncertain)
    }

    func testReassertEmptyReadsActualSleepDisabled() {
        let reader = FakeReader(); reader.value = true // external SleepDisabled still on
        let system = makeSystem(FakeAssertions(), FakeLid(), reader)

        XCTAssertFalse(system.reassertCurrentState())
        XCTAssertTrue(system.externallyBlocked)
        XCTAssertFalse(system.uncertain)
    }

    func testReassertEmptyUncertainWhenReaderFails() {
        let reader = FakeReader(); reader.fail = true
        let system = makeSystem(FakeAssertions(), FakeLid(), reader)
        reader.fail = true

        XCTAssertFalse(system.reassertCurrentState())
        XCTAssertTrue(system.uncertain)
    }

    func testReassertHalfReacquiresAssertions() throws {
        let assertions = FakeAssertions()
        let reader = FakeReader(); reader.value = false
        let system = makeSystem(assertions, FakeLid(), reader)
        try system.apply(.half)
        let before = assertions.acquireCount

        XCTAssertTrue(system.reassertCurrentState())
        XCTAssertEqual(system.applied, .half)
        XCTAssertGreaterThan(assertions.acquireCount, before)
        XCTAssertFalse(system.uncertain)
    }

    func testReassertFullKeepsLeaseWithoutReEnable() throws {
        let assertions = FakeAssertions()
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(assertions, lid, reader)
        try system.apply(.full)
        let enableBefore = lid.enableCount
        let acquireBefore = assertions.acquireCount

        XCTAssertTrue(system.reassertCurrentState())
        XCTAssertEqual(system.applied, .full)
        XCTAssertEqual(lid.enableCount, enableBefore, "must not create a new lease on wake")
        XCTAssertGreaterThan(assertions.acquireCount, acquireBefore)
    }

    func testReassertFullDegradesWhenLeaseLost() throws {
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(FakeAssertions(), lid, reader)
        try system.apply(.full)
        let enableBefore = lid.enableCount

        lid.enabled = false
        reader.value = false
        var notified = false
        system.onUnexpectedDisconnect = { state, _ in
            notified = true
            XCTAssertEqual(state, .empty)
        }

        XCTAssertFalse(system.reassertCurrentState())
        XCTAssertEqual(system.applied, .empty)
        XCTAssertEqual(lid.enableCount, enableBefore, "must not auto re-acquire on wake")
        XCTAssertTrue(notified)
    }

    func testReassertFullDegradesWhenLeaseQueryFails() throws {
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(FakeAssertions(), lid, reader)
        try system.apply(.full)
        let enableBefore = lid.enableCount

        lid.leaseQueryFails = true
        reader.value = false
        XCTAssertFalse(system.reassertCurrentState())
        XCTAssertEqual(system.applied, .empty)
        XCTAssertEqual(lid.enableCount, enableBefore)
    }

    func testReassertIsIdempotent() throws {
        let lid = FakeLid()
        let reader = FakeReader(); reader.value = true
        let system = makeSystem(FakeAssertions(), lid, reader)
        try system.apply(.full)
        let enableBefore = lid.enableCount

        _ = system.reassertCurrentState()
        _ = system.reassertCurrentState()
        XCTAssertEqual(system.applied, .full)
        XCTAssertEqual(lid.enableCount, enableBefore)
    }
}

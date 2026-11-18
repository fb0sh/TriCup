import XCTest
@testable import TriCupCore

/// Records which states were applied and can be told to fail for a given state.
private final class RecordingPower: PowerManaging {
    var applied: [CupState] = []
    var failOn: CupState?

    func apply(_ state: CupState) throws {
        if state == failOn {
            throw PowerError("apply failed for \(state)")
        }
        applied.append(state)
    }
}

final class CupControllerTests: XCTestCase {
    func testDefaultStateIsEmpty() {
        let controller = CupController(power: RecordingPower())
        XCTAssertEqual(controller.state, .empty)
    }

    func testCycleOrderIsEmptyHalfFullEmpty() {
        let controller = CupController(power: RecordingPower())
        XCTAssertEqual(try? controller.cycle().get(), .half)
        XCTAssertEqual(try? controller.cycle().get(), .full)
        XCTAssertEqual(try? controller.cycle().get(), .empty)
    }

    func testCycleAppliesEveryTransition() {
        let power = RecordingPower()
        let controller = CupController(power: power)
        _ = controller.cycle()
        _ = controller.cycle()
        _ = controller.cycle()
        XCTAssertEqual(power.applied, [.half, .full, .empty])
    }

    func testSetStateDirectly() {
        let controller = CupController(power: RecordingPower())
        XCTAssertEqual(try? controller.setState(.full).get(), .full)
        XCTAssertEqual(controller.state, .full)
    }

    func testSelectingCurrentStateSkipsApply() {
        let power = RecordingPower()
        let controller = CupController(power: power)
        XCTAssertEqual(try? controller.setState(.empty).get(), .empty)
        XCTAssertTrue(power.applied.isEmpty)
    }

    func testApplyingHalfFromEmptyAcquiresAwake() {
        let power = RecordingPower()
        let controller = CupController(power: power)
        XCTAssertEqual(try? controller.setState(.half).get(), .half)
        XCTAssertEqual(power.applied, [.half])
    }

    func testFailureApplyingHalfKeepsEmpty() {
        let power = RecordingPower()
        power.failOn = .half
        let controller = CupController(power: power)
        XCTAssertThrowsError(try controller.setState(.half).get())
        XCTAssertEqual(controller.state, .empty)
    }

    func testFailedTransitionKeepsPreviousState() {
        let power = RecordingPower()
        power.failOn = .full
        let controller = CupController(power: power)

        let result = controller.setState(.full)
        guard case .failure(let error) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error as? PowerError, Optional(PowerError("apply failed for full")))
        XCTAssertEqual(controller.state, .empty)
    }
}

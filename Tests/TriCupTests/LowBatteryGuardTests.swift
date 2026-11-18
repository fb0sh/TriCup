import XCTest
@testable import TriCupCore

final class LowBatteryGuardTests: XCTestCase {
    private let guard20 = LowBatteryGuard(threshold: 20)

    func testBlocksAtExactly20OnBattery() {
        XCTAssertTrue(guard20.blocksFull(BatteryStatus(onBattery: true, percent: 20)))
    }

    func testBlocksBelow20OnBattery() {
        XCTAssertTrue(guard20.blocksFull(BatteryStatus(onBattery: true, percent: 5)))
    }

    func testAllowsAbove20OnBattery() {
        XCTAssertFalse(guard20.blocksFull(BatteryStatus(onBattery: true, percent: 21)))
    }

    func testNeverBlocksOnAC() {
        XCTAssertFalse(guard20.blocksFull(BatteryStatus(onBattery: false, percent: 5)))
    }

    func testNeverBlocksOnDesktopNoBattery() {
        // Desktops report full capacity on AC; no battery means not onBattery.
        XCTAssertFalse(guard20.blocksFull(BatteryStatus(onBattery: false, percent: 100)))
    }

    func testUnavailableBatteryInfoDoesNotBlock() {
        XCTAssertFalse(guard20.blocksFull(
            BatteryStatus(isAvailable: false, hasBattery: true, onBattery: true, percent: 5)
        ))
    }

    func testNoBatteryHardwareDoesNotBlock() {
        XCTAssertFalse(guard20.blocksFull(
            BatteryStatus(isAvailable: true, hasBattery: false, onBattery: false, percent: 0)
        ))
    }

    func testUnknownBatteryInfoOnBatteryDeviceBlocks() {
        // A MacBook whose battery info cannot be read must fail closed.
        XCTAssertTrue(guard20.blocksFull(
            BatteryStatus(isAvailable: false, hasBattery: true, onBattery: false, percent: 0)
        ))
    }

    func testUnknownBatteryInfoWithNoBatteryDoesNotBlock() {
        XCTAssertFalse(guard20.blocksFull(
            BatteryStatus(isAvailable: false, hasBattery: false, onBattery: false, percent: 0)
        ))
    }

    func testShouldExitFullWhenBatteryUnknownOnBatteryDevice() {
        XCTAssertTrue(guard20.shouldExitFull(
            BatteryStatus(isAvailable: false, hasBattery: true, onBattery: false, percent: 0)
        ))
    }

    func testExitFullMatchesBlockRule() {
        let low = BatteryStatus(onBattery: true, percent: 20)
        XCTAssertTrue(guard20.shouldExitFull(low))
        XCTAssertFalse(guard20.shouldExitFull(BatteryStatus(onBattery: false, percent: 20)))
    }
}

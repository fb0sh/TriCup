import XCTest
@testable import TriCupCore

final class LowBatteryGuardTests: XCTestCase {
    private let guard15 = LowBatteryGuard() // default threshold is 15%

    func testDefaultThresholdIs15() {
        XCTAssertEqual(guard15.threshold, 15)
    }

    func testBlocksAtExactly15OnBattery() {
        XCTAssertTrue(guard15.blocksFull(BatteryStatus(onBattery: true, percent: 15)))
    }

    func testBlocksBelow15OnBattery() {
        XCTAssertTrue(guard15.blocksFull(BatteryStatus(onBattery: true, percent: 5)))
    }

    func testAllowsAbove15OnBattery() {
        XCTAssertFalse(guard15.blocksFull(BatteryStatus(onBattery: true, percent: 16)))
    }

    func testNeverBlocksOnAC() {
        XCTAssertFalse(guard15.blocksFull(BatteryStatus(onBattery: false, percent: 5)))
    }

    func testNeverBlocksOnDesktopNoBattery() {
        // Desktops report full capacity on AC; no battery means not onBattery.
        XCTAssertFalse(guard15.blocksFull(BatteryStatus(onBattery: false, percent: 100)))
    }

    func testUnavailableBatteryInfoBlocksWhenBatteryEquipped() {
        // Fail-closed policy: unknown battery info on a battery-equipped Mac
        // must block full mode.
        XCTAssertTrue(guard15.blocksFull(
            BatteryStatus(isAvailable: false, hasBattery: true, onBattery: true, percent: 5)
        ))
    }

    func testNoBatteryHardwareDoesNotBlock() {
        XCTAssertFalse(guard15.blocksFull(
            BatteryStatus(isAvailable: true, hasBattery: false, onBattery: false, percent: 0)
        ))
    }

    func testUnknownBatteryInfoOnBatteryDeviceBlocks() {
        // A MacBook whose battery info cannot be read must fail closed.
        XCTAssertTrue(guard15.blocksFull(
            BatteryStatus(isAvailable: false, hasBattery: true, onBattery: false, percent: 0)
        ))
    }

    func testUnknownBatteryInfoWithNoBatteryDoesNotBlock() {
        XCTAssertFalse(guard15.blocksFull(
            BatteryStatus(isAvailable: false, hasBattery: false, onBattery: false, percent: 0)
        ))
    }

    func testShouldExitFullWhenBatteryUnknownOnBatteryDevice() {
        XCTAssertTrue(guard15.shouldExitFull(
            BatteryStatus(isAvailable: false, hasBattery: true, onBattery: false, percent: 0)
        ))
    }

    func testExitFullMatchesBlockRule() {
        let low = BatteryStatus(onBattery: true, percent: 15)
        XCTAssertTrue(guard15.shouldExitFull(low))
        XCTAssertFalse(guard15.shouldExitFull(BatteryStatus(onBattery: false, percent: 15)))
    }
}

import XCTest
@testable import TriCupCore

final class UninstallSafetyTests: XCTestCase {
    func testUnknownLeaseStateIsUnsafe() {
        XCTAssertFalse(UninstallSafety.canUninstall(leaseActive: nil, hasResidualRecord: false))
    }

    func testActiveLeaseIsUnsafe() {
        XCTAssertFalse(UninstallSafety.canUninstall(leaseActive: true, hasResidualRecord: false))
    }

    func testResidualRecordIsUnsafe() {
        XCTAssertFalse(UninstallSafety.canUninstall(leaseActive: false, hasResidualRecord: true))
    }

    func testCleanInactiveIsSafe() {
        XCTAssertTrue(UninstallSafety.canUninstall(leaseActive: false, hasResidualRecord: false))
    }
}

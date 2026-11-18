import XCTest
@testable import TriCupCore

final class SleepDisabledParserTests: XCTestCase {
    func testParsesTrue() throws {
        XCTAssertTrue(try SleepDisabledParser.parse("SleepDisabled\t\t1\n"))
    }

    func testParsesFalse() throws {
        XCTAssertFalse(try SleepDisabledParser.parse("SleepDisabled\t\t0\n"))
    }

    func testParsesWithSurroundingLines() throws {
        let text = """
        System-wide power settings:
        Currently in use:
         standby 1
         SleepDisabled 1
         hibernatefile /var/vm/sleepimage
        """
        XCTAssertTrue(try SleepDisabledParser.parse(text))
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(try SleepDisabledParser.parse("System-wide power settings:\n standby 1\n"))
    }

    func testInvalidValueThrows() {
        XCTAssertThrowsError(try SleepDisabledParser.parse("SleepDisabled maybe\n"))
    }
}

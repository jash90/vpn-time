import XCTest
@testable import VPNTimeCore

final class TimeFormatTests: XCTestCase {
    func testHoursMinutesPadsMinutesToTwoDigits() {
        XCTAssertEqual(hoursMinutes(0), "0h 00m")
        XCTAssertEqual(hoursMinutes(5400), "1h 30m")
        XCTAssertEqual(hoursMinutes(902880), "250h 48m")
    }

    func testHoursMinutesTruncatesSeconds() {
        XCTAssertEqual(hoursMinutes(59), "0h 00m")
        XCTAssertEqual(hoursMinutes(3659), "1h 00m")
    }

    func testCounterKeepsTheLeadingSpaceThatSeparatesItFromTheIcon() {
        XCTAssertEqual(counter(434820), " 120:47")
        XCTAssertEqual(counter(0), " 0:00")
    }
}

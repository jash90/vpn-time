import XCTest
@testable import VPNTimeCore

final class TotalsTests: XCTestCase {
    func testISOCalendarStartsWeekOnMonday() {
        let calendar = Calendar.vpnTimeISO
        XCTAssertEqual(calendar.firstWeekday, 2)
        XCTAssertEqual(calendar.timeZone, TimeZone.current)
    }
}

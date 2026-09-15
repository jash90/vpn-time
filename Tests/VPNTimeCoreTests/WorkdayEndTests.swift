import XCTest
@testable import VPNTimeCore

final class WorkdayEndTests: XCTestCase {
    private let calendar = Calendar.vpnTimeISO
    private let end = WorkdayEnd(hour: 17, minute: 0)

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: string)!
    }

    func testDoesNotFireBeforeTheConfiguredTime() {
        XCTAssertFalse(
            end.shouldFire(now: date("2026-09-15 16:59:59"), lastFired: nil, calendar: calendar)
        )
    }

    func testFiresOnceTheConfiguredTimeHasArrived() {
        XCTAssertTrue(
            end.shouldFire(now: date("2026-09-15 17:00:00"), lastFired: nil, calendar: calendar)
        )
        XCTAssertTrue(
            end.shouldFire(now: date("2026-09-15 23:14:00"), lastFired: nil, calendar: calendar)
        )
    }

    func testDoesNotFireTwiceOnTheSameDay() {
        XCTAssertFalse(
            end.shouldFire(
                now: date("2026-09-15 18:00:00"),
                lastFired: date("2026-09-15 17:00:05"),
                calendar: calendar
            )
        )
    }

    func testFiresAgainTheNextDay() {
        XCTAssertTrue(
            end.shouldFire(
                now: date("2026-09-16 17:00:01"),
                lastFired: date("2026-09-15 17:00:05"),
                calendar: calendar
            )
        )
    }

    func testSurvivesAnAppRestartLaterTheSameEvening() {
        XCTAssertFalse(
            end.shouldFire(
                now: date("2026-09-15 22:30:00"),
                lastFired: date("2026-09-15 17:00:05"),
                calendar: calendar
            )
        )
    }

    func testMinutesOfDayRoundTrip() {
        XCTAssertEqual(end.minutesOfDay, 1020)
        XCTAssertEqual(WorkdayEnd(minutesOfDay: 1020), end)
        XCTAssertEqual(WorkdayEnd(minutesOfDay: 990), WorkdayEnd(hour: 16, minute: 30))
        XCTAssertNil(WorkdayEnd(minutesOfDay: -1))
        XCTAssertNil(WorkdayEnd(minutesOfDay: 1440))
    }
}

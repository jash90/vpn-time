import XCTest
@testable import VPNTimeCore

final class TotalsTests: XCTestCase {
    func testISOCalendarStartsWeekOnMonday() {
        let calendar = Calendar.vpnTimeISO
        XCTAssertEqual(calendar.firstWeekday, 2)
        XCTAssertEqual(calendar.timeZone, TimeZone.current)
    }

    private let calendar = Calendar.vpnTimeISO

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: string)!
    }

    func testMultiDaySessionIsSplitAcrossTheDaysItSpans() {
        let now = date("2026-09-09 20:00:00")
        let totals = Totals(calendar: calendar, now: now)
        // 2026-09-07 07:31:22 → 2026-09-09 18:31:42
        let sessions = [Session(start: date("2026-09-07 07:31:22"), duration: 212420)]

        XCTAssertEqual(totals.total(.today, sessions: sessions, active: nil), 18 * 3600 + 31 * 60 + 42)
        XCTAssertEqual(totals.total(.week, sessions: sessions, active: nil), 212420)
    }

    func testActiveSessionFromAnEarlierDayCountsTodayFromMidnight() {
        let now = date("2026-10-27 10:16:00")
        let start = date("2026-10-26 07:58:00")
        let totals = Totals(calendar: calendar, now: now)
        let active = (start, "Office_VPN_bartlomiej_zimny")

        XCTAssertEqual(totals.total(.today, sessions: [], active: active), 10 * 3600 + 16 * 60)
        XCTAssertEqual(totals.total(.week, sessions: [], active: active), Int(now.timeIntervalSince(start)))
    }

    func testActiveSessionFromThePreviousWeekCountsOnlyThisWeeksPart() {
        let now = date("2026-09-15 08:31:30")
        let start = date("2026-09-10 07:44:00")
        let totals = Totals(calendar: calendar, now: now)
        let active = (start, "Office_VPN_bartlomiej_zimny")

        XCTAssertEqual(totals.total(.today, sessions: [], active: active), 8 * 3600 + 31 * 60 + 30)
        XCTAssertEqual(
            totals.total(.week, sessions: [], active: active),
            Int(now.timeIntervalSince(date("2026-09-14 00:00:00")))
        )
        XCTAssertEqual(
            totals.total(.month, sessions: [], active: active),
            Int(now.timeIntervalSince(start))
        )
    }

    func testTodayBucketSumsFinishedSessionsStartedToday() {
        let now = date("2026-09-15 18:00:00")
        let totals = Totals(calendar: calendar, now: now)
        let sessions = [
            Session(start: date("2026-09-15 08:00:00"), duration: 3600),
            Session(start: date("2026-09-15 10:00:00"), duration: 1800),
            Session(start: date("2026-09-14 10:00:00"), duration: 9999),
        ]

        XCTAssertEqual(totals.total(.today, sessions: sessions, active: nil), 5400)
    }

    func testWeekBucketUsesISOWeekSoSundayBelongsToTheWeekThatStartedMonday() {
        let totals = Totals(calendar: calendar, now: date("2026-09-20 12:00:00"))
        let sessions = [Session(start: date("2026-09-14 09:00:00"), duration: 600)]

        XCTAssertEqual(totals.total(.week, sessions: sessions, active: nil), 600)
    }
}

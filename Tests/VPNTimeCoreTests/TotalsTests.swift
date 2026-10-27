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

    private func record(_ start: String, _ end: String?) -> WorkdayRecord {
        WorkdayRecord(day: String(start.prefix(10)), start: date(start), end: end.map(date), source: .activity)
    }

    func testSplitSeparatesTheWorkdayWithoutTheVPN() {
        let totals = Totals(calendar: calendar, now: date("2026-10-27 18:00:00"))
        let split = totals.split(
            .today,
            sessions: [Session(start: date("2026-10-27 09:00:00"), duration: 4 * 3600)],
            active: nil,
            records: [record("2026-10-27 08:00:00", "2026-10-27 16:00:00")]
        )

        XCTAssertEqual(split, WorkSplit(vpn: 4 * 3600, noVPN: 4 * 3600))
        XCTAssertEqual(split.total, 8 * 3600)
    }

    func testSplitCountsTodaysRunningDayUpToNow() {
        let totals = Totals(calendar: calendar, now: date("2026-10-27 12:00:00"))
        let split = totals.split(
            .today,
            sessions: [],
            active: (date("2026-10-27 10:00:00"), "Office_VPN"),
            records: [record("2026-10-27 08:00:00", nil)]
        )

        XCTAssertEqual(split, WorkSplit(vpn: 2 * 3600, noVPN: 2 * 3600))
    }

    func testVPNAfterTheWorkdayEndedIsNoWork() {
        let totals = Totals(calendar: calendar, now: date("2026-10-27 23:00:00"))
        let split = totals.split(
            .today,
            sessions: [
                Session(start: date("2026-10-27 15:00:00"), duration: 3600),
                Session(start: date("2026-10-27 20:00:00"), duration: 3600),
            ],
            active: nil,
            records: [record("2026-10-27 08:00:00", "2026-10-27 16:00:00")]
        )

        XCTAssertEqual(split, WorkSplit(vpn: 3600, noVPN: 7 * 3600))
    }

    func testADayWithoutAnEndCountsAllItsVPNTime() {
        let totals = Totals(calendar: calendar, now: date("2026-10-28 12:00:00"))
        let split = totals.split(
            .week,
            sessions: [Session(start: date("2026-10-27 09:00:00"), duration: 3600)],
            active: nil,
            records: [record("2026-10-27 08:00:00", nil)]
        )

        XCTAssertEqual(split, WorkSplit(vpn: 3600, noVPN: 0))
    }

    func testSplitWithoutAWorkdayIsTheVPNTime() {
        let totals = Totals(calendar: calendar, now: date("2026-10-27 18:00:00"))
        let split = totals.split(
            .today,
            sessions: [Session(start: date("2026-10-27 09:00:00"), duration: 3600)],
            active: nil,
            records: []
        )

        XCTAssertEqual(split, WorkSplit(vpn: 3600, noVPN: 0))
    }

    func testWeekSplitSumsTheWeeksWorkdays() {
        let totals = Totals(calendar: calendar, now: date("2026-10-28 12:00:00"))
        let split = totals.split(
            .week,
            sessions: [Session(start: date("2026-10-26 09:00:00"), duration: 3600)],
            active: nil,
            records: [
                record("2026-10-26 08:00:00", "2026-10-26 10:00:00"),
                record("2026-10-27 08:00:00", "2026-10-27 09:00:00"),
                record("2026-10-25 08:00:00", "2026-10-25 18:00:00"),
                record("2026-10-24 08:00:00", nil),
            ]
        )

        XCTAssertEqual(split, WorkSplit(vpn: 3600, noVPN: 3600 + 3600))
    }

    func testAWorkdayPastMidnightIsNotCountedTwice() {
        let totals = Totals(calendar: calendar, now: date("2026-10-31 12:00:00"))
        // Friday 20:00 to Saturday 02:00 on the VPN; Saturday has no workday.
        let split = totals.split(
            .week,
            sessions: [Session(start: date("2026-10-30 20:00:00"), duration: 6 * 3600)],
            active: nil,
            records: [record("2026-10-30 20:00:00", "2026-10-31 02:00:00")]
        )

        XCTAssertEqual(split, WorkSplit(vpn: 6 * 3600, noVPN: 0))
    }

    func testAWorkdayPastMidnightKeepsItsTimeWhenTheNextDayHasOne() {
        let totals = Totals(calendar: calendar, now: date("2026-10-27 12:00:00"))
        let monday = record("2026-10-26 20:00:00", "2026-10-27 01:00:00")
        let split = totals.split(
            .week,
            sessions: [Session(start: date("2026-10-26 20:00:00"), duration: 5 * 3600)],
            active: nil,
            records: [monday, record("2026-10-27 09:00:00", "2026-10-27 12:00:00")]
        )

        XCTAssertEqual(split, WorkSplit(vpn: 5 * 3600, noVPN: 3 * 3600))
        XCTAssertEqual(
            totals.split(
                record: monday,
                day: DateInterval(start: date("2026-10-26 00:00:00"), end: date("2026-10-27 00:00:00")),
                sessions: [Session(start: date("2026-10-26 20:00:00"), duration: 5 * 3600)],
                active: nil
            ).total,
            monday.duration
        )
    }
}

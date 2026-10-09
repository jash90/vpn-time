import XCTest
@testable import VPNTimeCore

final class WorkdayHistoryTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + UUID().uuidString + ".csv"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: string)!
    }

    private func contents() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func session(_ start: String, _ duration: Int) -> Session {
        Session(start: date(start), duration: duration)
    }

    func testRecordReplacesTheDaysRow() {
        let history = WorkdayHistory(path: path)
        let day = date("2026-10-02 12:00:00")

        history.record(WorkdayStart(date: date("2026-10-02 08:40:00"), source: .activity), end: nil, day: day)
        history.record(
            WorkdayStart(date: date("2026-10-02 08:00:00"), source: .manual),
            end: date("2026-10-02 16:00:00"),
            day: day
        )

        XCTAssertEqual(
            contents(),
            "date,start_iso,end_iso,source\n2026-10-02,2026-10-02 08:00:00,2026-10-02 16:00:00,manual\n"
        )
    }

    func testRecordingNothingRemovesTheRow() {
        let history = WorkdayHistory(path: path)
        let day = date("2026-10-02 12:00:00")

        history.record(WorkdayStart(date: date("2026-10-02 08:40:00"), source: .vpn), end: nil, day: day)
        history.record(nil, end: nil, day: day)

        XCTAssertEqual(contents(), "date,start_iso,end_iso,source\n")
    }

    func testReadsRowsWithoutTheEndColumn() throws {
        try "date,start_iso,source\n2026-09-15,2026-09-15 12:00:48,vpn\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(WorkdayHistory(path: path).records(), [
            WorkdayRecord(day: "2026-09-15", start: date("2026-09-15 12:00:48"), end: nil, source: .vpn),
        ])
    }

    func testEditingADayMarksItEditedAndKeepsTheEnd() {
        let history = WorkdayHistory(path: path)
        history.set(
            day: date("2026-09-30 12:00:00"),
            start: date("2026-09-30 08:00:00"),
            end: date("2026-09-30 16:30:00")
        )

        let record = history.entries()["2026-09-30"]
        XCTAssertEqual(record?.source, .edited)
        XCTAssertEqual(record?.duration, 30_600)

        history.remove(day: date("2026-09-30 12:00:00"))
        XCTAssertTrue(history.entries().isEmpty)
    }

    func testBackfillAddsPastWorkdaysWithTheirEnd() {
        let history = WorkdayHistory(path: path)
        history.set(
            day: date("2026-09-30 12:00:00"),
            start: date("2026-09-30 07:00:00"),
            end: nil
        )
        // Yesterday's row as recorded during the day: start known, no end yet.
        history.record(
            WorkdayStart(date: date("2026-10-01 08:30:00"), source: .activity),
            end: nil,
            day: date("2026-10-01 12:00:00")
        )

        history.backfill(
            detector: WorkdayStartDetector(),
            streaks: [
                ActivityStreak(start: date("2026-09-29 10:00:00"), end: date("2026-09-29 11:00:00")),
                ActivityStreak(start: date("2026-10-01 08:30:00"), end: date("2026-10-01 16:00:00")),
            ],
            sessions: [
                session("2026-09-28 09:00:00", 3600),
                session("2026-09-30 09:00:00", 3600),
                session("2026-10-01 08:35:00", 3600),
                session("2026-10-01 12:00:00", 14_400),
                session("2026-10-02 08:00:00", 600),
            ],
            today: date("2026-10-02 12:00:00")
        )

        XCTAssertEqual(contents(), """
        date,start_iso,end_iso,source
        2026-09-28,2026-09-28 09:00:00,2026-09-28 10:00:00,vpn
        2026-09-30,2026-09-30 07:00:00,,edited
        2026-10-01,2026-10-01 08:30:00,2026-10-01 16:00:00,activity

        """)
    }
}

final class WorkdayTotalsTests: XCTestCase {
    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: string)!
    }

    private func record(_ day: String, _ start: String, _ end: String?) -> WorkdayRecord {
        WorkdayRecord(
            day: day,
            start: date("\(day) \(start):00"),
            end: end.map { date("\(day) \($0):00") },
            source: .activity
        )
    }

    // Friday 2026-10-09 14:00; the ISO week starts on Monday 2026-10-05.
    private lazy var now = date("2026-10-09 14:00:00")
    private lazy var records = [
        record("2026-10-09", "08:00", "16:00"),   // today, end still ahead: 6h so far
        record("2026-10-08", "08:00", "15:30"),   // 7h 30m
        record("2026-10-05", "09:00", "17:00"),   // 8h, Monday of this week
        record("2026-10-02", "08:00", "16:00"),   // last week, this month
        record("2026-10-01", "08:00", nil),       // no end: not counted
        record("2026-09-30", "08:00", "16:00"),   // last month
    ]

    func testTodayCountsOnlyUpToNow() {
        XCTAssertEqual(WorkdayTotals(now: now).total(.today, records: records), 6 * 3600)
    }

    func testWeekAndMonth() {
        let totals = WorkdayTotals(now: now)

        XCTAssertEqual(totals.total(.week, records: records), (6 * 60 + 7 * 60 + 30 + 8 * 60) * 60)
        XCTAssertEqual(totals.total(.month, records: records), (6 * 60 + 7 * 60 + 30 + 8 * 60 + 8 * 60) * 60)
    }

    func testTodayStoppedEarlierCountsUpToTheStop() {
        let stopped = [record("2026-10-09", "08:00", "11:15")]

        XCTAssertEqual(WorkdayTotals(now: now).total(.today, records: stopped), 3 * 3600 + 15 * 60)
    }

    func testTodayWithoutEndCountsUpToNow() {
        let open = [record("2026-10-09", "13:00", nil)]

        XCTAssertEqual(WorkdayTotals(now: now).total(.today, records: open), 3600)
    }
}

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

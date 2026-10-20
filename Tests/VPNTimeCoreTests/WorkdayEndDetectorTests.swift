import XCTest
@testable import VPNTimeCore

final class WorkdayEndDetectorTests: XCTestCase {
    private let calendar = Calendar.vpnTimeISO
    private lazy var detector = WorkdayEndDetector(calendar: calendar)

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: string)!
    }

    private func streak(_ start: String, _ end: String) -> ActivityStreak {
        ActivityStreak(start: date(start), end: date(end))
    }

    private func session(_ start: String, _ duration: Int) -> Session {
        Session(start: date(start), duration: duration)
    }

    func testEndsAtTheLastVPNSessionWhenNothingFollowsIt() {
        let end = detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-02 09:00:00", 3600), session("2026-10-02 15:00:00", 3600)],
            streaks: [streak("2026-10-02 08:50:00", "2026-10-02 10:00:00")]
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-02 16:00:00"), source: .vpn))
    }

    func testActivityAfterTheLastDisconnectExtendsTheEnd() {
        let end = detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-02 09:00:00", 3600), session("2026-10-02 15:00:00", 3600)],
            streaks: [streak("2026-10-02 14:50:00", "2026-10-02 17:30:00")]
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-02 17:30:00"), source: .activity))
    }

    func testChainedStreaksExtendTheEnd() {
        let end = detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-02 15:00:00", 3600)],
            streaks: [
                streak("2026-10-02 15:50:00", "2026-10-02 16:00:00"),
                streak("2026-10-02 16:20:00", "2026-10-02 17:00:00"),
            ]
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-02 17:00:00"), source: .activity))
    }

    // A streak picked up again much later is a new block of work, not a
    // continuation of the workday.
    func testAStreakAfterALongBreakDoesNotCount() {
        let end = detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-02 15:00:00", 3600)],
            streaks: [
                streak("2026-10-02 14:50:00", "2026-10-02 16:05:00"),
                streak("2026-10-02 19:00:00", "2026-10-02 20:00:00"),
            ]
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-02 16:05:00"), source: .activity))
    }

    func testActivityPastMidnightIsClippedToTheDay() {
        let end = detector.detect(
            day: date("2026-10-02 23:00:00"),
            sessions: [session("2026-10-02 22:00:00", 3600)],
            streaks: [streak("2026-10-02 22:00:00", "2026-10-03 01:30:00")]
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-03 00:00:00"), source: .activity))
    }

    func testNoVPNThatDayIsNotAWorkday() {
        XCTAssertNil(detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-01 09:00:00", 3600)],
            streaks: [streak("2026-10-02 08:00:00", "2026-10-02 16:00:00")]
        ))
    }

    func testActivityDisabledEndsAtTheVPNSession() {
        let end = detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-02 15:00:00", 3600)],
            streaks: [streak("2026-10-02 14:50:00", "2026-10-02 17:30:00")],
            useActivity: false
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-02 16:00:00"), source: .vpn))
    }

    // A session running past midnight ends where the VPN ended, even when the
    // activity around it is cut at the end of the day.
    func testASessionPastMidnightIsNotClippedBeforeTheVPNEnd() {
        let end = detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-02 22:00:00", 4 * 3600)],
            streaks: [streak("2026-10-02 21:50:00", "2026-10-03 03:00:00")]
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-03 02:00:00"), source: .vpn))
    }

    // A streak ending exactly at the disconnect adds nothing, so the VPN is
    // the source.
    func testAStreakEndingAtTheDisconnectKeepsTheVPNSource() {
        let end = detector.detect(
            day: date("2026-10-02 12:00:00"),
            sessions: [session("2026-10-02 09:00:00", 3600)],
            streaks: [streak("2026-10-02 08:50:00", "2026-10-02 10:00:00")]
        )

        XCTAssertEqual(end, WorkdayEndPoint(date: date("2026-10-02 10:00:00"), source: .vpn))
    }
}

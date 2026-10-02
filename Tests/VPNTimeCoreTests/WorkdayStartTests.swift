import XCTest
@testable import VPNTimeCore

final class WorkdayStartTests: XCTestCase {
    private let calendar = Calendar.vpnTimeISO
    private lazy var detector = WorkdayStartDetector(calendar: calendar)

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

    func testAMorningGlanceDoesNotStartTheDay() {
        let start = detector.detect(
            day: date("2026-10-02 12:00:00"),
            streaks: [
                streak("2026-10-02 07:00:00", "2026-10-02 07:05:00"),
                streak("2026-10-02 08:40:00", "2026-10-02 12:00:00"),
            ],
            vpnStarts: [date("2026-10-02 08:45:00")]
        )

        XCTAssertEqual(start, WorkdayStart(date: date("2026-10-02 08:40:00"), source: .activity))
    }

    func testVPNRightAfterAShortBreakStillBelongsToTheStreak() {
        let start = detector.detect(
            day: date("2026-10-02 12:00:00"),
            streaks: [streak("2026-10-02 08:00:00", "2026-10-02 08:20:00")],
            vpnStarts: [date("2026-10-02 08:45:00")]
        )

        XCTAssertEqual(start, WorkdayStart(date: date("2026-10-02 08:00:00"), source: .activity))
    }

    func testVPNWithoutActivityUsesTheFirstConnection() {
        let start = detector.detect(
            day: date("2026-10-02 12:00:00"),
            streaks: [streak("2026-10-02 07:00:00", "2026-10-02 07:05:00")],
            vpnStarts: [date("2026-10-02 10:00:00"), date("2026-10-02 09:00:00")]
        )

        XCTAssertEqual(start, WorkdayStart(date: date("2026-10-02 09:00:00"), source: .vpn))
    }

    func testNoVPNYieldsAProvisionalStart() {
        let start = detector.detect(
            day: date("2026-10-02 12:00:00"),
            streaks: [
                streak("2026-10-02 09:30:00", "2026-10-02 10:00:00"),
                streak("2026-10-02 07:00:00", "2026-10-02 07:05:00"),
            ],
            vpnStarts: [date("2026-10-01 09:00:00")]
        )

        XCTAssertEqual(
            start,
            WorkdayStart(date: date("2026-10-02 07:00:00"), source: .activity, provisional: true)
        )
    }

    func testAStreakCrossingMidnightIsClipped() {
        let start = detector.detect(
            day: date("2026-10-02 12:00:00"),
            streaks: [streak("2026-10-01 23:00:00", "2026-10-02 01:00:00")],
            vpnStarts: [date("2026-10-02 00:30:00")]
        )

        XCTAssertEqual(start, WorkdayStart(date: date("2026-10-02 00:00:00"), source: .activity))
    }

    func testNothingToDetect() {
        XCTAssertNil(detector.detect(day: date("2026-10-02 12:00:00"), streaks: [], vpnStarts: []))
    }

    func testTodaysManualStartWins() {
        let start = detector.resolve(
            now: date("2026-10-02 12:00:00"),
            manual: date("2026-10-02 07:30:00"),
            detectionEnabled: true,
            streaks: [],
            vpnStarts: [date("2026-10-02 09:00:00")]
        )

        XCTAssertEqual(start, WorkdayStart(date: date("2026-10-02 07:30:00"), source: .manual))
    }

    func testYesterdaysManualStartIsIgnored() {
        let start = detector.resolve(
            now: date("2026-10-02 12:00:00"),
            manual: date("2026-10-01 07:30:00"),
            detectionEnabled: true,
            streaks: [],
            vpnStarts: [date("2026-10-02 09:00:00")]
        )

        XCTAssertEqual(start, WorkdayStart(date: date("2026-10-02 09:00:00"), source: .vpn))
    }

    func testDisabledDetectionLeavesOnlyTheManualStart() {
        let vpn = [date("2026-10-02 09:00:00")]
        let now = date("2026-10-02 12:00:00")

        XCTAssertNil(detector.resolve(
            now: now, manual: nil, detectionEnabled: false, streaks: [], vpnStarts: vpn
        ))
        XCTAssertEqual(
            detector.resolve(
                now: now, manual: date("2026-10-02 08:00:00"), detectionEnabled: false,
                streaks: [], vpnStarts: vpn
            )?.source,
            .manual
        )
    }
}

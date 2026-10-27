import Foundation

public enum WorkdayEndSource: String {
    // End of the day's last VPN session.
    case vpn
    // Activity carried on after the last VPN session.
    case activity
    // The inactivity question: answered "Zakończ pracę" or left unanswered.
    case idle
    // Typed for today in "Dni pracy".
    case manual
    // The end rule's planned time: only a guess, may be replaced by backfill.
    case planned
    // A past day corrected by hand.
    case edited
}

public struct WorkdayEndPoint: Hashable {
    public let date: Date
    public let source: WorkdayEndSource

    public init(date: Date, source: WorkdayEndSource) {
        self.date = date
        self.source = source
    }
}

public struct WorkdayEndDetector {
    private let calendar: Calendar
    private let gap: TimeInterval
    // Off in the no-VPN mode: a day without the VPN ends with its last activity.
    private let requireVPN: Bool

    public init(calendar: Calendar = .vpnTimeISO, gap: TimeInterval = 1800, requireVPN: Bool = true) {
        self.calendar = calendar
        self.gap = gap
        self.requireVPN = requireVPN
    }

    // The end is the end of the day's last VPN session, extended over the
    // activity streak that contains it (or picks up right after it) and any
    // streaks chained on from there — mirroring how start detection reaches
    // back over the streak to the day's first input.
    public func detect(
        day: Date,
        sessions: [Session],
        streaks: [ActivityStreak],
        useActivity: Bool = true
    ) -> WorkdayEndPoint? {
        let dayStart = calendar.startOfDay(for: day)
        let sessionEnds = sessions
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .map { $0.start.addingTimeInterval(TimeInterval($0.duration)) }

        // No VPN session that day: not a workday, unless the VPN is not needed.
        guard let vpnEnd = sessionEnds.max() else {
            return requireVPN ? nil : lastActivity(day: dayStart, streaks: streaks)
        }

        guard useActivity,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return WorkdayEndPoint(date: vpnEnd, source: .vpn)
        }

        let dayStreaks = streaks
            .filter { $0.start < dayEnd && $0.end >= dayStart }
            .map { ActivityStreak(start: max($0.start, dayStart), end: $0.end) }
            .sorted { $0.start < $1.start }

        var end = vpnEnd

        for streak in dayStreaks where streak.start <= end.addingTimeInterval(gap) && streak.end >= end {
            end = streak.end
        }

        // Activity is clipped to the day, but never to before the VPN end: a
        // session running past midnight still ends where the VPN ended.
        let clipped = max(vpnEnd, min(end, dayEnd))

        if clipped > vpnEnd {
            return WorkdayEndPoint(date: clipped, source: .activity)
        }

        return WorkdayEndPoint(date: vpnEnd, source: .vpn)
    }

    private func lastActivity(day dayStart: Date, streaks: [ActivityStreak]) -> WorkdayEndPoint? {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }

        return streaks
            .filter { $0.start < dayEnd && $0.end >= dayStart }
            .map { min($0.end, dayEnd) }
            .max()
            .map { WorkdayEndPoint(date: $0, source: .activity) }
    }
}

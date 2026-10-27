import Foundation

public enum WorkdayStartSource: String {
    case manual
    case vpn
    case activity
    // A past day corrected by hand in the work-time form.
    case edited
}

public struct WorkdayStart: Hashable {
    public let date: Date
    public let source: WorkdayStartSource
    // No VPN connection that day yet, so this is only the first activity.
    public let provisional: Bool

    public init(date: Date, source: WorkdayStartSource, provisional: Bool = false) {
        self.date = date
        self.source = source
        self.provisional = provisional
    }
}

public struct WorkdayStartDetector {
    private let calendar: Calendar
    private let gap: TimeInterval
    // Off in the no-VPN mode: the day's activity is then a real start.
    private let requireVPN: Bool
    // In the no-VPN mode, the activity it takes to count as work: a glance
    // at the laptop before work must not start (and soon stop) the day.
    private let minimumWork: TimeInterval

    public init(
        calendar: Calendar = .vpnTimeISO,
        gap: TimeInterval = 1800,
        requireVPN: Bool = true,
        minimumWork: TimeInterval = 900
    ) {
        self.calendar = calendar
        self.gap = gap
        self.requireVPN = requireVPN
        self.minimumWork = minimumWork
    }

    // The start is the beginning of the activity streak that contains the day's
    // first VPN connection, so touching the laptop early in the morning does
    // not count unless the work carried on from there without a long break.
    // `carriedOver` is a session that began on an earlier day and ran into
    // this one: when it was still up at the day's first activity, that
    // activity is when the VPN was there for the day.
    public func detect(
        day: Date,
        streaks: [ActivityStreak],
        vpnStarts: [Date],
        carriedOver: DateInterval? = nil
    ) -> WorkdayStart? {
        let dayStart = calendar.startOfDay(for: day)

        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }

        let dayStreaks = streaks
            .filter { $0.start < dayEnd && $0.end >= dayStart }
            .map { ActivityStreak(start: max($0.start, dayStart), end: $0.end) }
            .sorted { $0.start < $1.start }

        var dayVPNStarts = vpnStarts.filter { $0 >= dayStart && $0 < dayEnd }

        if let carriedOver, carriedOver.start < dayStart,
           let first = dayStreaks.first, first.start <= carriedOver.end {
            dayVPNStarts.append(first.start)
        }

        let vpnStart = dayVPNStarts.min().map { firstVPN in
            let containing = dayStreaks.first {
                $0.start <= firstVPN && firstVPN <= $0.end.addingTimeInterval(gap)
            }

            if let containing, containing.start < firstVPN {
                return WorkdayStart(date: containing.start, source: .activity)
            }

            return WorkdayStart(date: firstVPN, source: .vpn)
        }

        guard !requireVPN else {
            return vpnStart ?? dayStreaks.first.map {
                WorkdayStart(date: $0.start, source: .activity, provisional: true)
            }
        }

        // Without the VPN the day starts with the first activity long enough
        // to be work; a later connection never moves that start.
        let activityStart = dayStreaks
            .first { $0.end.timeIntervalSince($0.start) >= minimumWork }
            .map { WorkdayStart(date: $0.start, source: .activity) }

        guard let vpnStart, let activityStart else {
            return vpnStart ?? activityStart
        }

        return activityStart.date < vpnStart.date ? activityStart : vpnStart
    }

    // In the no-VPN mode nothing reconnects after inactivity ended the day,
    // so enough activity after `stopped` resumes it instead.
    public func resumesWork(streaks: [ActivityStreak], after stopped: Date) -> Bool {
        streaks.contains { $0.end.timeIntervalSince(max($0.start, stopped)) >= minimumWork }
    }

    // A manual start only counts on the day it was set; the next day falls back
    // to detection (or to nothing, when detection is off).
    public func resolve(
        now: Date,
        manual: Date?,
        detectionEnabled: Bool,
        streaks: [ActivityStreak],
        vpnStarts: [Date],
        carriedOver: DateInterval? = nil
    ) -> WorkdayStart? {
        if let manual, calendar.isDate(manual, inSameDayAs: now) {
            return WorkdayStart(date: manual, source: .manual)
        }

        guard detectionEnabled else {
            return nil
        }

        return detect(day: now, streaks: streaks, vpnStarts: vpnStarts, carriedOver: carriedOver)
    }
}

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

    public init(calendar: Calendar = .vpnTimeISO, gap: TimeInterval = 1800) {
        self.calendar = calendar
        self.gap = gap
    }

    // The start is the beginning of the activity streak that contains the day's
    // first VPN connection, so touching the laptop early in the morning does
    // not count unless the work carried on from there without a long break.
    public func detect(day: Date, streaks: [ActivityStreak], vpnStarts: [Date]) -> WorkdayStart? {
        let dayStart = calendar.startOfDay(for: day)

        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }

        let dayStreaks = streaks
            .filter { $0.start < dayEnd && $0.end >= dayStart }
            .map { ActivityStreak(start: max($0.start, dayStart), end: $0.end) }
            .sorted { $0.start < $1.start }

        let firstVPN = vpnStarts
            .filter { $0 >= dayStart && $0 < dayEnd }
            .min()

        guard let firstVPN else {
            return dayStreaks.first.map {
                WorkdayStart(date: $0.start, source: .activity, provisional: true)
            }
        }

        let containing = dayStreaks.first {
            $0.start <= firstVPN && firstVPN <= $0.end.addingTimeInterval(gap)
        }

        if let containing, containing.start < firstVPN {
            return WorkdayStart(date: containing.start, source: .activity)
        }

        return WorkdayStart(date: firstVPN, source: .vpn)
    }

    // A manual start only counts on the day it was set; the next day falls back
    // to detection (or to nothing, when detection is off).
    public func resolve(
        now: Date,
        manual: Date?,
        detectionEnabled: Bool,
        streaks: [ActivityStreak],
        vpnStarts: [Date]
    ) -> WorkdayStart? {
        if let manual, calendar.isDate(manual, inSameDayAs: now) {
            return WorkdayStart(date: manual, source: .manual)
        }

        guard detectionEnabled else {
            return nil
        }

        return detect(day: now, streaks: streaks, vpnStarts: vpnStarts)
    }
}

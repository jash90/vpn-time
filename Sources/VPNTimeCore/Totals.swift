import Foundation

public struct Totals {
    private let calendar: Calendar
    private let now: Date

    public init(calendar: Calendar = .vpnTimeISO, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
    }

    // Only the part of each session that falls inside the bucket counts, so a
    // connection left open overnight is split between the days it spans.
    public func total(_ bucket: Bucket, sessions: [Session], active: (Date, String)?) -> Int {
        let component: Calendar.Component
        switch bucket {
        case .today: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }

        guard let interval = calendar.dateInterval(of: component, for: now) else {
            return 0
        }

        func overlap(_ start: Date, _ end: Date) -> Int {
            let from = max(start, interval.start)
            let to = min(end, interval.end, now)
            return to > from ? Int(to.timeIntervalSince(from)) : 0
        }

        var seconds = sessions.reduce(0) {
            $0 + overlap($1.start, $1.start.addingTimeInterval(TimeInterval($1.duration)))
        }

        if let active {
            seconds += overlap(active.0, now)
        }

        return seconds
    }
}

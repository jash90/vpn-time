import Foundation

public struct Totals {
    private let calendar: Calendar
    private let now: Date

    public init(calendar: Calendar = .vpnTimeISO, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
    }

    public func total(_ bucket: Bucket, sessions: [Session], active: (Date, String)?) -> Int {
        func inBucket(_ date: Date) -> Bool {
            switch bucket {
            case .today:
                return calendar.isDate(date, inSameDayAs: now)
            case .week:
                return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .month:
                return calendar.isDate(date, equalTo: now, toGranularity: .month)
            }
        }

        var seconds = sessions
            .filter { inBucket($0.start) }
            .reduce(0) { $0 + $1.duration }

        if let active, inBucket(active.0) {
            seconds += Int(now.timeIntervalSince(active.0))
        }

        return seconds
    }
}

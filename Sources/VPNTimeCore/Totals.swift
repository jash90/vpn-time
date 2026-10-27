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
        guard let interval = interval(of: bucket) else {
            return 0
        }

        return vpnSeconds(in: interval, sessions: sessions, active: active)
    }

    // Work time split by the VPN. On a day with a recorded workday, `vpn` is
    // the VPN time inside it and `noVPN` the rest of it, so together they are
    // the workday's length; a VPN left up after the day ended is no work. On
    // a day without one (detection off, say, or a past day with no end) all
    // of the day's VPN time counts.
    public func split(
        _ bucket: Bucket,
        sessions: [Session],
        active: (Date, String)?,
        records: [WorkdayRecord]
    ) -> WorkSplit {
        guard let bucketInterval = interval(of: bucket) else {
            return WorkSplit(vpn: 0, noVPN: 0)
        }

        var vpn = 0
        var noVPN = 0
        var day = bucketInterval.start

        while day < min(bucketInterval.end, now) {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }

            let record = records.first { calendar.isDate($0.start, inSameDayAs: day) }
            let split = self.split(record: record, day: DateInterval(start: day, end: next), sessions: sessions, active: active)
            vpn += split.vpn
            noVPN += split.noVPN
            day = next
        }

        return WorkSplit(vpn: vpn, noVPN: noVPN)
    }

    // One day of `split`: inside its workday when it has one, otherwise all
    // of `day`'s VPN time.
    public func split(
        record: WorkdayRecord?,
        day: DateInterval,
        sessions: [Session],
        active: (Date, String)?
    ) -> WorkSplit {
        guard let workday = record?.interval(now: now, calendar: calendar) else {
            return WorkSplit(vpn: vpnSeconds(in: day, sessions: sessions, active: active), noVPN: 0)
        }

        return WorkSplit(
            vpn: vpnSeconds(in: workday, sessions: sessions, active: active),
            noVPN: noVPNSeconds(in: workday, sessions: sessions, active: active)
        )
    }

    // The part of `interval` (up to now) without the VPN.
    public func noVPNSeconds(in interval: DateInterval, sessions: [Session], active: (Date, String)?) -> Int {
        let end = min(interval.end, now)

        guard end > interval.start else {
            return 0
        }

        let length = Int(end.timeIntervalSince(interval.start))
        return max(0, length - vpnSeconds(in: interval, sessions: sessions, active: active))
    }

    // VPN time inside `interval`, up to now.
    public func vpnSeconds(in interval: DateInterval, sessions: [Session], active: (Date, String)?) -> Int {
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

    private func interval(of bucket: Bucket) -> DateInterval? {
        let component: Calendar.Component
        switch bucket {
        case .today: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }

        return calendar.dateInterval(of: component, for: now)
    }
}

public struct WorkSplit: Equatable {
    public let vpn: Int
    public let noVPN: Int

    public init(vpn: Int, noVPN: Int) {
        self.vpn = vpn
        self.noVPN = noVPN
    }

    public var total: Int {
        vpn + noVPN
    }
}

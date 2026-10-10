import Foundation

public struct WorkdayEnd: Hashable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init?(minutesOfDay: Int) {
        guard (0..<1440).contains(minutesOfDay) else {
            return nil
        }

        self.init(hour: minutesOfDay / 60, minute: minutesOfDay % 60)
    }

    public var minutesOfDay: Int {
        hour * 60 + minute
    }

    public var label: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public func shouldFire(now: Date, lastFired: Date?, calendar: Calendar) -> Bool {
        WorkdayEndRule.fixed(self).shouldFire(now: now, start: nil, lastFired: lastFired, calendar: calendar)
    }
}

public enum WorkdayEndRule: Hashable {
    case fixed(WorkdayEnd)
    case afterStart(minutes: Int)

    public var label: String {
        switch self {
        case .fixed(let end):
            return end.label
        case .afterStart(let minutes):
            return L("end.afterStart", hoursMinutes(minutes * 60))
        }
    }

    public func trigger(now: Date, start: Date?, calendar: Calendar) -> Date? {
        switch self {
        case .fixed(let end):
            return calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: now)
        case .afterStart(let minutes):
            return start?.addingTimeInterval(TimeInterval(minutes * 60))
        }
    }

    public func shouldFire(now: Date, start: Date?, lastFired: Date?, calendar: Calendar) -> Bool {
        guard let trigger = trigger(now: now, start: start, calendar: calendar), now >= trigger else {
            return false
        }

        if let lastFired, calendar.isDate(lastFired, inSameDayAs: now) {
            return false
        }

        return true
    }
}

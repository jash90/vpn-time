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
        guard let trigger = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: now
        ) else {
            return false
        }

        if now < trigger {
            return false
        }

        if let lastFired, calendar.isDate(lastFired, inSameDayAs: now) {
            return false
        }

        return true
    }
}

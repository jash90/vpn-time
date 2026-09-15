import Foundation

public enum Bucket: Hashable {
    case today
    case week
    case month
}

public extension Calendar {
    static var vpnTimeISO: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }
}

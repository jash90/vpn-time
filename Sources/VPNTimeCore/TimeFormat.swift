import Foundation

public func hoursMinutes(_ seconds: Int) -> String {
    String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
}

public func counter(_ seconds: Int) -> String {
    String(format: " %d:%02d", seconds / 3600, (seconds % 3600) / 60)
}

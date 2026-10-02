import Foundation

// A run of keyboard/mouse activity with no break longer than the poller's gap.
public struct ActivityStreak: Hashable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

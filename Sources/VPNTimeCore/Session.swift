import Foundation

public struct Session {
    public let start: Date
    public let duration: Int

    public init(start: Date, duration: Int) {
        self.start = start
        self.duration = duration
    }
}

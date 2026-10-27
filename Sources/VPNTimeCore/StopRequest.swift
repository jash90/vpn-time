import Foundation

// Ends the active session at `end` once the VPN is down, so the inactivity
// that ended the workday does not count as time on the VPN.
public struct StopRequest: Equatable {
    public let sessionStart: Date
    public let end: Date

    public init(sessionStart: Date, end: Date) {
        self.sessionStart = sessionStart
        self.end = end
    }

    // Both files hold whole seconds, so that is what identifies a session.
    public func names(_ start: Date) -> Bool {
        Int(sessionStart.timeIntervalSince1970) == Int(start.timeIntervalSince1970)
    }

    // Until the tracker notices the disconnect, the session it names already
    // counts as finished at the requested end.
    public static func settle(
        sessions: [Session],
        active: (Date, String)?,
        stop: StopRequest?
    ) -> (sessions: [Session], active: (Date, String)?) {
        guard let active, let stop, stop.names(active.0) else {
            return (sessions, active)
        }

        let duration = max(0, Int(stop.end.timeIntervalSince(active.0)))
        return (duration > 0 ? sessions + [Session(start: active.0, duration: duration)] : sessions, nil)
    }
}

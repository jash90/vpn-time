import Foundation

// Decides when to ask whether work is still going on, and when an unanswered
// question stops the workday. Pure, so the timing rules can be tested without
// waiting an hour.
public struct IdleWatch {
    public static let defaultThreshold: TimeInterval = 60 * 60
    public static let defaultGrace: TimeInterval = 5 * 60

    // The question on screen: when it appeared and when the inactivity began.
    public struct Prompt: Equatable {
        public let shownAt: Date
        public let idleSince: Date

        public init(shownAt: Date, idleSince: Date) {
            self.shownAt = shownAt
            self.idleSince = idleSince
        }
    }

    public enum Action: Equatable {
        case none
        case ask(idleSince: Date)
        case stop(at: Date)
        // The question no longer applies (VPN gone, day already over).
        case withdraw
    }

    public let threshold: TimeInterval
    public let grace: TimeInterval

    public init(threshold: TimeInterval = defaultThreshold, grace: TimeInterval = defaultGrace) {
        self.threshold = threshold
        self.grace = grace
    }

    // `watching` is true while there is something to stop: an active VPN
    // session inside a workday that has not ended yet. An unanswered question
    // ends the day at the start of the inactivity, never before the workday
    // start. After "Pracuję" (`answeredAt`) only inactivity that began later
    // is asked about again.
    public func evaluate(
        now: Date,
        idleSeconds: TimeInterval,
        watching: Bool,
        workdayStart: Date?,
        prompt: Prompt?,
        answeredAt: Date? = nil
    ) -> Action {
        guard watching else {
            return prompt == nil ? .none : .withdraw
        }

        if let prompt {
            guard now.timeIntervalSince(prompt.shownAt) >= grace else {
                return .none
            }

            return .stop(at: max(prompt.idleSince, workdayStart ?? prompt.idleSince))
        }

        let idleSince = now.addingTimeInterval(-idleSeconds)

        guard idleSeconds >= threshold else {
            return .none
        }

        if let answeredAt, idleSince < answeredAt, now.timeIntervalSince(answeredAt) < threshold {
            return .none
        }

        return .ask(idleSince: max(idleSince, answeredAt ?? idleSince))
    }

    public func deadline(of prompt: Prompt) -> Date {
        prompt.shownAt.addingTimeInterval(grace)
    }
}

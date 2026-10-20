import Foundation

// Decides when to ask whether work is still going on, and when an unanswered
// question stops the workday. Pure, so the timing rules can be tested without
// waiting an hour.
public struct IdleWatch {
    public static let defaultThreshold: TimeInterval = 60 * 60
    public static let defaultGrace: TimeInterval = 5 * 60
    public static let defaultRepeat: TimeInterval = 60 * 60

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
    public let repeatInterval: TimeInterval

    public init(
        threshold: TimeInterval = defaultThreshold,
        grace: TimeInterval = defaultGrace,
        repeatInterval: TimeInterval = defaultRepeat
    ) {
        self.threshold = threshold
        self.grace = grace
        self.repeatInterval = repeatInterval
    }

    // `watching` is true while there is something to stop: a workday that has
    // not ended yet. An unanswered question ends the day at the start of the
    // inactivity, never before the workday start. After "Pracuję"
    // (`answeredAt`) inactivity that began before the answer is asked about
    // again once `repeatInterval` has passed since it; inactivity that began
    // later follows the plain threshold. `previousInput` is the last input
    // seen on the previous tick: a jump from it to the current last input
    // means the app missed an idle period (the Mac slept, say).
    public func evaluate(
        now: Date,
        idleSeconds: TimeInterval,
        watching: Bool,
        workdayStart: Date?,
        prompt: Prompt?,
        answeredAt: Date? = nil,
        previousInput: Date? = nil
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

        // A missed idle period shows up as a jump of the last input time,
        // with the system idle counter starting over. Ask about that break
        // too, counting only the part after "Pracuję": the first input right
        // after the answer must not look like the end of a long break.
        if let previousInput {
            let breakStart = max(previousInput, answeredAt ?? previousInput)

            if idleSince.timeIntervalSince(breakStart) >= threshold {
                return .ask(idleSince: breakStart)
            }
        }

        guard idleSeconds >= threshold else {
            return .none
        }

        if let answeredAt, idleSince < answeredAt, now.timeIntervalSince(answeredAt) < repeatInterval {
            return .none
        }

        return .ask(idleSince: max(idleSince, answeredAt ?? idleSince))
    }

    public func deadline(of prompt: Prompt) -> Date {
        prompt.shownAt.addingTimeInterval(grace)
    }
}

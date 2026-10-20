import XCTest
@testable import VPNTimeCore

final class IdleWatchTests: XCTestCase {
    private let watch = IdleWatch()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let start = Date(timeIntervalSince1970: 1_800_000_000 - 6 * 3600)

    func testAsksOnceAnHourOfInactivityHasPassed() {
        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 3599, watching: true, workdayStart: start, prompt: nil),
            .none
        )
        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 3600, watching: true, workdayStart: start, prompt: nil),
            .ask(idleSince: now.addingTimeInterval(-3600))
        )
    }

    func testDoesNotAskWhenNotWatching() {
        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 9000, watching: false, workdayStart: start, prompt: nil),
            .none
        )
    }

    func testWaitsFiveMinutesForAnAnswer() {
        let prompt = IdleWatch.Prompt(shownAt: now.addingTimeInterval(-299), idleSince: now.addingTimeInterval(-3899))

        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 3899, watching: true, workdayStart: start, prompt: prompt),
            .none
        )
        XCTAssertEqual(watch.deadline(of: prompt), now.addingTimeInterval(1))
    }

    func testStopsAtTheStartOfTheInactivityWhenUnanswered() {
        let idleSince = now.addingTimeInterval(-3900)
        let prompt = IdleWatch.Prompt(shownAt: now.addingTimeInterval(-300), idleSince: idleSince)

        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 3900, watching: true, workdayStart: start, prompt: prompt),
            .stop(at: idleSince)
        )
    }

    // Activity after the question appeared does not count as an answer.
    func testStopsEvenIfActivityResumedWithoutAClick() {
        let idleSince = now.addingTimeInterval(-3900)
        let prompt = IdleWatch.Prompt(shownAt: now.addingTimeInterval(-300), idleSince: idleSince)

        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 2, watching: true, workdayStart: start, prompt: prompt),
            .stop(at: idleSince)
        )
    }

    func testNeverStopsBeforeTheWorkdayStart() {
        let lateStart = now.addingTimeInterval(-1800)
        let prompt = IdleWatch.Prompt(shownAt: now.addingTimeInterval(-300), idleSince: now.addingTimeInterval(-3900))

        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 3900, watching: true, workdayStart: lateStart, prompt: prompt),
            .stop(at: lateStart)
        )
    }

    func testWithdrawsTheQuestionWhenWatchingEnds() {
        let prompt = IdleWatch.Prompt(shownAt: now.addingTimeInterval(-60), idleSince: now.addingTimeInterval(-3660))

        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 3660, watching: false, workdayStart: start, prompt: prompt),
            .withdraw
        )
    }

    // "Pracuję" answers for the inactivity so far; the next question needs a
    // full hour counted from the answer, even if the click did not reset the
    // system idle time.
    func testAsksAgainOnlyAnHourAfterTheAnswer() {
        let answered = now.addingTimeInterval(-600)

        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 4200, watching: true, workdayStart: start, prompt: nil, answeredAt: answered),
            .none
        )

        let later = answered.addingTimeInterval(3600)
        XCTAssertEqual(
            watch.evaluate(now: later, idleSeconds: 7200, watching: true, workdayStart: start, prompt: nil, answeredAt: answered),
            .ask(idleSince: answered)
        )
    }

    func testFreshInactivityAfterTheAnswerIsAskedAboutNormally() {
        let answered = now.addingTimeInterval(-5000)

        XCTAssertEqual(
            watch.evaluate(now: now, idleSeconds: 3600, watching: true, workdayStart: start, prompt: nil, answeredAt: answered),
            .ask(idleSince: now.addingTimeInterval(-3600))
        )
    }

    func testHonoursCustomTimings() {
        let quick = IdleWatch(threshold: 20, grace: 10)
        let prompt = IdleWatch.Prompt(shownAt: now.addingTimeInterval(-10), idleSince: now.addingTimeInterval(-30))

        XCTAssertEqual(
            quick.evaluate(now: now, idleSeconds: 20, watching: true, workdayStart: start, prompt: nil),
            .ask(idleSince: now.addingTimeInterval(-20))
        )
        XCTAssertEqual(
            quick.evaluate(now: now, idleSeconds: 30, watching: true, workdayStart: start, prompt: prompt),
            .stop(at: now.addingTimeInterval(-30))
        )
    }

    // The re-ask after "Pracuję" can be set separately from the threshold.
    func testAsksAgainAfterTheRepeatInterval() {
        let chatty = IdleWatch(threshold: 3600, grace: 300, repeatInterval: 1800)
        let answered = now.addingTimeInterval(-1000)

        XCTAssertEqual(
            chatty.evaluate(
                now: now, idleSeconds: 4600, watching: true, workdayStart: start,
                prompt: nil, answeredAt: answered
            ),
            .none
        )

        let later = answered.addingTimeInterval(1800)
        XCTAssertEqual(
            chatty.evaluate(
                now: later, idleSeconds: 6400, watching: true, workdayStart: start,
                prompt: nil, answeredAt: answered
            ),
            .ask(idleSince: answered)
        )
    }

    // The Mac slept through the idle period: the system idle counter starts
    // over, so the break only shows up as a jump of the last input time.
    func testAsksAboutABreakItSleptThrough() {
        let previousInput = now.addingTimeInterval(-7200)

        XCTAssertEqual(
            watch.evaluate(
                now: now, idleSeconds: 5, watching: true, workdayStart: start,
                prompt: nil, previousInput: previousInput
            ),
            .ask(idleSince: previousInput)
        )
    }

    func testTheSleptThroughBreakNeverEndsBeforeTheAnswer() {
        let previousInput = now.addingTimeInterval(-7200)
        let answered = now.addingTimeInterval(-5400)

        XCTAssertEqual(
            watch.evaluate(
                now: now, idleSeconds: 60, watching: true, workdayStart: start,
                prompt: nil, answeredAt: answered, previousInput: previousInput
            ),
            .ask(idleSince: answered)
        )
    }

    // A break that ended before "Pracuję" is covered by the answer; only the
    // repeat interval brings the question back.
    func testABreakThatEndedBeforeTheAnswerFollowsTheRepeatInterval() {
        let answered = now.addingTimeInterval(-1800)

        XCTAssertEqual(
            watch.evaluate(
                now: now, idleSeconds: 2, watching: true, workdayStart: start,
                prompt: nil, answeredAt: answered, previousInput: now.addingTimeInterval(-9000)
            ),
            .none
        )
        XCTAssertEqual(
            watch.evaluate(
                now: now, idleSeconds: 7800, watching: true, workdayStart: start,
                prompt: nil,
                answeredAt: now.addingTimeInterval(-7200),
                previousInput: now.addingTimeInterval(-14_400)
            ),
            .ask(idleSince: now.addingTimeInterval(-7200))
        )
    }

    // The question was shown during a long idle period and answered; the
    // next tick still remembers the input from before the break.
    func testDoesNotAskAgainRightAfterTheAnswer() {
        XCTAssertEqual(
            watch.evaluate(
                now: now, idleSeconds: 2, watching: true, workdayStart: start,
                prompt: nil,
                answeredAt: now.addingTimeInterval(-4),
                previousInput: now.addingTimeInterval(-3700)
            ),
            .none
        )
    }
}

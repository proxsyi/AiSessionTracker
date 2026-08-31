import XCTest
@testable import TrackerDesignSystem
@testable import CombinedSessionTracker

@MainActor
final class SessionTimingTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testScheduledTimeAndResetTimeAreIndependent() {
        let now = date("2026-08-30T04:00:00Z")
        let reset = now.addingTimeInterval(1800)
        let schedule = TrackerSessionTiming.nextScheduledDate(after: now, slots: [.init(hour: 5, minute: 0)], calendar: calendar)
        XCTAssertEqual(schedule, date("2026-08-30T05:00:00Z"))
        XCTAssertEqual(TrackerSessionTiming.nextPossibleDate(now: now, reset: reset, percent: 50, lastSuccess: now), reset)
        XCTAssertNotEqual(schedule, reset)
    }

    func testAutomaticWakeAndTimerCannotRepeatRecentSuccessfulPing() {
        let now = Date()
        XCTAssertFalse(TrackerSessionTiming.allowsAutomaticPing(now: now, lastSuccess: now.addingTimeInterval(-59)))
        XCTAssertTrue(TrackerSessionTiming.allowsAutomaticPing(now: now, lastSuccess: now.addingTimeInterval(-60)))
        XCTAssertTrue(TrackerSessionTiming.allowsAutomaticPing(now: now, lastSuccess: nil))
        // A recent success for Claude does not suppress a separate Codex history.
        XCTAssertTrue(TrackerSessionTiming.allowsAutomaticPing(now: now, lastSuccess: now.addingTimeInterval(-300)))
    }

    func testScheduleOrderMidnightAndExactBoundary() {
        let slots: [TrackerScheduleTime] = [.init(hour: 20, minute: 0), .init(hour: 5, minute: 0), .init(hour: 10, minute: 0)]
        XCTAssertEqual(TrackerSessionTiming.nextScheduledDate(after: date("2026-08-30T05:00:00Z"), slots: slots, calendar: calendar), date("2026-08-30T10:00:00Z"))
        XCTAssertEqual(TrackerSessionTiming.nextScheduledDate(after: date("2026-08-30T23:59:59Z"), slots: slots, calendar: calendar), date("2026-08-31T05:00:00Z"))
        XCTAssertNil(TrackerSessionTiming.nextScheduledDate(after: Date(), slots: [], calendar: calendar))
    }

    func testDaylightSavingGapAndRepeatedHour() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(TrackerSessionTiming.nextScheduledDate(after: date("2026-03-08T06:00:00Z"), slots: [.init(hour: 2, minute: 30)], calendar: local), date("2026-03-08T07:00:00Z"))
        XCTAssertEqual(TrackerSessionTiming.nextScheduledDate(after: date("2026-11-01T04:00:00Z"), slots: [.init(hour: 1, minute: 30)], calendar: local), date("2026-11-01T05:30:00Z"))
        XCTAssertEqual(TrackerSessionTiming.nextScheduledDate(after: date("2026-11-01T05:30:00Z"), slots: [.init(hour: 1, minute: 30)], calendar: local), date("2026-11-02T06:30:00Z"))
    }

    func testExpiredResetIsNowEvenAfterRecentPing() {
        let now = Date()
        for percent in [nil, 0, 100] as [Int?] {
            XCTAssertEqual(TrackerSessionTiming.nextPossibleDate(now: now, reset: now.addingTimeInterval(-1), percent: percent, lastSuccess: now.addingTimeInterval(-60)), now)
        }
    }

    func testMissingResetFallbackAndClockProgress() {
        let now = Date()
        let last = now.addingTimeInterval(-3600)
        let reset = TrackerSessionTiming.nextPossibleDate(now: now, reset: nil, percent: nil, lastSuccess: last)
        XCTAssertEqual(reset, last.addingTimeInterval(5 * 3600))
        XCTAssertEqual(reset.timeIntervalSince(now.addingTimeInterval(60)), 4 * 3600 - 60, accuracy: 0.01)
        XCTAssertEqual(TrackerSessionTiming.nextPossibleDate(now: now, reset: nil, percent: 0, lastSuccess: last), now)
        XCTAssertEqual(TrackerSessionTiming.nextPossibleDate(now: now, reset: nil, percent: nil, lastSuccess: nil), now)
    }

    func testChangingOrDisablingClaudeDoesNotChangeCodexScheduleOrReset() {
        let now = date("2026-08-30T04:00:00Z")
        let claude = TrackerDailyScheduler(clock: { now }, calendar: calendar)
        let codex = TrackerDailyScheduler(clock: { now }, calendar: calendar)
        defer { claude.stop(); codex.stop() }
        claude.schedule(slots: [.init(hour: 5, minute: 0)])
        codex.schedule(slots: [.init(hour: 10, minute: 0)])
        let codexDate = codex.nextFireDate
        let reset = now.addingTimeInterval(900)
        claude.schedule(slots: [.init(hour: 6, minute: 30)])
        XCTAssertEqual(codex.nextFireDate, codexDate)
        claude.stop()
        XCTAssertNil(claude.nextFireDate)
        XCTAssertEqual(codex.nextFireDate, codexDate)
        XCTAssertEqual(TrackerSessionTiming.nextPossibleDate(now: now, reset: reset, percent: 80, lastSuccess: nil), reset)
    }

    func testCancelledAndReplacedTimerCannotFireQueuedCallback() {
        var now = date("2026-08-30T04:59:59Z")
        let scheduler = TrackerDailyScheduler(clock: { now }, calendar: calendar)
        defer { scheduler.stop() }
        var calls = 0
        scheduler.onFire = { calls += 1 }
        scheduler.schedule(slots: [.init(hour: 5, minute: 0)])
        let oldGeneration = scheduler.generation
        now = now.addingTimeInterval(1)
        scheduler.stop()
        scheduler.fire(generation: oldGeneration)
        XCTAssertEqual(calls, 0)
        scheduler.schedule(slots: [.init(hour: 10, minute: 0)])
        scheduler.fire(generation: oldGeneration)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(scheduler.nextFireDate, date("2026-08-30T10:00:00Z"))
    }

    func testDueScheduleAdvancesBeforePingAndOnlyFiresOnce() {
        var now = date("2026-08-30T04:59:59Z")
        let scheduler = TrackerDailyScheduler(clock: { now }, calendar: calendar)
        defer { scheduler.stop() }
        var calls = 0
        scheduler.onFire = {
            calls += 1
            XCTAssertEqual(scheduler.nextFireDate, self.date("2026-08-30T10:00:00Z"))
        }
        scheduler.schedule(slots: [.init(hour: 5, minute: 0), .init(hour: 10, minute: 0)])
        let generation = scheduler.generation
        now = now.addingTimeInterval(1)
        scheduler.fire(generation: generation)
        scheduler.fire(generation: generation)
        XCTAssertEqual(calls, 1)
    }

    func testClockMovingBackDoesNotSendEarly() {
        var now = date("2026-08-30T04:59:59Z")
        let scheduler = TrackerDailyScheduler(clock: { now }, calendar: calendar)
        defer { scheduler.stop() }
        var calls = 0
        scheduler.onFire = { calls += 1 }
        scheduler.schedule(slots: [.init(hour: 5, minute: 0)])
        let generation = scheduler.generation
        now = now.addingTimeInterval(-3600)
        scheduler.fire(generation: generation)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(scheduler.nextFireDate, date("2026-08-30T05:00:00Z"))
    }

    func testLateWakeOnlyDispatchesOnceAndAdvancesToFuture() {
        var now = date("2026-08-30T04:59:59Z")
        let scheduler = TrackerDailyScheduler(clock: { now }, calendar: calendar)
        defer { scheduler.stop() }
        var calls = 0
        scheduler.onFire = { calls += 1 }
        scheduler.schedule(slots: [.init(hour: 5, minute: 0), .init(hour: 10, minute: 0), .init(hour: 15, minute: 0)])
        let generation = scheduler.generation
        now = date("2026-08-30T11:00:00Z")
        scheduler.fire(generation: generation)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(scheduler.nextFireDate, date("2026-08-30T15:00:00Z"))
    }

    func testRealTimersFireIndependentlyAtSameTime() async {
        let wallStart = Date()
        let logicalStart = date("2026-08-30T04:59:59Z").addingTimeInterval(0.8)
        let clock = { logicalStart.addingTimeInterval(Date().timeIntervalSince(wallStart)) }
        let claude = TrackerDailyScheduler(clock: clock, calendar: calendar)
        let codex = TrackerDailyScheduler(clock: clock, calendar: calendar)
        defer { claude.stop(); codex.stop() }
        let claudeFired = expectation(description: "Claude scheduled dispatch")
        let codexFired = expectation(description: "Codex scheduled dispatch")
        claude.onFire = { claudeFired.fulfill() }
        codex.onFire = { codexFired.fulfill() }
        claude.schedule(slots: [.init(hour: 5, minute: 0)])
        codex.schedule(slots: [.init(hour: 5, minute: 0)])
        await fulfillment(of: [claudeFired, codexFired], timeout: 3)
        XCTAssertEqual(claude.nextFireDate, date("2026-08-31T05:00:00Z"))
        XCTAssertEqual(codex.nextFireDate, date("2026-08-31T05:00:00Z"))
    }

    func testClaudeWrapperUsesSameScheduleCalculation() {
        let scheduler = Scheduler()
        let now = date("2026-08-30T04:00:00Z")
        XCTAssertEqual(scheduler.nextFireDate(after: now, slots: [.init(hour: 5, minute: 0)]),
            TrackerSessionTiming.nextScheduledDate(after: now, slots: [.init(hour: 5, minute: 0)]))
    }
}

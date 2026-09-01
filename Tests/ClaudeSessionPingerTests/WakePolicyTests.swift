import XCTest
import TrackerDesignSystem

final class WakePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProvidersProduceIdenticalDatesButIsolatedCommands() throws {
        var claude: [[String]] = [], codex: [[String]] = []
        let slots = [TrackerScheduleTime(hour: 5, minute: 30), .init(hour: 10, minute: 30)]
        let c = try TrackerWakeSchedule.synchronize(provider: "claude", enabled: true, slots: slots, testEpoch: 0, now: now) { claude.append($0) }
        let g = try TrackerWakeSchedule.synchronize(provider: "codex", enabled: true, slots: slots, testEpoch: 0, now: now) { codex.append($0) }
        XCTAssertEqual(c.map(\.wake), g.map(\.wake))
        XCTAssertEqual(c.map(\.ping), g.map(\.ping))
        XCTAssertTrue(c.allSatisfy { $0.ping.timeIntervalSince($0.wake) == 5 })
        XCTAssertEqual(claude.map { $0.map { $0 == "claude" ? "codex" : $0 } }, codex)
        XCTAssertFalse(claude.contains { $0.contains("codex") })
        XCTAssertFalse(codex.contains { $0.contains("claude") })
    }

    func testScheduleRefreshPreservesPendingTestEvenWhenScheduleIsOff() throws {
        for provider in ["claude", "codex"] {
            var commands: [[String]] = []
            let test = now.timeIntervalSince1970 + 120
            let pairs = try TrackerWakeSchedule.synchronize(provider: provider, enabled: false, slots: [], testEpoch: test, now: now) { commands.append($0) }
            XCTAssertTrue(pairs.isEmpty)
            XCTAssertEqual(commands, [["purge", provider], ["purge", "legacy"], ["schedule", provider, String(format: "%.0f", test)]])
        }
    }

    func testPartialFailureRollsBackOnlyNewProviderEventsAndPreservesTest() {
        enum Failure: Error { case expected }
        for provider in ["claude", "codex"] {
            var commands: [[String]] = []
            let test = now.timeIntervalSince1970 + 120
            var schedules = 0
            XCTAssertThrowsError(try TrackerWakeSchedule.synchronize(provider: provider, enabled: true,
                slots: [.init(hour: 5, minute: 0)], testEpoch: test, now: now) { command in
                commands.append(command)
                if command[0] == "schedule" { schedules += 1; if schedules == 3 { throw Failure.expected } }
            })
            let cancels = commands.filter { $0[0] == "cancel" }
            XCTAssertEqual(cancels.count, 1)
            XCTAssertEqual(cancels.first?[1], provider)
            XCTAssertNotEqual(cancels.first?[2], String(format: "%.0f", test))
        }
    }

    func testExpiredTestIsNotRescheduled() throws {
        var commands: [[String]] = []
        _ = try TrackerWakeSchedule.synchronize(provider: "codex", enabled: false, slots: [], testEpoch: now.timeIntervalSince1970 - 1, now: now) { commands.append($0) }
        XCTAssertEqual(commands.count, 2)
    }

    @MainActor func testSleepProtectionStaysActiveUntilEveryPingFinishes() async {
        let activity = TrackerWakeActivity()
        XCTAssertTrue(activity.isIdle)
        let claude = activity.begin(), codex = activity.begin()
        activity.end(claude)
        XCTAssertFalse(activity.isIdle)
        activity.end(claude)
        XCTAssertFalse(activity.isIdle)
        activity.end(codex)
        XCTAssertTrue(activity.isIdle)
        let idle = await activity.waitUntilIdle()
        XCTAssertTrue(idle)
    }

    @MainActor func testCancelledWakeNeverProceedsToSleep() async {
        let activity = TrackerWakeActivity()
        let token = activity.begin()
        let task = Task { await activity.waitUntilIdle() }
        task.cancel()
        let maySleep = await task.value
        XCTAssertFalse(maySleep)
        activity.end(token)
    }
}

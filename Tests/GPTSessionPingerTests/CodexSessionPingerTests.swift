import XCTest
@testable import GPTTrackerFeature

@MainActor
final class CodexSessionPingerTests: XCTestCase {
    func testScheduleSlotsHaveDistinctStableIdentities() {
        let first = CodexSessionPinger.ScheduleSlot(hour: 5, minute: 0)
        let second = CodexSessionPinger.ScheduleSlot(hour: 10, minute: 0)
        XCTAssertEqual(first.id, "5-0")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testPreferenceDraftDoesNotChangeOriginalValues() {
        let saved = CodexSessionPinger.Preferences()
        var draft = saved
        draft.enabled = false
        draft.notifyOnFailure = false
        draft.slots[0].hour = 6
        XCTAssertTrue(saved.enabled)
        XCTAssertTrue(saved.notifyOnFailure)
        XCTAssertEqual(saved.slots[0].hour, 5)
    }

    func testCodexScheduleMatchesClaudeFiveHourSpacing() {
        XCTAssertNil(CodexSessionPinger.validationMessage(for: [.init(hour: 5, minute: 0), .init(hour: 10, minute: 0)]))
        XCTAssertNotNil(CodexSessionPinger.validationMessage(for: [.init(hour: 5, minute: 0), .init(hour: 9, minute: 0)]))
        XCTAssertNotNil(CodexSessionPinger.validationMessage(for: [.init(hour: 23, minute: 0), .init(hour: 2, minute: 0)]))
    }

    func testNextPossibleSessionUsesActiveRollingReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = now.addingTimeInterval(90 * 60)
        let lastSuccess = now.addingTimeInterval(-60 * 60)

        XCTAssertEqual(
            CodexSessionPinger.nextPossibleSessionDate(
                now: now,
                rollingReset: reset,
                lastSuccess: lastSuccess
            ),
            reset
        )
    }

    func testNextPossibleSessionFallsBackToLastSuccessfulPing() {
        let now = Date(timeIntervalSince1970: 1_000)
        let lastSuccess = now.addingTimeInterval(-60 * 60)

        XCTAssertEqual(
            CodexSessionPinger.nextPossibleSessionDate(
                now: now,
                rollingReset: nil,
                lastSuccess: lastSuccess
            ),
            lastSuccess.addingTimeInterval(5 * 60 * 60)
        )
    }

    func testReportedResetDoesNotRestartCountdownFromLaterPing() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(CodexSessionPinger.nextPossibleSessionDate(now: now,
            rollingReset: now.addingTimeInterval(-1), lastSuccess: now.addingTimeInterval(-60)), now)
    }
}

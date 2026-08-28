import XCTest
@testable import GPTTrackerFeature

@MainActor
final class CodexSessionPingerTests: XCTestCase {
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
                rollingReset: now.addingTimeInterval(-1),
                lastSuccess: lastSuccess
            ),
            lastSuccess.addingTimeInterval(5 * 60 * 60)
        )
    }
}

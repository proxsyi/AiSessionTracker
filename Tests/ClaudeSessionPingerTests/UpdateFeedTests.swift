import XCTest
@testable import CombinedSessionTracker

final class CombinedUpdateFeedTests: XCTestCase {
    func testCombinedFeedCannotSelectAStandaloneApp() {
        XCTAssertEqual(UpdateFeed.tagPrefix, "tracker-v")
        XCTAssertEqual(UpdateFeed.assetName, "SessionTracker.app.zip")
        XCTAssertTrue(UpdateFeed.latestReleaseAPIURL.absoluteString.contains("proxsyi/AiSessionTracker"))
    }

    func testAutomaticUpdateChecksWaitUntilTheDailyIntervalHasPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(UpdateCheckSchedule.delay(lastCheck: nil, now: now), 5)
        XCTAssertEqual(
            UpdateCheckSchedule.delay(lastCheck: now.addingTimeInterval(-23 * 60 * 60), now: now),
            60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            UpdateCheckSchedule.delay(lastCheck: now.addingTimeInterval(-25 * 60 * 60), now: now),
            1,
            accuracy: 0.001
        )
    }

    func testAutomaticUpdateCheckTimestampsAreScopedPerApp() {
        XCTAssertNotEqual(
            UpdateCheckSchedule.defaultsKey(bundleIdentifier: "com.proxsyi.sessiontracker"),
            UpdateCheckSchedule.defaultsKey(bundleIdentifier: "com.proxsyi.claudesessionpinger")
        )
    }
}

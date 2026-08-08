import XCTest
@testable import ClaudeSessionPinger

final class UpdateFeedTests: XCTestCase {
    func testStandaloneClaudeFeedCannotSelectAnotherApp() {
        XCTAssertEqual(UpdateFeed.tagPrefix, "v")
        XCTAssertEqual(UpdateFeed.assetName, "ClaudeSessionPinger.app.zip")
        XCTAssertTrue(UpdateFeed.latestReleaseAPIURL.absoluteString.contains("proxsyi/AiSessionTracker"))
    }
}

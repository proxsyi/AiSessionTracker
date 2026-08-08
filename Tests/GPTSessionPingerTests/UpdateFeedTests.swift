import XCTest
@testable import GPTUsageTracker

final class UpdateFeedTests: XCTestCase {
    func testStandaloneGPTFeedCannotSelectAnotherApp() {
        XCTAssertEqual(UpdateFeed.tagPrefix, "gpt-v")
        XCTAssertEqual(UpdateFeed.assetName, "GPTSessionPinger.app.zip")
        XCTAssertTrue(UpdateFeed.latestReleaseAPIURL.absoluteString.contains("proxsyi/AiSessionTracker"))
    }
}

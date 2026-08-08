import XCTest
@testable import GPTTrackerFeature

final class GPTFeatureUpdateFeedTests: XCTestCase {
    func testEmbeddedGPTFeedStaysOnTheGPTReleaseContract() {
        XCTAssertEqual(UpdateFeed.tagPrefix, "gpt-v")
        XCTAssertEqual(UpdateFeed.assetName, "GPTSessionPinger.app.zip")
        XCTAssertTrue(UpdateFeed.latestReleaseAPIURL.absoluteString.contains("proxsyi/AiSessionTracker"))
    }
}

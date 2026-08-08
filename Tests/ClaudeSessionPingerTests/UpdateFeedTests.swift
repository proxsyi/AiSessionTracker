import XCTest
@testable import CombinedSessionTracker

final class CombinedUpdateFeedTests: XCTestCase {
    func testCombinedFeedCannotSelectAStandaloneApp() {
        XCTAssertEqual(UpdateFeed.tagPrefix, "tracker-v")
        XCTAssertEqual(UpdateFeed.assetName, "SessionTracker.app.zip")
        XCTAssertTrue(UpdateFeed.latestReleaseAPIURL.absoluteString.contains("proxsyi/AiSessionTracker"))
    }
}

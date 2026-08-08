import XCTest
@testable import GPTTrackerFeature

final class GPTSettingsStoreDomainTests: XCTestCase {
    func testStandaloneAppUsesStandardDefaultsDomain() {
        XCTAssertNil(SettingsStore.defaultsSuiteName(for: "com.proxsyi.gptsessionpinger"))
    }

    func testCombinedAppUsesGPTDefaultsDomain() {
        XCTAssertEqual(
            SettingsStore.defaultsSuiteName(for: "com.proxsyi.sessiontracker"),
            "com.proxsyi.gptsessionpinger"
        )
    }
}

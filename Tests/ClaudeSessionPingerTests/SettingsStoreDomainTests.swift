import XCTest
@testable import CombinedSessionTracker

final class ClaudeSettingsStoreDomainTests: XCTestCase {
    func testStandaloneAppUsesStandardDefaultsDomain() {
        XCTAssertNil(SettingsStore.defaultsSuiteName(for: "com.proxsyi.claudesessionpinger"))
    }

    func testCombinedAppUsesClaudeDefaultsDomain() {
        XCTAssertEqual(
            SettingsStore.defaultsSuiteName(for: "com.proxsyi.sessiontracker"),
            "com.proxsyi.claudesessionpinger"
        )
    }
}

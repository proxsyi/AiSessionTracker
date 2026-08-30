import Foundation
import TrackerDesignSystem
import XCTest

final class SecureUpdateTests: XCTestCase {
    func testAssetURLMustUseTheExpectedGitHubRepository() throws {
        XCTAssertNoThrow(try TrackerSecureUpdate.validateAssetURL(
            URL(string: "https://api.github.com/repos/proxsyi/AiSessionTracker/releases/assets/123")!
        ))
        XCTAssertThrowsError(try TrackerSecureUpdate.validateAssetURL(
            URL(string: "https://example.com/repos/proxsyi/AiSessionTracker/releases/assets/123")!
        ))
        XCTAssertThrowsError(try TrackerSecureUpdate.validateAssetURL(
            URL(string: "https://api.github.com/repos/other/project/releases/assets/123")!
        ))
        XCTAssertThrowsError(try TrackerSecureUpdate.validateAssetURL(
            URL(string: "https://api.github.com/repos/proxsyi/AiSessionTracker/issues/123")!
        ))
    }

    func testArchiveMustContainExactlyOneRealTopLevelApp() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let first = work.appendingPathComponent("First.app")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        XCTAssertEqual(
            try TrackerSecureUpdate.locateTopLevelApp(in: work).standardizedFileURL.path,
            first.standardizedFileURL.path
        )

        let second = work.appendingPathComponent("Second.app")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        XCTAssertThrowsError(try TrackerSecureUpdate.locateTopLevelApp(in: work))
    }

    func testInstallerUsesPositionalArgumentsAndKeepsQuarantine() {
        let script = TrackerSecureUpdate.installerScript
        XCTAssertTrue(script.contains("current_app=\"$2\""))
        XCTAssertTrue(script.contains("new_app=\"$3\""))
        XCTAssertTrue(script.contains("backup_app=\"$work_dir/previous.app\""))
        XCTAssertFalse(script.contains("xattr"))
    }
}

import XCTest
@testable import TrackerDesignSystem

@MainActor
final class WeeklyHistoryParityTests: XCTestCase {
    func testBothProvidersUseTheSamePersistenceWithoutSharingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeURL = root.appendingPathComponent("claude.json")
        let codexURL = root.appendingPathComponent("codex.json")
        let claude = TrackerWeeklyHistoryStore(storageFolder: "unused", fileURL: claudeURL)
        let codex = TrackerWeeklyHistoryStore(storageFolder: "unused", fileURL: codexURL)
        let now = Date()
        claude.record(trackID: "claude-weekly", percent: 25, reset: now.addingTimeInterval(1_000), now: now)
        codex.record(trackID: "codex-weekly", percent: 75, reset: now.addingTimeInterval(2_000), now: now)
        XCTAssertEqual(claude.points(for: "claude-weekly", since: now).map(\.percent), [25])
        XCTAssertTrue(claude.points(for: "codex-weekly", since: now).isEmpty)
        claude.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        let reloaded = TrackerWeeklyHistoryStore(storageFolder: "unused", fileURL: codexURL)
        XCTAssertEqual(reloaded.points(for: "codex-weekly", since: now).map(\.percent), [75])
    }
}

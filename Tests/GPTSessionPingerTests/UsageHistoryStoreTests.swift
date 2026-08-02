import Foundation
import XCTest
@testable import GPTUsageTracker

@MainActor
final class UsageHistoryStoreTests: XCTestCase {
    func testHistoryRecordsRollingAndWeeklyTracksIndependently() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = UsageHistoryStore(fileURL: fileURL)
        let start = Date()
        let usage = GPTUsage(
            tracks: [
                GPTUsageTrack(id: "codex-primary-18000", scope: .codex, title: "Rolling", usedPercent: 15, remaining: nil, limit: nil, resetsAt: nil, windowSeconds: 18_000, isBlocked: false, modelSlug: nil),
                GPTUsageTrack(id: "codex-secondary-604800", scope: .codex, title: "Weekly", usedPercent: 45, remaining: nil, limit: nil, resetsAt: nil, windowSeconds: 604_800, isBlocked: false, modelSlug: nil)
            ],
            blockedFeatures: [],
            planType: "plus",
            fetchedAt: start
        )

        store.record(usage, now: start)
        store.record(usage, now: start.addingTimeInterval(61))

        XCTAssertEqual(store.points(for: "codex-rolling-5h", since: start.addingTimeInterval(-1)).map(\.percent), [15, 15])
        XCTAssertEqual(store.points(for: "codex-weekly", since: start.addingTimeInterval(-1)).map(\.percent), [45, 45])
    }

    func testDuplicateSampleWithinOneMinuteIsSkipped() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = UsageHistoryStore(fileURL: fileURL)
        let usage = GPTUsage(
            tracks: [GPTUsageTrack(id: "codex-secondary-604800", scope: .codex, title: "Weekly", usedPercent: 45, remaining: nil, limit: nil, resetsAt: nil, windowSeconds: 604_800, isBlocked: false, modelSlug: nil)],
            blockedFeatures: [],
            planType: "plus",
            fetchedAt: Date()
        )

        store.record(usage)
        store.record(usage)

        XCTAssertEqual(store.samples.count, 1)
    }

    func testClearRemovesSamplesAndStoredHistory() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = UsageHistoryStore(fileURL: fileURL)
        let usage = GPTUsage(
            tracks: [GPTUsageTrack(id: "codex-secondary-604800", scope: .codex, title: "Weekly", usedPercent: 45, remaining: nil, limit: nil, resetsAt: nil, windowSeconds: 604_800, isBlocked: false, modelSlug: nil)],
            blockedFeatures: [],
            planType: "plus",
            fetchedAt: Date()
        )
        store.record(usage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.clear()

        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

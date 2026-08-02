import Foundation
import XCTest
@testable import GPTTrackerFeature

@MainActor
final class UsageHistoryStoreTests: XCTestCase {
    func testHistoryRecordsOnlyCodexWeeklyPercent() throws {
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

        XCTAssertTrue(store.points(for: "codex-rolling-5h", since: start.addingTimeInterval(-1)).isEmpty)
        XCTAssertEqual(store.points(for: "codex-weekly", since: start.addingTimeInterval(-1)).map(\.percent), [45, 45])
    }

    func testMalformedWeeklyPercentIsNotRecorded() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = UsageHistoryStore(fileURL: fileURL)
        let usage = GPTUsage(
            tracks: [GPTUsageTrack(id: "codex-secondary-604800", scope: .codex, title: "Weekly", usedPercent: 140, remaining: nil, limit: nil, resetsAt: nil, windowSeconds: 604_800, isBlocked: false, modelSlug: nil)],
            blockedFeatures: [], planType: "plus", fetchedAt: Date()
        )

        store.record(usage)

        XCTAssertTrue(store.samples.isEmpty)
    }

    func testDifferentWeeklyResetWindowsProduceSeparateChartSeries() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = UsageHistoryStore(fileURL: fileURL)
        let start = Date()
        func usage(percent: Int, reset: Date) -> GPTUsage {
            GPTUsage(
                tracks: [GPTUsageTrack(id: "codex-secondary-604800", scope: .codex, title: "Weekly", usedPercent: percent, remaining: nil, limit: nil, resetsAt: reset, windowSeconds: 604_800, isBlocked: false, modelSlug: nil)],
                blockedFeatures: [], planType: "plus", fetchedAt: start
            )
        }

        store.record(usage(percent: 90, reset: start.addingTimeInterval(60)), now: start)
        store.record(usage(percent: 5, reset: start.addingTimeInterval(604_860)), now: start.addingTimeInterval(61))

        let points = store.points(for: "codex-weekly", since: start.addingTimeInterval(-1))
        XCTAssertEqual(points.count, 2)
        XCTAssertNotEqual(points[0].series, points[1].series)
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

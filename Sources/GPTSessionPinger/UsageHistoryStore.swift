import Foundation
import TrackerDesignSystem

typealias UsageHistorySample = TrackerUsageHistorySample
typealias UsageHistoryPoint = TrackerUsageHistoryPoint

@MainActor
final class UsageHistoryStore: TrackerWeeklyHistoryStore {
    init(fileURL: URL? = nil) {
        super.init(storageFolder: "GPTUsageTracker", fileURL: fileURL)
    }

    func record(_ usage: GPTUsage, now: Date = Date()) {
        guard let weekly = usage.weeklyTrack, weekly.preferenceID == "codex-weekly" else { return }
        record(trackID: weekly.preferenceID, percent: weekly.usedPercent, reset: weekly.resetsAt, now: now)
    }
}

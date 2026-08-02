import Foundation

struct UsageHistorySample: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let percentages: [String: Int]
    /// The server-reported reset date identifies the exact weekly window.
    /// Optional so history written by earlier versions still decodes.
    let resetDates: [String: Date]?
}

struct UsageHistoryPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let percent: Int
    let series: String
}

@MainActor
final class UsageHistoryStore: ObservableObject {
    @Published private(set) var samples: [UsageHistorySample] = []

    private let minimumSampleInterval: TimeInterval = 60
    private let retentionInterval: TimeInterval = 60 * 60 * 24 * 60
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let folder = base?.appendingPathComponent("GPTUsageTracker", isDirectory: true)
            if let folder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            self.fileURL = folder?.appendingPathComponent("usage-history.json")
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("gpt-usage-history.json")
        }
        load()
    }

    func record(_ usage: GPTUsage, now: Date = Date()) {
        // The trend has one precise meaning: the percentage returned for the
        // Codex seven-day window. Never mix rolling, model, feature, credit,
        // inferred, or malformed values into this chart.
        guard let weekly = usage.weeklyTrack,
              weekly.preferenceID == "codex-weekly",
              let percent = weekly.usedPercent,
              (0...100).contains(percent) else { return }
        let values = [weekly.preferenceID: percent]
        let resetDates = weekly.resetsAt.map { [weekly.preferenceID: $0] }

        if let latest = samples.last,
           now.timeIntervalSince(latest.date) < minimumSampleInterval,
           latest.percentages == values {
            return
        }

        samples.append(UsageHistorySample(
            id: UUID(),
            date: now,
            percentages: values,
            resetDates: resetDates
        ))
        let cutoff = now.addingTimeInterval(-retentionInterval)
        samples.removeAll { $0.date < cutoff }
        save()
    }

    func points(for trackID: String, since startDate: Date) -> [UsageHistoryPoint] {
        var inferredWindow = 0
        var previousPercent: Int?
        return samples.sorted { $0.date < $1.date }.compactMap { sample in
            guard sample.date >= startDate,
                  let percent = sample.percentages[trackID],
                  (0...100).contains(percent) else { return nil }
            if let previousPercent, percent < previousPercent {
                inferredWindow += 1
            }
            previousPercent = percent
            let series = sample.resetDates?[trackID]
                .map { "reset-\($0.timeIntervalSince1970)" }
                ?? "legacy-\(inferredWindow)"
            return UsageHistoryPoint(
                id: sample.id,
                date: sample.date,
                percent: percent,
                series: series
            )
        }
    }

    func clear() {
        samples = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UsageHistorySample].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        samples = decoded.filter { $0.date >= cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

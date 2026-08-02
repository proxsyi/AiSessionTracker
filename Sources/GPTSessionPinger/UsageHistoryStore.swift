import Foundation

struct UsageHistorySample: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let percentages: [String: Int]
}

struct UsageHistoryPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let percent: Int
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
        let values = Dictionary(uniqueKeysWithValues: usage.tracks.compactMap { track -> (String, Int)? in
            guard let percent = track.usedPercent else { return nil }
            return (track.preferenceID, percent)
        })
        guard !values.isEmpty else { return }

        if let latest = samples.last,
           now.timeIntervalSince(latest.date) < minimumSampleInterval,
           latest.percentages == values {
            return
        }

        samples.append(UsageHistorySample(id: UUID(), date: now, percentages: values))
        let cutoff = now.addingTimeInterval(-retentionInterval)
        samples.removeAll { $0.date < cutoff }
        save()
    }

    func points(for trackID: String, since startDate: Date) -> [UsageHistoryPoint] {
        samples.compactMap { sample in
            guard sample.date >= startDate, let percent = sample.percentages[trackID] else { return nil }
            return UsageHistoryPoint(id: sample.id, date: sample.date, percent: percent)
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

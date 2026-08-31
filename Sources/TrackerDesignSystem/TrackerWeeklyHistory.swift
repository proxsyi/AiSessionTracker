import Foundation
import Combine

public struct TrackerUsageHistorySample: Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let percentages: [String: Int]
    /// The server-reported reset date identifies the exact weekly window.
    /// Optional so history written by earlier versions still decodes.
    public let resetDates: [String: Date]?
}

public struct TrackerUsageHistoryPoint: Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let percent: Int
    public let series: String
}

@MainActor
open class TrackerWeeklyHistoryStore: ObservableObject {
    @Published public private(set) var samples: [TrackerUsageHistorySample] = []

    private let minimumSampleInterval: TimeInterval = 60
    private let retentionInterval: TimeInterval = 60 * 60 * 24 * 60
    private let fileURL: URL

    public init(storageFolder: String, fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let folder = base?.appendingPathComponent(storageFolder, isDirectory: true)
            if let folder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            self.fileURL = folder?.appendingPathComponent("usage-history.json")
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(storageFolder)-usage-history.json")
        }
        load()
    }

    public func record(trackID: String, percent: Int?, reset: Date?, now: Date = Date()) {
        guard let percent, (0...100).contains(percent) else { return }
        let values = [trackID: percent]
        let resetDates = reset.map { [trackID: $0] }

        if let latest = samples.last,
           now.timeIntervalSince(latest.date) < minimumSampleInterval,
           latest.percentages == values {
            return
        }

        samples.append(TrackerUsageHistorySample(
            id: UUID(),
            date: now,
            percentages: values,
            resetDates: resetDates
        ))
        let cutoff = now.addingTimeInterval(-retentionInterval)
        samples.removeAll { $0.date < cutoff }
        save()
    }

    public func points(for trackID: String, since startDate: Date) -> [TrackerUsageHistoryPoint] {
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
            return TrackerUsageHistoryPoint(
                id: sample.id,
                date: sample.date,
                percent: percent,
                series: series
            )
        }
    }

    public func clear() {
        samples = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TrackerUsageHistorySample].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        samples = decoded.filter { $0.date >= cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

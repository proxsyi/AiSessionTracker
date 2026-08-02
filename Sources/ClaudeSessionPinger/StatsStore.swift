import Foundation

final class StatsStore: ObservableObject {
    @Published private(set) var records: [PingRecord] = []

    private let maxRecords = 50
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let folder = appSupport?.appendingPathComponent("GPTSessionPinger", isDirectory: true)
        if let folder = folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        fileURL = folder?.appendingPathComponent("history.json") ?? URL(fileURLWithPath: "/tmp/gpt-session-pinger-history.json")
        load()
    }

    var successCount: Int { records.filter { $0.success }.count }
    var totalCount: Int { records.count }
    var successRate: Double {
        guard totalCount > 0 else { return 0 }
        return Double(successCount) / Double(totalCount)
    }
    var lastRecord: PingRecord? { records.last }

    func addRecord(success: Bool, summary: String) {
        let record = PingRecord(id: UUID(), date: Date(), success: success, summary: summary)
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([PingRecord].self, from: data) {
            records = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

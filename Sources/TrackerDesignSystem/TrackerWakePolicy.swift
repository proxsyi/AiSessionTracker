import Foundation

/// Shared scheduling transaction. Tests inject a helper so no power settings are changed.
public enum TrackerWakeSchedule {
    public static func synchronize(provider: String, enabled: Bool, slots: [TrackerScheduleTime],
                                   testEpoch: Double, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                   run: ([String]) throws -> Void) throws -> [(wake: Date, ping: Date)] {
        precondition(provider == "claude" || provider == "codex")
        try run(["purge", provider])
        try run(["purge", "legacy"])
        // Provider purge also removes its pending test. Restore it before changing regular events.
        if testEpoch > now.timeIntervalSince1970 {
            try run(["schedule", provider, timestamp(testEpoch)])
        }
        guard enabled else { return [] }
        var pairs: [(wake: Date, ping: Date)] = []
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            for slot in slots {
                guard let ping = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day),
                      ping > now.addingTimeInterval(15) else { continue }
                pairs.append((ping.addingTimeInterval(-5), ping))
            }
        }
        pairs.sort { $0.ping < $1.ping }
        var installed: [Date] = []
        do {
            for pair in pairs {
                // The test can share the same timestamp as a regular event.
                guard timestamp(pair.wake.timeIntervalSince1970) != timestamp(testEpoch) else { continue }
                try run(["schedule", provider, timestamp(pair.wake.timeIntervalSince1970)])
                installed.append(pair.wake)
            }
        } catch {
            for date in installed { try? run(["cancel", provider, timestamp(date.timeIntervalSince1970)]) }
            throw error
        }
        return pairs
    }

    private static func timestamp(_ epoch: Double) -> String { String(format: "%.0f", epoch) }
}

/// A provider must not put the Mac to sleep while another provider is still sending.
@MainActor
public final class TrackerWakeActivity {
    public static let shared = TrackerWakeActivity()
    private var active: Set<UUID> = []
    private var processActivity: NSObjectProtocol?
    public init() {}
    public var isIdle: Bool { active.isEmpty }
    public func begin() -> UUID {
        if active.isEmpty {
            processActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                reason: "Completing a session ping")
        }
        let token = UUID()
        active.insert(token)
        return token
    }
    public func end(_ token: UUID) {
        active.remove(token)
        if active.isEmpty, let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
    }
    public func waitUntilIdle() async -> Bool {
        // Never sleep a continually busy app, and never outlive a cancelled wake task.
        for _ in 0..<120 {
            guard !Task.isCancelled else { return false }
            if isIdle { return true }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return false }
        }
        return false
    }
}

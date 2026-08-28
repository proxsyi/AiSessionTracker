import CoreGraphics
import Darwin
import Foundation
import IOKit

struct CodexWakeScheduleSummary: Sendable {
    let eventCount: Int
    let nextWake: Date?
}

enum CodexWakeTestOutcome: String {
    case pending
    case passed
    case failed
}

struct CodexWakeTestResult {
    let outcome: CodexWakeTestOutcome
    let message: String
}

enum CodexWakeSupportError: LocalizedError {
    case bundledHelperMissing
    case helperNotInstalled
    case installationFailed(String)
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing: return "The wake helper is missing from this app build."
        case .helperNotInstalled: return "Wake support needs its one-time administrator installation."
        case .installationFailed(let message): return "Wake support installation failed: \(message)"
        case .helperFailed(let message): return "Wake scheduling failed: \(message)"
        }
    }
}

/// Codex uses the same restricted helper binary as Claude, but owns separate
/// schedule and test records. Cancelling or rescheduling either provider can
/// therefore never remove the other provider's wake events.
enum CodexWakeSupport {
    static let helperVersion = "3"
    static let helperName = "com.proxsyi.sessiontracker.wake-helper"
    static let installedHelperURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(helperName)")
    static let wakeLeadTime: TimeInterval = 5
    static let wakeHoldDuration = 120
    static let resleepDelay: TimeInterval = 30
    static let activityTimingTolerance: TimeInterval = 3

    private static let scheduledWakeEpochsKey = "codexWakeSupportScheduledWakeEpochs"
    private static let scheduledPingEpochsKey = "codexWakeSupportScheduledPingEpochs"
    private static let testWakeEpochKey = "codexWakeSupportTestWakeEpoch"
    private static let testResultOutcomeKey = "codexWakeSupportTestResultOutcome"
    private static let testResultMessageKey = "codexWakeSupportTestResultMessage"

    static var bundledHelperURL: URL? {
        Bundle.main.url(forResource: "SessionPingerWakeHelper", withExtension: nil)
    }

    static var isInstalled: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: installedHelperURL.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              owner.intValue == 0,
              permissions.intValue & 0o4000 != 0,
              let output = try? runHelper(["version"]),
              output.trimmingCharacters(in: .whitespacesAndNewlines) == helperVersion else { return false }
        return true
    }

    static var lastTestResult: CodexWakeTestResult? {
        let defaults = UserDefaults.standard
        let epoch = defaults.double(forKey: testWakeEpochKey)
        if epoch > 0, Date().timeIntervalSince1970 > epoch + 300 {
            defaults.removeObject(forKey: testWakeEpochKey)
            saveTestResult(outcome: .failed, message: "Last Codex closed-lid test failed: the scheduled wake was not handled within five minutes.")
        }
        guard let raw = defaults.string(forKey: testResultOutcomeKey),
              let outcome = CodexWakeTestOutcome(rawValue: raw),
              let message = defaults.string(forKey: testResultMessageKey),
              !message.isEmpty else { return nil }
        return CodexWakeTestResult(outcome: outcome, message: message)
    }

    static func saveTestResult(outcome: CodexWakeTestOutcome, message: String) {
        UserDefaults.standard.set(outcome.rawValue, forKey: testResultOutcomeKey)
        UserDefaults.standard.set(message, forKey: testResultMessageKey)
    }

    static func installBundledHelper() throws {
        guard let source = bundledHelperURL else { throw CodexWakeSupportError.bundledHelperMissing }
        let script = """
        on run argv
            set sourcePath to item 1 of argv
            set destinationPath to item 2 of argv
            set allowedUID to item 3 of argv
            set supportPath to "/Library/Application Support/SessionTracker"
            set commandText to "/bin/mkdir -p " & quoted form of supportPath & " /Library/PrivilegedHelperTools && /usr/bin/install -o root -g wheel -m 4755 " & quoted form of sourcePath & " " & quoted form of destinationPath & " && /usr/bin/xattr -c " & quoted form of destinationPath & " && /usr/bin/printf '%s\\n' " & quoted form of allowedUID & " > " & quoted form of (supportPath & "/allowed_uid") & " && /usr/sbin/chown root:wheel " & quoted form of (supportPath & "/allowed_uid") & " && /bin/chmod 600 " & quoted form of (supportPath & "/allowed_uid")
            do shell script commandText with administrator privileges
        end run
        """
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, source.path, installedHelperURL.path, String(getuid())]
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CodexWakeSupportError.installationFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexWakeSupportError.installationFailed(message?.isEmpty == false ? message! : "Administrator approval was cancelled.")
        }
        guard isInstalled else {
            throw CodexWakeSupportError.installationFailed("The installed helper failed ownership, permission, user, or version verification.")
        }
    }

    static func syncSchedule(enabled: Bool, slots: [CodexSessionPinger.ScheduleSlot], now: Date = Date()) throws -> CodexWakeScheduleSummary {
        let defaults = UserDefaults.standard
        let previous = defaults.array(forKey: scheduledWakeEpochsKey) as? [Double] ?? []
        if isInstalled {
            for epoch in previous { _ = try? runHelper(["cancel", "codex", timestampArgument(epoch)]) }
        }
        defaults.removeObject(forKey: scheduledWakeEpochsKey)
        defaults.removeObject(forKey: scheduledPingEpochsKey)
        guard enabled else { return CodexWakeScheduleSummary(eventCount: 0, nextWake: nil) }
        guard isInstalled else { throw CodexWakeSupportError.helperNotInstalled }

        let pairs = futurePingDates(slots: slots, now: now).compactMap { ping -> (wake: Date, ping: Date)? in
            let wake = ping.addingTimeInterval(-wakeLeadTime)
            return wake > now.addingTimeInterval(10) ? (wake, ping) : nil
        }
        var scheduled: [Date] = []
        do {
            for pair in pairs {
                try runHelper(["schedule", "codex", timestampArgument(pair.wake.timeIntervalSince1970)])
                scheduled.append(pair.wake)
            }
        } catch {
            for date in scheduled { _ = try? runHelper(["cancel", "codex", timestampArgument(date.timeIntervalSince1970)]) }
            throw error
        }
        defaults.set(pairs.map { $0.wake.timeIntervalSince1970 }, forKey: scheduledWakeEpochsKey)
        defaults.set(pairs.map { $0.ping.timeIntervalSince1970 }, forKey: scheduledPingEpochsKey)
        return CodexWakeScheduleSummary(eventCount: pairs.count, nextWake: pairs.first?.wake)
    }

    static func scheduleTestWake(after delay: TimeInterval = 120) throws -> Date {
        guard isInstalled else { throw CodexWakeSupportError.helperNotInstalled }
        let defaults = UserDefaults.standard
        let previous = defaults.double(forKey: testWakeEpochKey)
        if previous > 0 { _ = try? runHelper(["cancel", "codex", timestampArgument(previous)]) }
        let date = Date().addingTimeInterval(delay)
        try runHelper(["schedule", "codex", timestampArgument(date.timeIntervalSince1970)])
        defaults.set(date.timeIntervalSince1970, forKey: testWakeEpochKey)
        saveTestResult(outcome: .pending, message: "Codex closed-lid test scheduled for \(date.formatted(date: .omitted, time: .shortened)).")
        return date
    }

    static func consumeSuccessfulTestWake(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let epoch = defaults.double(forKey: testWakeEpochKey)
        guard epoch > 0 else { return false }
        let scheduled = Date(timeIntervalSince1970: epoch)
        if now >= scheduled.addingTimeInterval(-15), now.timeIntervalSince(scheduled) <= 300 {
            defaults.removeObject(forKey: testWakeEpochKey)
            saveTestResult(outcome: .pending, message: "Mac woke successfully; checking the Codex test ping…")
            return true
        }
        return false
    }

    static func matchingScheduledPingAfterWake(now: Date = Date()) -> Date? {
        guard userIdleSeconds >= 30 else { return nil }
        let defaults = UserDefaults.standard
        var wakes = defaults.array(forKey: scheduledWakeEpochsKey) as? [Double] ?? []
        var pings = defaults.array(forKey: scheduledPingEpochsKey) as? [Double] ?? []
        guard wakes.count == pings.count else { return nil }
        for index in wakes.indices {
            let wake = Date(timeIntervalSince1970: wakes[index])
            if abs(now.timeIntervalSince(wake)) <= 300 {
                let ping = Date(timeIntervalSince1970: pings[index])
                wakes.remove(at: index)
                pings.remove(at: index)
                defaults.set(wakes, forKey: scheduledWakeEpochsKey)
                defaults.set(pings, forKey: scheduledPingEpochsKey)
                return ping
            }
        }
        return nil
    }

    static var userIdleSeconds: TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                return value.doubleValue / 1_000_000_000
            }
        }
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    static func userWasActive(since startedAt: Date, now: Date = Date()) -> Bool {
        userIdleSeconds + activityTimingTolerance < max(0, now.timeIntervalSince(startedAt))
    }

    static func beginWakeHold() throws {
        guard isInstalled else { throw CodexWakeSupportError.helperNotInstalled }
        let process = Process()
        process.executableURL = installedHelperURL
        process.arguments = ["hold", String(wakeHoldDuration)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw CodexWakeSupportError.helperFailed(error.localizedDescription) }
    }

    static func requestSystemSleep() throws {
        guard isInstalled else { throw CodexWakeSupportError.helperNotInstalled }
        _ = try runHelper(["sleep"])
    }

    private static func futurePingDates(slots: [CodexSessionPinger.ScheduleSlot], now: Date) -> [Date] {
        let calendar = Calendar.autoupdatingCurrent
        var dates: [Date] = []
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            for slot in slots {
                if let date = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day),
                   date > now.addingTimeInterval(wakeLeadTime + 10) { dates.append(date) }
            }
        }
        return dates.sorted()
    }

    @discardableResult
    private static func runHelper(_ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = installedHelperURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CodexWakeSupportError.helperFailed(error.localizedDescription)
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexWakeSupportError.helperFailed(message?.isEmpty == false ? message! : "Helper exited with status \(process.terminationStatus).")
        }
        return output
    }

    private static func timestampArgument(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

import Foundation
import CoreGraphics
import IOKit
import Darwin

struct WakeScheduleSummary: Sendable {
    let eventCount: Int
    let nextWake: Date?
}

enum WakeTestOutcome: String {
    case pending
    case passed
    case failed
}

struct WakeTestResult {
    let outcome: WakeTestOutcome
    let message: String
}

enum WakeSupportError: LocalizedError {
    case bundledHelperMissing
    case helperNotInstalled
    case installationFailed(String)
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing:
            return "The wake helper is missing from this app build."
        case .helperNotInstalled:
            return "Wake support needs its one-time administrator installation."
        case .installationFailed(let message):
            return "Wake support installation failed: \(message)"
        case .helperFailed(let message):
            return "Wake scheduling failed: \(message)"
        }
    }
}

/// Bridges the user app to a tiny, root-owned helper restricted to the user
/// who installed it. The helper accepts only fixed wake, cancel, and sleep
/// operations and never executes caller-supplied shell commands.
enum WakeSupport {
    static let helperVersion = "2"
    static let helperName = "com.proxsyi.claudesessionpinger.wake-helper"
    static let installedHelperURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(helperName)")
    static let wakeLeadTime: TimeInterval = 5
    static let wakeHoldDuration: Int = 120
    static let resleepDelay: TimeInterval = 30
    static let activityTimingTolerance: TimeInterval = 3

    private static let scheduledWakeEpochsKey = "wakeSupportScheduledWakeEpochs"
    private static let scheduledPingEpochsKey = "wakeSupportScheduledPingEpochs"
    private static let testWakeEpochKey = "wakeSupportTestWakeEpoch"
    private static let testResultOutcomeKey = "wakeSupportTestResultOutcome"
    private static let testResultMessageKey = "wakeSupportTestResultMessage"

    static var lastTestResult: WakeTestResult? {
        let defaults = UserDefaults.standard
        let epoch = defaults.double(forKey: testWakeEpochKey)
        if epoch > 0, Date().timeIntervalSince1970 > epoch + (5 * 60) {
            defaults.removeObject(forKey: testWakeEpochKey)
            saveTestResult(
                outcome: .failed,
                message: "Last closed-lid test failed: the scheduled wake was not handled within five minutes."
            )
        }
        guard let rawOutcome = defaults.string(forKey: testResultOutcomeKey),
              let outcome = WakeTestOutcome(rawValue: rawOutcome),
              let message = defaults.string(forKey: testResultMessageKey),
              !message.isEmpty else { return nil }
        return WakeTestResult(outcome: outcome, message: message)
    }

    static func saveTestResult(outcome: WakeTestOutcome, message: String) {
        let defaults = UserDefaults.standard
        defaults.set(outcome.rawValue, forKey: testResultOutcomeKey)
        defaults.set(message, forKey: testResultMessageKey)
    }

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
              output.trimmingCharacters(in: .whitespacesAndNewlines) == helperVersion else {
            return false
        }
        return true
    }

    static func installBundledHelper() throws {
        guard let source = bundledHelperURL else { throw WakeSupportError.bundledHelperMissing }

        let script = """
        on run argv
            set sourcePath to item 1 of argv
            set destinationPath to item 2 of argv
            set allowedUID to item 3 of argv
            set supportPath to "/Library/Application Support/SessionPinger"
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
            throw WakeSupportError.installationFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WakeSupportError.installationFailed(message?.isEmpty == false ? message! : "Administrator approval was cancelled.")
        }
        guard isInstalled else {
            throw WakeSupportError.installationFailed("The installed helper failed ownership, permission, user, or version verification.")
        }
    }

    static func syncSchedule(enabled: Bool, slots: [ScheduleSlot], now: Date = Date()) throws -> WakeScheduleSummary {
        let defaults = UserDefaults.standard
        let previousWakeEpochs = defaults.array(forKey: scheduledWakeEpochsKey) as? [Double] ?? []
        if isInstalled {
            for epoch in previousWakeEpochs {
                _ = try? runHelper(["cancel", timestampArgument(epoch)])
            }
        }
        defaults.removeObject(forKey: scheduledWakeEpochsKey)
        defaults.removeObject(forKey: scheduledPingEpochsKey)

        guard enabled else { return WakeScheduleSummary(eventCount: 0, nextWake: nil) }
        guard isInstalled else { throw WakeSupportError.helperNotInstalled }

        let pingDates = futurePingDates(slots: slots, now: now)
        let pairs = pingDates.compactMap { ping -> (wake: Date, ping: Date)? in
            let wake = ping.addingTimeInterval(-wakeLeadTime)
            return wake > now.addingTimeInterval(10) ? (wake, ping) : nil
        }
        var scheduled: [Date] = []
        do {
            for pair in pairs {
                try runHelper(["schedule", timestampArgument(pair.wake.timeIntervalSince1970)])
                scheduled.append(pair.wake)
            }
        } catch {
            for date in scheduled {
                _ = try? runHelper(["cancel", timestampArgument(date.timeIntervalSince1970)])
            }
            throw error
        }

        defaults.set(pairs.map { $0.wake.timeIntervalSince1970 }, forKey: scheduledWakeEpochsKey)
        defaults.set(pairs.map { $0.ping.timeIntervalSince1970 }, forKey: scheduledPingEpochsKey)
        return WakeScheduleSummary(eventCount: pairs.count, nextWake: pairs.first?.wake)
    }

    static func scheduleTestWake(after delay: TimeInterval = 120) throws -> Date {
        guard isInstalled else { throw WakeSupportError.helperNotInstalled }
        let defaults = UserDefaults.standard
        let previousEpoch = defaults.double(forKey: testWakeEpochKey)
        if previousEpoch > 0 {
            _ = try? runHelper(["cancel", timestampArgument(previousEpoch)])
        }
        let date = Date().addingTimeInterval(delay)
        try runHelper(["schedule", timestampArgument(date.timeIntervalSince1970)])
        defaults.set(date.timeIntervalSince1970, forKey: testWakeEpochKey)
        saveTestResult(
            outcome: .pending,
            message: "Closed-lid test scheduled for \(date.formatted(date: .omitted, time: .shortened))."
        )
        return date
    }

    static func consumeSuccessfulTestWake(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let epoch = defaults.double(forKey: testWakeEpochKey)
        guard epoch > 0 else { return false }
        let scheduled = Date(timeIntervalSince1970: epoch)
        if now >= scheduled.addingTimeInterval(-15), now.timeIntervalSince(scheduled) <= 5 * 60 {
            defaults.removeObject(forKey: testWakeEpochKey)
            saveTestResult(outcome: .pending, message: "Mac woke successfully; checking the test ping…")
            return true
        }
        if now.timeIntervalSince(scheduled) > 10 * 60 {
            defaults.removeObject(forKey: testWakeEpochKey)
        }
        return false
    }

    static func matchingScheduledPingAfterWake(now: Date = Date()) -> Date? {
        guard userIdleSeconds >= 30 else { return nil }
        let defaults = UserDefaults.standard
        var wakeEpochs = defaults.array(forKey: scheduledWakeEpochsKey) as? [Double] ?? []
        var pingEpochs = defaults.array(forKey: scheduledPingEpochsKey) as? [Double] ?? []
        guard wakeEpochs.count == pingEpochs.count else { return nil }
        for index in wakeEpochs.indices {
            let wake = Date(timeIntervalSince1970: wakeEpochs[index])
            if abs(now.timeIntervalSince(wake)) <= 5 * 60 {
                let ping = Date(timeIntervalSince1970: pingEpochs[index])
                wakeEpochs.remove(at: index)
                pingEpochs.remove(at: index)
                defaults.set(wakeEpochs, forKey: scheduledWakeEpochsKey)
                defaults.set(pingEpochs, forKey: scheduledPingEpochsKey)
                return ping
            }
        }
        return nil
    }

    /// Prefer IOHIDSystem's hardware-input idle timer. Quartz's combined
    /// session state includes every event source posting into the login
    /// session, so wake-time software events can look like user activity.
    static var userIdleSeconds: TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let property = IORegistryEntryCreateCFProperty(
                service,
                "HIDIdleTime" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? NSNumber {
                return property.doubleValue / 1_000_000_000
            }
        }
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Determine whether physical input occurred during this app-controlled
    /// post-ping observation window. Comparing idle time with the elapsed
    /// window avoids the old impossible condition where a 30-second wait was
    /// tested against a fixed 60-second idle requirement after wake.
    static func userWasActive(since observationStartedAt: Date, now: Date = Date()) -> Bool {
        let observedDuration = max(0, now.timeIntervalSince(observationStartedAt))
        return userIdleSeconds + activityTimingTolerance < observedDuration
    }

    static func requestSystemSleep() throws {
        guard isInstalled else { throw WakeSupportError.helperNotInstalled }
        try runHelper(["sleep"])
    }

    /// Starts a separate helper process that owns a PreventSystemSleep power
    /// assertion. Returning immediately is important because the native
    /// clamshell wake window lasts only about ten seconds.
    static func beginWakeHold() throws {
        guard isInstalled else { throw WakeSupportError.helperNotInstalled }
        let process = Process()
        process.executableURL = installedHelperURL
        process.arguments = ["hold", String(wakeHoldDuration)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw WakeSupportError.helperFailed(error.localizedDescription)
        }
    }

    static func appendDiagnostic(_ message: String) {
        let manager = FileManager.default
        guard let appSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = appSupport.appendingPathComponent("ClaudeSessionPinger", isDirectory: true)
        let file = folder.appendingPathComponent("wake-events.log")
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !manager.fileExists(atPath: file.path) {
            try? data.write(to: file, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private static func futurePingDates(slots: [ScheduleSlot], now: Date) -> [Date] {
        let calendar = Calendar.autoupdatingCurrent
        var dates: [Date] = []
        for dayOffset in 0...7 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            for slot in slots {
                if let date = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: dayStart),
                   date > now.addingTimeInterval(wakeLeadTime + 10) {
                    dates.append(date)
                }
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
            throw WakeSupportError.helperFailed(error.localizedDescription)
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WakeSupportError.helperFailed(message?.isEmpty == false ? message! : "Helper exited with status \(process.terminationStatus).")
        }
        return output
    }

    private static func timestampArgument(_ timestamp: Double) -> String {
        String(format: "%.0f", timestamp)
    }
}

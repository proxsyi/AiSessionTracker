import AppKit
import Foundation
import TrackerDesignSystem
import UserNotifications

private actor CodexWakeScheduleCoordinator {
    private var latestGeneration = 0

    func synchronize(
        generation: Int,
        enabled: Bool,
        slots: [CodexSessionPinger.ScheduleSlot]
    ) throws -> CodexWakeScheduleSummary? {
        guard generation >= latestGeneration else { return nil }
        latestGeneration = generation
        return try CodexWakeSupport.syncSchedule(enabled: enabled, slots: slots)
    }
}

/// A combined-app-only scheduler for a light Codex prompt. Its state is kept
/// separate from the normal ChatGPT pinger so each service always reuses its
/// own dedicated conversation.
@MainActor
final class CodexSessionPinger: ObservableObject {
    enum CountdownFocus: String, CaseIterable, Identifiable {
        case nextPossible
        case scheduled

        var id: String { rawValue }
        var label: String { self == .nextPossible ? "Next possible" : "Scheduled" }
    }

    struct ScheduleSlot: Codable, Hashable, Identifiable {
        var hour: Int
        var minute: Int

        var id: String { "\\(hour)-\\(minute)" }
        var dateComponents: DateComponents { DateComponents(hour: hour, minute: minute) }
    }

    struct PingRecord: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        let success: Bool
        let summary: String
        let model: String?
        let conversationID: String?
    }

    private enum Keys {
        static let enabled = "codexSessionPingerEnabled"
        static let model = "codexSessionPingerModel"
        static let reasoningEffort = "codexSessionPingerReasoningEffort"
        static let message = "codexSessionPingerMessage"
        static let conversationID = "codexSessionPingerConversationID"
        static let parentMessageID = "codexSessionPingerParentMessageID"
        static let firstPingPending = "codexSessionPingerFirstPingPending"
        static let slots = "codexSessionPingerScheduleSlots"
        static let lastResult = "codexSessionPingerLastResult"
        static let lastSuccess = "codexSessionPingerLastSuccess"
        static let notifyOnFailure = "codexSessionPingerNotifyOnFailure"
        static let notifyOnSuccess = "codexSessionPingerNotifyOnSuccess"
        static let notifySessionAvailable = "codexSessionPingerNotifySessionAvailable"
        static let notifySessionStarted = "codexSessionPingerNotifySessionStarted"
        static let showNextPossibleCountdown = "codexSessionPingerShowNextPossibleCountdown"
        static let showScheduledCountdown = "codexSessionPingerShowScheduledCountdown"
        static let countdownFocus = "codexSessionPingerCountdownFocus"
        static let autoStartAvailableSessions = "codexSessionPingerAutoStartAvailableSessions"
        static let history = "codexSessionPingerHistory"
        static let confirmedModelRecordingVersion = "codexSessionPingerConfirmedModelRecordingVersion"
        static let enableScheduledWake = "codexSessionPingerEnableScheduledWake"
        static let workComposerMigrationVersion = "codexSessionPingerWorkComposerMigrationVersion"
    }

    private static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == "com.proxsyi.sessiontracker" { return .standard }
        return UserDefaults(suiteName: "com.proxsyi.sessiontracker") ?? .standard
    }()
    private static let minimumSpacing: TimeInterval = 5 * 60 * 60

    @Published var enabled: Bool { didSet { save(); reschedule() } }
    @Published var model: String { didSet { save() } }
    @Published var reasoningEffort: String { didSet { save() } }
    @Published var message: String { didSet { save() } }
    @Published private(set) var conversationID: String { didSet { save() } }
    @Published var parentMessageID: String { didSet { save() } }
    @Published var slots: [ScheduleSlot] { didSet { save(); reschedule() } }
    @Published var notifyOnFailure: Bool { didSet { save() } }
    @Published var notifyOnSuccess: Bool { didSet { save() } }
    @Published var notifySessionAvailable: Bool { didSet { save() } }
    @Published var notifySessionStarted: Bool { didSet { save() } }
    @Published var showNextPossibleCountdown: Bool { didSet { save() } }
    @Published var showScheduledCountdown: Bool { didSet { save() } }
    @Published var countdownFocus: CountdownFocus { didSet { save() } }
    @Published var autoStartAvailableSessions: Bool { didSet { save(); startAvailableSessionIfNeeded() } }
    @Published var enableScheduledWake: Bool { didSet { save(); synchronizeWakeSchedule() } }
    @Published private(set) var isPinging = false
    @Published private(set) var status: String?
    @Published private(set) var nextFireDate: Date?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var records: [PingRecord]
    @Published private(set) var activeModel: String?
    @Published private(set) var wakeHelperInstalled = CodexWakeSupport.isInstalled
    @Published private(set) var isInstallingWakeSupport = false
    @Published private(set) var wakeSupportStatus = CodexWakeSupport.isInstalled
        ? "Wake support is installed."
        : "One-time administrator installation required."
    @Published private(set) var wakeTestResult = CodexWakeSupport.lastTestResult

    private let settings: SettingsStore
    private let hostAllowsPinging: Bool
    private let timer = TrackerInvalidatingTimer()
    private var rollingFiveHourPercent: Int?
    private var rollingFiveHourReset: Date?
    private var previousRollingFiveHourPercent: Int?
    private var previousRollingFiveHourReset: Date?
    private var usageBaselined = false
    private var autoStartPending = false
    private var wakeSyncGeneration = 0
    private let wakeScheduleCoordinator = CodexWakeScheduleCoordinator()
    private var automaticWakeTask: Task<Void, Never>?

    init(settings: SettingsStore, hostAllowsPinging: Bool = false) {
        self.settings = settings
        self.hostAllowsPinging = hostAllowsPinging
        let defaults = Self.defaults
        let workComposerMigrationVersion = defaults.integer(forKey: Keys.workComposerMigrationVersion)
        let requiresWorkComposerMigration = workComposerMigrationVersion < 1
        let requiresLowestWorkSelectionMigration = workComposerMigrationVersion < 2
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        let storedModel = defaults.string(forKey: Keys.model)
        let selectedModel = requiresLowestWorkSelectionMigration || storedModel == nil || storedModel?.hasSuffix("-wm") != true
            ? ChatGPTModelCatalog.lowestUsageWorkModelSlug
            : storedModel!
        model = selectedModel
        let storedEffort = defaults.string(forKey: Keys.reasoningEffort)
        reasoningEffort = requiresLowestWorkSelectionMigration || !["min", "standard", "extended"].contains(storedEffort ?? "")
            ? "min"
            : storedEffort!
        message = defaults.string(forKey: Keys.message) ?? "Say 1"
        conversationID = requiresWorkComposerMigration ? "" : (defaults.string(forKey: Keys.conversationID) ?? "")
        parentMessageID = requiresWorkComposerMigration ? "" : (defaults.string(forKey: Keys.parentMessageID) ?? "")
        if let data = defaults.data(forKey: Keys.slots),
           let decoded = try? JSONDecoder().decode([ScheduleSlot].self, from: data),
           Self.validationMessage(for: decoded) == nil {
            slots = decoded
        } else {
            slots = [5, 10, 15, 20].map { ScheduleSlot(hour: $0, minute: 0) }
        }
        status = defaults.string(forKey: Keys.lastResult)
        lastSuccess = defaults.object(forKey: Keys.lastSuccess) as? Date
        notifyOnFailure = defaults.object(forKey: Keys.notifyOnFailure) as? Bool ?? true
        notifyOnSuccess = defaults.object(forKey: Keys.notifyOnSuccess) as? Bool ?? true
        notifySessionAvailable = defaults.object(forKey: Keys.notifySessionAvailable) as? Bool ?? true
        notifySessionStarted = defaults.object(forKey: Keys.notifySessionStarted) as? Bool ?? true
        showNextPossibleCountdown = defaults.object(forKey: Keys.showNextPossibleCountdown) as? Bool ?? true
        showScheduledCountdown = defaults.object(forKey: Keys.showScheduledCountdown) as? Bool ?? true
        countdownFocus = CountdownFocus(rawValue: defaults.string(forKey: Keys.countdownFocus) ?? "") ?? .nextPossible
        autoStartAvailableSessions = defaults.bool(forKey: Keys.autoStartAvailableSessions)
        enableScheduledWake = defaults.bool(forKey: Keys.enableScheduledWake)
        if let data = defaults.data(forKey: Keys.history),
           let decoded = try? JSONDecoder().decode([PingRecord].self, from: data) {
            let recent = Array(decoded.suffix(50))
            if defaults.integer(forKey: Keys.confirmedModelRecordingVersion) < 1 {
                records = recent.map {
                    PingRecord(id: $0.id, date: $0.date, success: $0.success, summary: $0.summary, model: nil, conversationID: $0.conversationID)
                }
                defaults.set(1, forKey: Keys.confirmedModelRecordingVersion)
                if let migrated = try? JSONEncoder().encode(records) {
                    defaults.set(migrated, forKey: Keys.history)
                }
            } else {
                records = recent
            }
        } else {
            records = []
            defaults.set(1, forKey: Keys.confirmedModelRecordingVersion)
        }
        activeModel = records.last(where: { $0.success })?.model
        if requiresLowestWorkSelectionMigration {
            defaults.set(2, forKey: Keys.workComposerMigrationVersion)
            defaults.set(selectedModel, forKey: Keys.model)
            defaults.set(reasoningEffort, forKey: Keys.reasoningEffort)
        }
        if requiresWorkComposerMigration {
            defaults.removeObject(forKey: Keys.conversationID)
            defaults.removeObject(forKey: Keys.parentMessageID)
        }
        if hostAllowsPinging {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(handleWake),
                name: NSWorkspace.didWakeNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleTimeZoneChange),
                name: NSNotification.Name.NSSystemTimeZoneDidChange,
                object: nil
            )
            reschedule()
        }
    }

    deinit {
        automaticWakeTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    var scheduleValidationMessage: String? { Self.validationMessage(for: slots) }

    private static func validationMessage(for slots: [ScheduleSlot]) -> String? {
        let sorted = slots.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        guard !sorted.isEmpty else { return "Add at least one scheduled Codex ping." }
        guard sorted.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else {
            return "Choose a valid time for every scheduled Codex ping."
        }
        guard sorted.count > 1 else { return nil }
        let minutes = sorted.map { $0.hour * 60 + $0.minute }
        for index in minutes.indices {
            let next = index == minutes.count - 1 ? minutes[0] + 24 * 60 : minutes[index + 1]
            if next - minutes[index] < 5 * 60 {
                return "Scheduled Codex pings must be at least 5 hours apart, including overnight."
            }
        }
        return nil
    }

    func pingNow() {
        guard hostAllowsPinging else { return }
        Task { _ = await sendPing(manual: true) }
    }

    func testConnection() async -> String {
        guard hostAllowsPinging else { return "Codex session pinging is available only in Session Tracker." }
        _ = await sendPing(manual: true)
        return status ?? "Codex connection test finished."
    }

    func startFreshChat() {
        guard !isPinging else { return }
        Self.defaults.removeObject(forKey: Keys.firstPingPending)
        conversationID = ""
        parentMessageID = ""
        status = "The next Codex ping will use a new dedicated chat."
    }

    var needsChatRecovery: Bool {
        conversationID.isEmpty && Self.defaults.bool(forKey: Keys.firstPingPending)
    }

    func nextPossibleSessionDate(now: Date = Date(), resetDate: Date? = nil) -> Date {
        Self.nextPossibleSessionDate(
            now: now,
            rollingReset: resetDate ?? rollingFiveHourReset,
            lastSuccess: lastSuccess
        )
    }

    static func nextPossibleSessionDate(now: Date, rollingReset: Date?, lastSuccess: Date?) -> Date {
        if let rollingReset, rollingReset > now { return rollingReset }
        if let lastSuccess { return max(now, lastSuccess.addingTimeInterval(Self.minimumSpacing)) }
        return now
    }

    var successCount: Int { records.filter(\.success).count }
    var totalCount: Int { records.count }
    var successRateText: String {
        guard totalCount > 0 else { return "No pings yet" }
        return "\(successCount)/\(totalCount) (\(Int((Double(successCount) / Double(totalCount)) * 100))%)"
    }
    var lastResultText: String { records.last?.summary ?? "—" }
    var conversationURL: URL? {
        guard !conversationID.isEmpty else { return nil }
        return URL(string: "https://chatgpt.com/c/\(conversationID)")
    }

    func updateUsage(_ usage: GPTUsage?) {
        guard hostAllowsPinging else { return }
        previousRollingFiveHourPercent = rollingFiveHourPercent
        previousRollingFiveHourReset = rollingFiveHourReset
        rollingFiveHourPercent = usage?.rollingFiveHourPercent
        rollingFiveHourReset = usage?.rollingFiveHourResetsAt

        defer { usageBaselined = usage != nil }
        guard usage != nil else { return }
        if usageBaselined, sessionBecameAvailable(), notifySessionAvailable {
            notify(
                identifier: "codex-session-available",
                title: "A new Codex session is available",
                body: "Your previous rolling 5-hour Codex window reset."
            )
        }
        startAvailableSessionIfNeeded()
    }

    func reschedule() {
        timer.timer?.invalidate()
        guard hostAllowsPinging else {
            nextFireDate = nil
            return
        }
        guard enabled, scheduleValidationMessage == nil, let next = nextDate(after: Date()) else {
            nextFireDate = nil
            synchronizeWakeSchedule()
            return
        }
        nextFireDate = next
        let timer = Timer(timeInterval: max(next.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                _ = await self?.sendPing(manual: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer.timer = timer
        synchronizeWakeSchedule()
    }

    private func nextDate(after date: Date) -> Date? {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: date)
        return (0...1).compactMap { offset in
            guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: day) else { return nil }
            return slots.compactMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: candidateDay) }
                .filter { $0 > date }
                .min()
        }.min()
    }

    @discardableResult
    private func sendPing(manual: Bool) async -> Bool {
        guard hostAllowsPinging else { return false }
        guard !isPinging else { return false }
        guard !needsChatRecovery else {
            status = "The first ping's chat was not confirmed. Automatic creation is paused to avoid a duplicate. Check Work before choosing Start fresh chat."
            return false
        }
        guard settings.isConfigured else {
            status = "Sign in to ChatGPT before sending a Codex ping."
            addRecord(success: false, summary: status ?? "Missing credentials", model: nil)
            return false
        }
        isPinging = true
        status = nil
        defer { isPinging = false }
        let maxAttempts = 3
        var finalError: Error?
        for attempt in 1...maxAttempts {
            do {
                let auth = try await ChatGPTWebSession.resolve(
                    savedCredential: settings.sessionKey,
                    accountID: settings.organizationID,
                    cookieHeader: settings.effectiveCookieHeader
                )
                if conversationID.isEmpty {
                    // Persist before sending: a crash or uncertain first delivery
                    // must not silently create another chat on the next launch.
                    Self.defaults.set(true, forKey: Keys.firstPingPending)
                }
                let outcome = try await ChatGPTClient.sendPing(
                    auth: auth,
                    cookieHeader: settings.effectiveCookieHeader,
                    model: model,
                    modelTitle: settings.pingModelTitle(for: model),
                    mode: .work,
                    reasoningEffort: reasoningEffort,
                    message: message,
                    conversationID: conversationID,
                    parentMessageID: parentMessageID,
                    onConversationIdentified: { [weak self] id in
                        guard let self else { return }
                        self.conversationID = id
                        Self.defaults.removeObject(forKey: Keys.firstPingPending)
                    }
                )
                conversationID = try ChatGPTConversationIdentity.validate(expected: conversationID, observed: outcome.conversationID)
                parentMessageID = outcome.parentMessageID
                lastSuccess = Date()
                activeModel = outcome.confirmedModel
                let confirmation = Self.modelConfirmationText(
                    requestedModel: model,
                    requestedEffort: reasoningEffort,
                    confirmedModel: outcome.confirmedModel,
                    confirmedEffort: outcome.confirmedReasoningEffort
                )
                status = (manual ? "Codex ping sent in its dedicated chat. " : "Scheduled Codex ping sent in its dedicated chat. ") + confirmation
                addRecord(success: true, summary: "Got reply", model: outcome.confirmedModel)
                Self.defaults.set(lastSuccess, forKey: Keys.lastSuccess)
                save()
                if notifySessionStarted {
                    notify(
                        identifier: "codex-session-started",
                        title: "New Codex session started",
                        body: manual ? "Your manual ping started a new Codex session." : "Session Tracker started a new Codex session."
                    )
                }
                if !manual && notifyOnSuccess {
                    notify(
                        identifier: "codex-session-ping-success",
                        title: "Scheduled Codex ping sent",
                        body: "The dedicated Codex chat was updated."
                    )
                }
                reschedule()
                return true
            } catch {
                finalError = error
                guard !needsChatRecovery else { break }
                guard attempt < maxAttempts, isRetryable(error) else { break }
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
            }
        }

        let message = (finalError as? ChatGPTPingError)?.localizedDescription
            ?? finalError?.localizedDescription
            ?? "The Codex ping failed."
        status = message
        addRecord(success: false, summary: message, model: nil)
        save()
        if notifyOnFailure {
            notify(
                identifier: "codex-session-ping-failure",
                title: manual ? "Codex ping failed" : "Scheduled Codex ping failed",
                body: message
            )
        }
        reschedule()
        return false
    }

    private func sessionBecameAvailable() -> Bool {
        let percentReset = (previousRollingFiveHourPercent ?? 0) >= 100
            && (rollingFiveHourPercent ?? 100) < 100
        let resetRolled = previousRollingFiveHourReset.map { previous in
            guard let current = rollingFiveHourReset else { return false }
            return previous <= Date() && current.timeIntervalSince(previous) > 120
        } ?? false
        return percentReset || resetRolled
    }

    private func startAvailableSessionIfNeeded(now: Date = Date()) {
        guard autoStartAvailableSessions,
              !isPinging,
              !autoStartPending,
              let percent = rollingFiveHourPercent,
              percent < 100 else { return }
        if let next = nextDate(after: now), next.timeIntervalSince(now) <= Self.minimumSpacing { return }
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < Self.minimumSpacing { return }
        autoStartPending = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.sendPing(manual: false)
            self.autoStartPending = false
        }
    }

    func installWakeSupport() {
        guard hostAllowsPinging else { return }
        guard !isInstallingWakeSupport else { return }
        isInstallingWakeSupport = true
        wakeSupportStatus = "Waiting for administrator approval…"
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CodexWakeSupport.installBundledHelper()
                }.value
                guard let self else { return }
                self.wakeHelperInstalled = CodexWakeSupport.isInstalled
                self.isInstallingWakeSupport = false
                self.wakeSupportStatus = "Wake support installed. Scheduling Codex wake events…"
                self.synchronizeWakeSchedule()
            } catch {
                guard let self else { return }
                self.wakeHelperInstalled = CodexWakeSupport.isInstalled
                self.isInstallingWakeSupport = false
                self.wakeSupportStatus = error.localizedDescription
            }
        }
    }

    func refreshWakeSupportState() {
        wakeHelperInstalled = CodexWakeSupport.isInstalled
        wakeTestResult = CodexWakeSupport.lastTestResult
        if wakeHelperInstalled {
            synchronizeWakeSchedule()
        } else if enableScheduledWake {
            wakeSupportStatus = "Setup required in System."
        }
    }

    func testWakeSupport() {
        guard hostAllowsPinging else { return }
        guard wakeHelperInstalled else {
            wakeSupportStatus = "Install wake support before scheduling a test."
            return
        }
        wakeSupportStatus = "Scheduling a two-minute Codex wake test…"
        Task { [weak self] in
            do {
                let date = try await Task.detached(priority: .userInitiated) {
                    try CodexWakeSupport.scheduleTestWake()
                }.value
                self?.wakeSupportStatus = "Codex wake/ping/sleep test set for \(date.formatted(date: .omitted, time: .shortened)). Close the lid while plugged in."
                self?.wakeTestResult = CodexWakeSupport.lastTestResult
            } catch {
                self?.wakeSupportStatus = error.localizedDescription
            }
        }
    }

    @objc private func handleWake() {
        guard hostAllowsPinging else { return }
        if CodexWakeSupport.consumeSuccessfulTestWake() {
            queueAutomaticWakePing(at: Date().addingTimeInterval(15), isTest: true)
        } else if enableScheduledWake,
                  let scheduled = CodexWakeSupport.matchingScheduledPingAfterWake() {
            queueAutomaticWakePing(at: scheduled, isTest: false)
        }
        synchronizeWakeSchedule()
    }

    @objc private func handleTimeZoneChange() {
        reschedule()
    }

    private func queueAutomaticWakePing(at date: Date, isTest: Bool) {
        automaticWakeTask?.cancel()
        do {
            try CodexWakeSupport.beginWakeHold()
            wakeSupportStatus = isTest
                ? "Mac woke successfully. Testing the Codex ping…"
                : "Mac woke for a scheduled Codex ping."
        } catch {
            wakeSupportStatus = error.localizedDescription
        }
        automaticWakeTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            let succeeded = await self.sendPing(manual: false)
            await self.returnToSleepAfterWake(testResult: isTest ? succeeded : nil)
        }
    }

    private func returnToSleepAfterWake(testResult: Bool?) async {
        wakeSupportStatus = "Codex ping finished. Waiting 30 seconds before returning to sleep."
        let observationStarted = Date()
        try? await Task.sleep(nanoseconds: UInt64(CodexWakeSupport.resleepDelay * 1_000_000_000))
        guard enableScheduledWake else { return }
        guard !CodexWakeSupport.userWasActive(since: observationStarted) else {
            wakeSupportStatus = "Stayed awake because the Mac is being used."
            if testResult != nil {
                CodexWakeSupport.saveTestResult(
                    outcome: .failed,
                    message: "The Codex wake test was incomplete because the Mac was active before return to sleep."
                )
                wakeTestResult = CodexWakeSupport.lastTestResult
            }
            return
        }
        do {
            if let testResult {
                CodexWakeSupport.saveTestResult(
                    outcome: testResult ? .passed : .failed,
                    message: testResult
                        ? "Codex closed-lid test passed: wake, ping, and return-to-sleep request succeeded."
                        : "Codex closed-lid test failed: the Mac woke, but the ping failed."
                )
                wakeTestResult = CodexWakeSupport.lastTestResult
            }
            wakeSupportStatus = "Returning the Mac to sleep…"
            try await Task.detached(priority: .utility) {
                try CodexWakeSupport.requestSystemSleep()
            }.value
        } catch {
            wakeSupportStatus = error.localizedDescription
        }
    }

    private func synchronizeWakeSchedule() {
        guard hostAllowsPinging else { return }
        wakeSyncGeneration += 1
        let generation = wakeSyncGeneration
        let wakeEnabled = enabled && enableScheduledWake
        let wakeSlots = slots
        wakeHelperInstalled = CodexWakeSupport.isInstalled
        if wakeEnabled && !wakeHelperInstalled {
            wakeSupportStatus = "Enabled, but the one-time administrator installation is still required."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let summary = try await self.wakeScheduleCoordinator.synchronize(
                    generation: generation,
                    enabled: wakeEnabled,
                    slots: wakeSlots
                ) else { return }
                guard generation == self.wakeSyncGeneration else { return }
                if wakeEnabled {
                    self.wakeSupportStatus = summary.nextWake.map {
                        "\(summary.eventCount) Codex wakes scheduled. Next: \($0.formatted(date: .abbreviated, time: .shortened))."
                    } ?? "Codex wake support is on; no future schedule is available yet."
                } else {
                    self.wakeSupportStatus = "Scheduled Codex wake is off."
                }
            } catch {
                guard generation == self.wakeSyncGeneration else { return }
                self.wakeSupportStatus = error.localizedDescription
            }
        }
    }

    private func addRecord(success: Bool, summary: String, model: String?) {
        records.append(PingRecord(id: UUID(), date: Date(), success: success, summary: summary, model: model, conversationID: conversationID.isEmpty ? nil : conversationID))
        if records.count > 50 { records.removeFirst(records.count - 50) }
        if let data = try? JSONEncoder().encode(records) { Self.defaults.set(data, forKey: Keys.history) }
    }

    nonisolated static func modelConfirmationText(
        requestedModel: String,
        requestedEffort: String,
        confirmedModel: String?,
        confirmedEffort: String?
    ) -> String {
        guard let confirmedModel else {
            return "Requested \(requestedModel) with \(requestedEffort) effort; ChatGPT did not expose confirmation."
        }
        if confirmedModel != requestedModel {
            let effort = confirmedEffort.map { " with \($0) effort" } ?? ""
            return "Requested \(requestedModel), but ChatGPT confirmed \(confirmedModel)\(effort)."
        }
        if requestedEffort != "none", requestedEffort != "default",
           let confirmedEffort, confirmedEffort != requestedEffort {
            return "ChatGPT confirmed \(confirmedModel), but used \(confirmedEffort) instead of \(requestedEffort) effort."
        }
        let effort = confirmedEffort.map { " with \($0) effort" } ?? ""
        return "ChatGPT confirmed \(confirmedModel)\(effort)."
    }

    private func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let pingError = error as? ChatGPTPingError else { return false }
        if case .serverError(let code, _) = pingError { return code == 0 || code >= 500 }
        return false
    }

    private func notify(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    private func save() {
        let defaults = Self.defaults
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(model, forKey: Keys.model)
        defaults.set(reasoningEffort, forKey: Keys.reasoningEffort)
        defaults.set(message, forKey: Keys.message)
        defaults.set(conversationID, forKey: Keys.conversationID)
        defaults.set(parentMessageID, forKey: Keys.parentMessageID)
        defaults.set(notifyOnFailure, forKey: Keys.notifyOnFailure)
        defaults.set(notifyOnSuccess, forKey: Keys.notifyOnSuccess)
        defaults.set(notifySessionAvailable, forKey: Keys.notifySessionAvailable)
        defaults.set(notifySessionStarted, forKey: Keys.notifySessionStarted)
        defaults.set(showNextPossibleCountdown, forKey: Keys.showNextPossibleCountdown)
        defaults.set(showScheduledCountdown, forKey: Keys.showScheduledCountdown)
        defaults.set(countdownFocus.rawValue, forKey: Keys.countdownFocus)
        defaults.set(autoStartAvailableSessions, forKey: Keys.autoStartAvailableSessions)
        defaults.set(enableScheduledWake, forKey: Keys.enableScheduledWake)
        defaults.set(status, forKey: Keys.lastResult)
        if let data = try? JSONEncoder().encode(slots) { defaults.set(data, forKey: Keys.slots) }
    }
}

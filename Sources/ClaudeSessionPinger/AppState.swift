import Foundation
import AppKit
import TrackerDesignSystem
import UserNotifications

private actor WakeScheduleCoordinator {
    private var latestGeneration = 0

    func synchronize(
        generation: Int,
        enabled: Bool,
        slots: [ScheduleSlot]
    ) throws -> WakeScheduleSummary? {
        guard generation >= latestGeneration else { return nil }
        latestGeneration = generation
        return try WakeSupport.syncSchedule(enabled: enabled, slots: slots)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: PingStatus = .idle
    @Published var lastError: String?
    @Published var nextFireDate: Date?
    @Published var availableUpdate: UpdateInfo?
    @Published var isCheckingForUpdates = false
    @Published var updateCheckError: String?
    @Published var isInstallingUpdate = false
    @Published var installUpdateError: String?
    @Published var usage: ClaudeUsage?
    @Published var usageError: String?
    @Published var isRefreshingUsage = false
    @Published var serviceStatus: ClaudeServiceStatus?
    /// Model slugs detected as available for this account (empty until fetched).
    @Published var availableModels: [String] = []
    /// The model the last successful ping actually used.
    @Published var activeModel: String?
    /// Result line for the Settings "Send test notification" button.
    @Published var notificationTestStatus: String?
    @Published var wakeHelperInstalled = WakeSupport.isInstalled
    @Published var isInstallingWakeSupport = false
    @Published var wakeSupportStatus = WakeSupport.isInstalled
        ? "Wake support is installed."
        : "One-time administrator installation required."
    @Published var wakeTestResult = WakeSupport.lastTestResult

    let settings: SettingsStore
    let stats: StatsStore
    let weeklyHistory = TrackerWeeklyHistoryStore(storageFolder: "ClaudeSessionPinger")
    var requestClosePopover: (() -> Void)?
    var requestTogglePopover: (() -> Void)?
    var requestTogglePopoverFromShortcut: (() -> Void)?
    var completePopoverShortcutPress: (() -> Void)?
    var requestShowSettings: (() -> Void)?
    var closeSettingsWindow: (() -> Void)?
    var toggleSettingsWindow: (() -> Void)?
    var requestSaveAndCloseSettings: (() -> Void)?
    private let scheduler = Scheduler()
    private var isPinging = false
    private var lastPingDate: Date?
    private let minimumGap: TimeInterval = 60
    private let scheduledStartProtectionWindow: TimeInterval = 5 * 60 * 60
    private var autoStartAttemptPending = false
    private var pendingAutomaticWakePing: Date?
    private var pendingAutomaticWakeIsTest = false
    private let automaticWakePingTask = TrackerCancellableTask()
    private var wakeSyncGeneration = 0
    private let wakeScheduleCoordinator = WakeScheduleCoordinator()
    private let updatesEnabled: Bool

    init(settings: SettingsStore, stats: StatsStore, updatesEnabled: Bool = true) {
        self.settings = settings
        self.stats = stats
        self.updatesEnabled = updatesEnabled
        scheduler.onFire = { [weak self] in
            Task { await self?.runScheduledPing() }
        }
        rescheduleTimer()
        requestNotificationPermission()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(handleTimeZoneChange), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        if updatesEnabled { scheduleUpdateChecks() }
        scheduleUsageRefreshes()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func rescheduleTimer() {
        let slots = settings.scheduledPingsEnabled ? settings.scheduleSlots : []
        scheduler.schedule(slots: slots)
        nextFireDate = scheduler.nextFireDate(slots: slots)
        synchronizeWakeSchedule()
    }

    func nextPossibleSessionDate(now: Date = Date()) -> Date {
        if let reset = usage?.sessionResetsAt, reset > now { return reset }
        if let percent = usage?.sessionPercent, percent < 100 { return now }

        let latestSuccessfulPing = stats.records.last(where: { $0.success })?.date
        if let lastStart = [lastPingDate, latestSuccessfulPing].compactMap({ $0 }).max() {
            return max(now, lastStart.addingTimeInterval(scheduledStartProtectionWindow))
        }

        // A missing reset must not make the card unusable. With no evidence
        // of a closed window, the next valid opportunity is the present.
        return now
    }

    @objc private func handleWake() {
        WakeSupport.appendDiagnostic("didWake received; idleSeconds=\(Int(WakeSupport.userIdleSeconds))")
        let completedWakeTest = WakeSupport.consumeSuccessfulTestWake()
        if completedWakeTest {
            beginAutomaticWakeHold()
            let testPing = Date().addingTimeInterval(15)
            wakeSupportStatus = "Wake test succeeded. Testing the ping in 15 seconds."
            sendNotification(
                identifier: "wake-test-succeeded",
                title: "Scheduled wake succeeded",
                body: "Session Pinger will test the ping, then return the idle Mac to sleep."
            )
            wakeTestResult = WakeSupport.lastTestResult
            queueAutomaticWakePing(at: testPing, isWakeTest: true)
        } else if settings.enableScheduledWake,
           let scheduledPing = WakeSupport.matchingScheduledPingAfterWake() {
            beginAutomaticWakeHold()
            queueAutomaticWakePing(at: scheduledPing)
        } else {
            WakeSupport.appendDiagnostic("wake did not match a Session Pinger event")
        }
        rescheduleTimer()
    }

    private func queueAutomaticWakePing(at date: Date, isWakeTest: Bool = false) {
        WakeSupport.appendDiagnostic("queued automatic ping for \(date.timeIntervalSince1970)")
        automaticWakePingTask.task?.cancel()
        pendingAutomaticWakePing = date
        pendingAutomaticWakeIsTest = isWakeTest
        let delay = max(0, date.timeIntervalSinceNow)
        automaticWakePingTask.task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledPing(automaticWakeDate: date)
        }
    }

    private func beginAutomaticWakeHold() {
        do {
            try WakeSupport.beginWakeHold()
            WakeSupport.appendDiagnostic("started \(WakeSupport.wakeHoldDuration)-second PreventSystemSleep assertion")
        } catch {
            WakeSupport.appendDiagnostic("failed to start wake assertion: \(error.localizedDescription)")
            wakeSupportStatus = error.localizedDescription
        }
    }

    @objc private func handleTimeZoneChange() {
        rescheduleTimer()
    }

    func pingNow() {
        Task { _ = await runPing(manual: true) }
    }

    private func runScheduledPing(automaticWakeDate: Date? = nil) async {
        guard settings.scheduledPingsEnabled || pendingAutomaticWakeIsTest else { return }
        // On some wakes an overdue Timer can run before NSWorkspace posts
        // didWake. Claim the stored wake here so the power assertion still
        // starts before any network request.
        if automaticWakeDate == nil,
           settings.enableScheduledWake,
           let scheduledPing = WakeSupport.matchingScheduledPingAfterWake() {
            WakeSupport.appendDiagnostic("scheduler claimed wake before didWake notification")
            beginAutomaticWakeHold()
            queueAutomaticWakePing(at: scheduledPing)
            return
        }

        if automaticWakeDate == nil, pendingAutomaticWakePing != nil {
            WakeSupport.appendDiagnostic("regular scheduler deferred to automatic wake owner")
            return
        }

        if let automaticWakeDate {
            guard let pending = pendingAutomaticWakePing,
                  abs(pending.timeIntervalSince(automaticWakeDate)) < 1 else {
                WakeSupport.appendDiagnostic("discarded stale automatic wake task")
                return
            }
            let isWakeTest = pendingAutomaticWakeIsTest
            pendingAutomaticWakePing = nil
            pendingAutomaticWakeIsTest = false
            automaticWakePingTask.task = nil
            WakeSupport.appendDiagnostic("automatic ping started")

            let completedPing = await runPing(manual: false)
            if completedPing {
                WakeSupport.appendDiagnostic("automatic ping finished; status=\(String(describing: status))")
                scheduleReturnToSleep(wakeTestPingSucceeded: isWakeTest ? status == .success : nil)
            } else {
                WakeSupport.appendDiagnostic("automatic ping skipped because another ping already owned execution")
                if isWakeTest {
                    updateWakeTestResult(
                        outcome: .failed,
                        message: "Last closed-lid test failed: another ping prevented the test ping from running."
                    )
                }
            }
            return
        }

        _ = await runPing(manual: false)
    }

    func installWakeSupport() {
        guard !isInstallingWakeSupport else { return }
        isInstallingWakeSupport = true
        wakeSupportStatus = "Waiting for administrator approval\u{2026}"
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WakeSupport.installBundledHelper()
                }.value
                guard let self else { return }
                self.wakeHelperInstalled = WakeSupport.isInstalled
                self.isInstallingWakeSupport = false
                self.wakeSupportStatus = "Wake support installed. Scheduling wake events\u{2026}"
                self.synchronizeWakeSchedule()
            } catch {
                guard let self else { return }
                self.wakeHelperInstalled = WakeSupport.isInstalled
                self.isInstallingWakeSupport = false
                self.wakeSupportStatus = error.localizedDescription
            }
        }
    }

    func testWakeSupport() {
        guard wakeHelperInstalled else {
            wakeSupportStatus = "Install wake support before scheduling a test."
            return
        }
        wakeSupportStatus = "Scheduling a two-minute wake test\u{2026}"
        Task { [weak self] in
            do {
                let date = try await Task.detached(priority: .userInitiated) {
                    try WakeSupport.scheduleTestWake()
                }.value
                self?.wakeSupportStatus = "Wake/ping/sleep test set for \(date.formatted(date: .omitted, time: .shortened)). Close the lid while plugged in."
                self?.wakeTestResult = WakeSupport.lastTestResult
            } catch {
                self?.wakeSupportStatus = error.localizedDescription
            }
        }
    }

    private func synchronizeWakeSchedule() {
        wakeSyncGeneration += 1
        let generation = wakeSyncGeneration
        let enabled = settings.enableScheduledWake && settings.scheduledPingsEnabled
        let slots = settings.scheduleSlots
        if !enabled {
            automaticWakePingTask.task?.cancel()
            automaticWakePingTask.task = nil
            pendingAutomaticWakePing = nil
            pendingAutomaticWakeIsTest = false
        }
        wakeHelperInstalled = WakeSupport.isInstalled
        if enabled && !wakeHelperInstalled {
            wakeSupportStatus = "Enabled, but the one-time administrator installation is still required."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let summary = try await self.wakeScheduleCoordinator.synchronize(
                    generation: generation,
                    enabled: enabled,
                    slots: slots
                ) else { return }
                guard generation == self.wakeSyncGeneration else { return }
                if enabled {
                    if let nextWake = summary.nextWake {
                        self.wakeSupportStatus = "\(summary.eventCount) wakes scheduled. Next: \(nextWake.formatted(date: .abbreviated, time: .shortened))."
                    } else {
                        self.wakeSupportStatus = "Wake support is on; no future schedule is available yet."
                    }
                } else {
                    self.wakeSupportStatus = "Scheduled wake is off."
                }
            } catch {
                guard generation == self.wakeSyncGeneration else { return }
                self.wakeSupportStatus = error.localizedDescription
                self.wakeHelperInstalled = WakeSupport.isInstalled
            }
        }
    }

    func refreshWakeTestResult() {
        wakeHelperInstalled = WakeSupport.isInstalled
        wakeTestResult = WakeSupport.lastTestResult
    }

    private func updateWakeTestResult(outcome: WakeTestOutcome, message: String) {
        WakeSupport.saveTestResult(outcome: outcome, message: message)
        wakeTestResult = WakeSupport.lastTestResult
    }

    private func scheduleReturnToSleep(wakeTestPingSucceeded: Bool? = nil) {
        wakeSupportStatus = "Ping finished. Waiting 30 seconds before returning to sleep."
        let activityObservationStartedAt = Date()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WakeSupport.resleepDelay * 1_000_000_000))
            guard let self, self.settings.enableScheduledWake else { return }
            let idleSeconds = WakeSupport.userIdleSeconds
            let activityObserved = WakeSupport.userWasActive(since: activityObservationStartedAt)
            WakeSupport.appendDiagnostic(
                "return-to-sleep activity check; idleSeconds=\(Int(idleSeconds)) observedSeconds=\(Int(Date().timeIntervalSince(activityObservationStartedAt))) active=\(activityObserved)"
            )
            guard !activityObserved else {
                WakeSupport.appendDiagnostic("return-to-sleep skipped; physical user activity occurred after ping")
                self.wakeSupportStatus = "Stayed awake because the Mac is being used."
                if wakeTestPingSucceeded != nil {
                    self.updateWakeTestResult(
                        outcome: .failed,
                        message: "Last closed-lid test was incomplete: the Mac was active, so return to sleep was skipped."
                    )
                }
                return
            }
            self.wakeSupportStatus = "Returning the Mac to sleep…"
            WakeSupport.appendDiagnostic("requesting system sleep")
            if let pingSucceeded = wakeTestPingSucceeded {
                let timestamp = Date().formatted(date: .abbreviated, time: .shortened)
                self.updateWakeTestResult(
                    outcome: pingSucceeded ? .passed : .failed,
                    message: pingSucceeded
                        ? "Closed-lid test passed at \(timestamp): wake, ping, and return-to-sleep request succeeded."
                        : "Closed-lid test failed at \(timestamp): the Mac woke, but the ping failed."
                )
            }
            do {
                try await Task.detached(priority: .utility) {
                    try WakeSupport.requestSystemSleep()
                }.value
            } catch {
                self.wakeSupportStatus = error.localizedDescription
                if wakeTestPingSucceeded != nil {
                    self.updateWakeTestResult(
                        outcome: .failed,
                        message: "Last closed-lid test failed while returning the Mac to sleep: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    struct PingConfiguration {
        let sessionKey: String
        let organizationID: String
        let cookieHeader: String
        let model: String
        let message: String
    }

    func testConnection(configuration: PingConfiguration) async -> String {
        guard !isPinging else { return "A Claude ping is already running." }
        _ = await runPing(manual: true, configuration: configuration)
        return status == .success ? "Success: got reply" : (lastError ?? "Claude ping failed.")
    }

    @discardableResult
    private func runPing(manual: Bool, configuration: PingConfiguration? = nil) async -> Bool {
        guard !isPinging else { return false }
        let request = configuration ?? PingConfiguration(sessionKey: settings.sessionKey,
            organizationID: settings.organizationID, cookieHeader: settings.effectiveCookieHeader,
            model: settings.model, message: settings.message)
        if let last = lastPingDate, !manual, Date().timeIntervalSince(last) < minimumGap {
            return false
        }
        guard !request.sessionKey.isEmpty, !request.organizationID.isEmpty else {
            status = .failure
            lastError = PingError.missingCredentials.localizedDescription
            stats.addRecord(success: false, summary: "Missing credentials")
            notifyFailureIfNeeded(message: lastError ?? "")
            rescheduleTimer()
            return true
        }

        isPinging = true
        status = .sending
        lastError = nil

        let maxAttempts = 3
        var attempt = 0
        var finished = false
        let candidates = modelCandidates(selectedModel: request.model)
        var modelIndex = 0

        while attempt < maxAttempts && !finished {
            attempt += 1
            let modelToUse = candidates[min(modelIndex, candidates.count - 1)]
            do {
                let outcome = try await ClaudeClient.sendPing(
                    sessionKey: request.sessionKey,
                    organizationID: request.organizationID,
                    model: modelToUse,
                    message: request.message,
                    conversationID: settings.conversationID,
                    cookieHeader: request.cookieHeader
                )
                settings.conversationID = outcome.conversationID
                activeModel = modelToUse
                lastPingDate = Date()
                status = outcome.matchedExpected ? .success : .failure
                let summary = outcome.matchedExpected ? "Got reply" : "Claude returned an empty reply"
                stats.addRecord(success: outcome.matchedExpected, summary: summary)
                if outcome.matchedExpected, let alert = TrackerPingAlertPolicy.success(
                    manual: manual, pingSent: settings.notifySessionStarted, scheduledPingSent: settings.notifyOnSuccess
                ) {
                    sendNotification(
                        identifier: "ping-sent",
                        title: alert == .scheduledPingSent ? "Scheduled Claude ping sent" : "Claude ping sent",
                        body: "Your dedicated Claude chat replied."
                    )
                }
                if !outcome.matchedExpected {
                    lastError = "Claude returned an empty reply."
                    notifyFailureIfNeeded(message: lastError ?? "")
                }
                rescheduleTimer()
                finished = true
            } catch let error as PingError {
                if isModelUnavailable(error), modelIndex + 1 < candidates.count {
                    // The account can't use this model right now -- move on to
                    // the next available one without burning a retry attempt.
                    modelIndex += 1
                    attempt -= 1
                    continue
                }
                if attempt >= maxAttempts || !isRetryable(error) {
                    lastPingDate = Date()
                    status = .failure
                    lastError = error.localizedDescription
                    stats.addRecord(success: false, summary: error.localizedDescription)
                    notifyFailureIfNeeded(message: error.localizedDescription)
                    rescheduleTimer()
                    finished = true
                } else {
                    let backoffSeconds = pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                }
            } catch {
                lastPingDate = Date()
                status = .failure
                lastError = error.localizedDescription
                stats.addRecord(success: false, summary: error.localizedDescription)
                notifyFailureIfNeeded(message: error.localizedDescription)
                rescheduleTimer()
                finished = true
            }
        }

        isPinging = false
        return true
    }

    private func isRetryable(_ error: PingError) -> Bool {
        switch error {
        case .network:
            return true
        case .serverError(let code, _):
            return code >= 500
        default:
            return false
        }
    }

    /// Try the user's selected model first, then detected and known fallbacks
    /// from lightest to heaviest if Claude rejects that model.
    private func modelCandidates(selectedModel: String) -> [String] {
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPool = (availableModels + UsageChecker.fallbackModels)
            .sorted { modelRank($0) < modelRank($1) }
        var candidates = selected.isEmpty ? [] : [selected]
        for model in fallbackPool where !candidates.contains(model) {
            candidates.append(model)
        }
        return candidates
    }

    private func modelRank(_ slug: String) -> Int {
        if slug.contains("haiku") { return 0 }
        if slug.contains("sonnet") { return 1 }
        if slug.contains("opus") { return 2 }
        return 3
    }

    /// True when the server rejected the request in a way that points at the
    /// model slug itself (unknown/retired/unavailable model), so trying the
    /// next candidate makes sense.
    private func isModelUnavailable(_ error: PingError) -> Bool {
        if case .serverError(let code, let body) = error {
            return (400...499).contains(code) && body.lowercased().contains("model")
        }
        return false
    }

    private let updateTimer = TrackerInvalidatingTimer()

    /// Checks once shortly after launch, then once a day after that.
    /// Any failure (no network, no feed configured yet, bad response) is
    /// stored in `updateCheckError` and otherwise ignored -- this never
    /// interrupts pinging or shows an alert.
    private func scheduleUpdateChecks() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.checkForUpdates()
        }
        updateTimer.timer?.invalidate()
        updateTimer.timer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
    }

    private let usageTimer = TrackerInvalidatingTimer()

    /// Fetches usage shortly after launch, then every 5 minutes, mirroring how
    /// ClaudeUsageBar keeps its numbers fresh. Failures only set `usageError`
    /// and never interrupt pinging.
    private func scheduleUsageRefreshes() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.refreshUsage()
        }
        usageTimer.timer?.invalidate()
        usageTimer.timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refreshUsage() }
        }
    }

    /// Used when the popover opens: refresh only if the data is older than a
    /// minute so opening the popover shows fresh numbers without hammering
    /// the API on every click.
    func refreshUsageIfStale() async {
        if let fetched = usage?.fetchedAt, Date().timeIntervalSince(fetched) < 60 { return }
        await refreshUsage()
    }

    func refreshUsage() async {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        let credential = settings.sessionKey
        let organization = settings.organizationID
        async let statusCheck = UsageChecker.fetchServiceStatus()
        do {
            let previousUsage = usage
            let fetched = try await UsageChecker.fetchUsage(
                sessionKey: settings.sessionKey,
                organizationID: settings.organizationID,
                cookieHeader: settings.effectiveCookieHeader
            )
            guard credential == settings.sessionKey, organization == settings.organizationID else { return }
            usage = fetched
            usageError = nil
            weeklyHistory.record(trackID: "claude-weekly", percent: fetched.weeklyPercent, reset: fetched.weeklyResetsAt)
            notifyUsageThresholdsIfNeeded(for: fetched)
            handleSessionAvailability(previous: previousUsage, current: fetched)
        } catch {
            guard credential == settings.sessionKey, organization == settings.organizationID else { return }
            usageError = (error as? UsageError)?.localizedDescription ?? error.localizedDescription
        }
        if let status = await statusCheck {
            notifyServiceChangeIfNeeded(newStatus: status)
            serviceStatus = status
        }
        let models = await UsageChecker.fetchAvailableModels(
            sessionKey: settings.sessionKey,
            organizationID: settings.organizationID,
            cookieHeader: settings.effectiveCookieHeader
        )
        if !models.isEmpty {
            availableModels = models.sorted { modelRank($0) < modelRank($1) }
        }
    }

    func clearAccountData() {
        usage = nil
        usageError = nil
        availableModels = []
        sessionAlerts = TrackerUsageAlertState()
        weeklyAlerts = TrackerUsageAlertState()
        sessionAvailability = TrackerSessionAvailabilityState()
    }

    func clearWeeklyHistory() {
        objectWillChange.send()
        weeklyHistory.clear()
    }

    // MARK: - Usage threshold & service status notifications

    private var sessionAvailability = TrackerSessionAvailabilityState()

    private func handleSessionAvailability(previous: ClaudeUsage?, current: ClaudeUsage) {
        if sessionAvailability.observe(percent: current.sessionPercent, reset: current.sessionResetsAt) {
            if settings.notifySessionAvailable {
                sendNotification(
                    identifier: "session-available",
                    title: "A new Claude session is available",
                    body: "Your previous 5-hour window reset."
                )
            }
        }

        startAvailableSessionIfNeeded()
    }

    /// Starts immediately whenever Claude currently accepts session traffic,
    /// except during the five hours before the next configured start. A
    /// successful manual or automatic ping also suppresses duplicates for
    /// five hours, including across app relaunches through Activity history.
    func startAvailableSessionIfNeeded(now: Date = Date()) {
        guard settings.autoStartAvailableSessions,
              !isPinging,
              !autoStartAttemptPending else { return }

        guard let usage, now.timeIntervalSince(usage.fetchedAt) < 30 else {
            Task { [weak self] in await self?.refreshUsage() }
            return
        }
        guard let sessionPercent = usage.sessionPercent, sessionPercent < 100 else { return }

        if settings.scheduledPingsEnabled,
           let nextScheduled = scheduler.nextFireDate(after: now, slots: settings.scheduleSlots),
           nextScheduled.timeIntervalSince(now) <= scheduledStartProtectionWindow {
            return
        }

        let latestSuccessfulPing = stats.records.last(where: { $0.success })?.date
        let mostRecentStart = [lastPingDate, latestSuccessfulPing].compactMap { $0 }.max()
        if let mostRecentStart,
           now.timeIntervalSince(mostRecentStart) < scheduledStartProtectionWindow {
            return
        }

        autoStartAttemptPending = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.runPing(manual: false)
            self.autoStartAttemptPending = false
        }
    }

    private var sessionAlerts = TrackerUsageAlertState()
    private var weeklyAlerts = TrackerUsageAlertState()
    private var serviceAlerts = TrackerServiceAlertState()

    /// Fires each user-selected usage threshold at most once per window.
    /// Guards against the two big false-alert sources: relaunching the app
    /// (the first fetch baselines silently) and server-side jitter in the
    /// reset timestamps (small shifts don't count as a new window).
    private func notifyUsageThresholdsIfNeeded(for fetched: ClaudeUsage) {
        let crossedSession = sessionAlerts.observe(percent: fetched.sessionPercent, reset: fetched.sessionResetsAt,
            enabled: !settings.sessionUsageThresholds.isEmpty, thresholds: settings.sessionUsageThresholds)
        let crossedWeekly = weeklyAlerts.observe(percent: fetched.weeklyPercent, reset: fetched.weeklyResetsAt,
            enabled: !settings.weeklyUsageThresholds.isEmpty, thresholds: settings.weeklyUsageThresholds)

        if let percent = fetched.sessionPercent {
            for case .threshold(let threshold) in crossedSession {
                let reset = fetched.sessionResetsAt.map { " Resets at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
                sendNotification(
                    identifier: "usage-session-\(threshold)",
                    title: "Session usage reached \(threshold)%",
                    body: "Your 5-hour session window is at \(percent)%.\(reset)"
                )
            }
        }
        if let percent = fetched.weeklyPercent {
            for case .threshold(let threshold) in crossedWeekly {
                let reset = fetched.weeklyResetsAt.map { " Resets \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                sendNotification(
                    identifier: "usage-weekly-\(threshold)",
                    title: "Weekly usage reached \(threshold)%",
                    body: "Your 7-day window is at \(percent)%.\(reset)"
                )
            }
        }
    }

    /// Notifies when Claude services go down, degrade, or recover -- once
    /// per level transition, gated by the user's notification toggles.
    private func notifyServiceChangeIfNeeded(newStatus: ClaudeServiceStatus) {
        let level: TrackerServiceAlertState.Level
        switch newStatus.level {
        case .outage: level = .outage
        case .degraded: level = .degraded
        case .operational: level = .operational
        }
        guard serviceAlerts.observe(level, outages: settings.notifyOnServiceOutage, degraded: settings.notifyOnServiceDegraded) else { return }
        switch newStatus.level {
        case .outage:
            guard settings.notifyOnServiceOutage else { return }
            sendNotification(
                identifier: "service-outage",
                title: "Claude services are down",
                body: newStatus.message
            )
        case .degraded:
            guard settings.notifyOnServiceDegraded else { return }
            sendNotification(
                identifier: "service-degraded",
                title: "Claude services are performing poorly",
                body: newStatus.message
            )
        case .operational:
            // Recovery matters to anyone who saw either alert above.
            guard settings.notifyOnServiceOutage || settings.notifyOnServiceDegraded else { return }
            sendNotification(
                identifier: "service-recovered",
                title: "Claude services recovered",
                body: "All Claude services are operational again."
            )
        }
    }

    /// Versions the auto-updater has already tried to install this run.
    private var autoUpdateAttemptedVersions: Set<String> = []

    func checkForUpdates() async {
        guard updatesEnabled else { return }
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateCheckError = nil
        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let result = await UpdateChecker.check(currentVersion: currentVersion)
        switch result {
        case .upToDate:
            availableUpdate = nil
        case .updateAvailable(let info):
            availableUpdate = info
            // Auto-update: install the new release as soon as it's seen, but
            // only try each version once so a failing install can't loop.
            if settings.autoUpdateEnabled && !autoUpdateAttemptedVersions.contains(info.version) {
                autoUpdateAttemptedVersions.insert(info.version)
                installUpdate()
            }
        case .failed(let message):
            availableUpdate = nil
            updateCheckError = message
        }
        isCheckingForUpdates = false
    }

    /// Downloads the available update's app bundle, swaps it in for this
    /// running app, and relaunches it. On success this method never visibly
    /// returns -- `Updater` terminates the app partway through the install.
    func installUpdate() {
        guard let update = availableUpdate, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        installUpdateError = nil
        Task {
            do {
                try await Updater.downloadAndInstall(update)
            } catch {
                self.isInstallingUpdate = false
                self.installUpdateError = (error as? UpdaterError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    /// Sends a test notification so delivery can be verified from Settings.
    /// Requests permission on the spot if it was never granted, and reports
    /// exactly why nothing appeared otherwise.
    func sendTestNotification() {
        notificationTestStatus = nil
        Task { [weak self] in
            self?.notificationTestStatus = await TrackerNotifications.shared.sendTest(provider: .claude)
        }
    }

    private func requestNotificationPermission() {
        TrackerNotifications.shared.requestPermission()
    }

    private func notifyFailureIfNeeded(message: String) {
        guard settings.notifyOnFailure else { return }
        // Stable identifier: repeated failures replace the previous alert
        // instead of stacking a pile of duplicates.
        sendNotification(identifier: "ping-failure", title: "Session ping failed", body: message)
    }

    /// Shared local-notification helper. Stable identifiers let the system
    /// coalesce repeats of the same alert instead of stacking duplicates.
    private func sendNotification(identifier: String, title: String, body: String) {
        TrackerNotifications.shared.send(provider: .claude, event: identifier, title: title, body: body)
    }
}

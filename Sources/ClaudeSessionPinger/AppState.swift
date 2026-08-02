import Foundation
import AppKit
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
    private var automaticWakePingTask: Task<Void, Never>?
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
        updateTimer?.invalidate()
        usageTimer?.invalidate()
        automaticWakePingTask?.cancel()
    }

    func rescheduleTimer() {
        scheduler.schedule(slots: settings.scheduleSlots)
        nextFireDate = scheduler.nextFireDate(slots: settings.scheduleSlots)
        synchronizeWakeSchedule()
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
        automaticWakePingTask?.cancel()
        pendingAutomaticWakePing = date
        pendingAutomaticWakeIsTest = isWakeTest
        let delay = max(0, date.timeIntervalSinceNow)
        automaticWakePingTask = Task { [weak self] in
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
            automaticWakePingTask = nil
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
        let enabled = settings.enableScheduledWake
        let slots = settings.scheduleSlots
        if !enabled {
            automaticWakePingTask?.cancel()
            automaticWakePingTask = nil
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

    @discardableResult
    private func runPing(manual: Bool) async -> Bool {
        guard !isPinging else { return false }
        if let last = lastPingDate, !manual, Date().timeIntervalSince(last) < minimumGap {
            return false
        }
        guard settings.isConfigured else {
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
        let candidates = modelCandidates()
        var modelIndex = 0

        while attempt < maxAttempts && !finished {
            attempt += 1
            let modelToUse = candidates[min(modelIndex, candidates.count - 1)]
            do {
                let outcome = try await ClaudeClient.sendPing(
                    sessionKey: settings.sessionKey,
                    organizationID: settings.organizationID,
                    model: modelToUse,
                    message: settings.message,
                    conversationID: settings.conversationID,
                    cookieHeader: settings.effectiveCookieHeader
                )
                settings.conversationID = outcome.conversationID
                activeModel = modelToUse
                lastPingDate = Date()
                status = outcome.matchedExpected ? .success : .failure
                let summary = outcome.matchedExpected ? "Got reply" : "Claude returned an empty reply"
                stats.addRecord(success: outcome.matchedExpected, summary: summary)
                if outcome.matchedExpected && settings.notifySessionStarted {
                    sendNotification(
                        identifier: "session-started",
                        title: "New Claude session started",
                        body: manual
                            ? "Your manual ping started a new session."
                            : "Session Pinger started a new session."
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
    private func modelCandidates() -> [String] {
        let selected = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var updateTimer: Timer?

    /// Checks once shortly after launch, then once a day after that.
    /// Any failure (no network, no feed configured yet, bad response) is
    /// stored in `updateCheckError` and otherwise ignored -- this never
    /// interrupts pinging or shows an alert.
    private func scheduleUpdateChecks() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.checkForUpdates()
        }
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
    }

    private var usageTimer: Timer?

    /// Fetches usage shortly after launch, then every 5 minutes, mirroring how
    /// ClaudeUsageBar keeps its numbers fresh. Failures only set `usageError`
    /// and never interrupt pinging.
    private func scheduleUsageRefreshes() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.refreshUsage()
        }
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
        async let statusCheck = UsageChecker.fetchServiceStatus()
        do {
            let previousUsage = usage
            let fetched = try await UsageChecker.fetchUsage(
                sessionKey: settings.sessionKey,
                organizationID: settings.organizationID,
                cookieHeader: settings.effectiveCookieHeader
            )
            usage = fetched
            usageError = nil
            notifyUsageThresholdsIfNeeded(for: fetched)
            handleSessionAvailability(previous: previousUsage, current: fetched)
        } catch {
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
        isRefreshingUsage = false
    }

    // MARK: - Usage threshold & service status notifications

    private var sessionAvailabilityBaselined = false

    private func handleSessionAvailability(previous: ClaudeUsage?, current: ClaudeUsage) {
        let wasBaselined = sessionAvailabilityBaselined
        defer { sessionAvailabilityBaselined = true }

        let becameAvailable = wasBaselined
            && (previous?.sessionPercent ?? 0) >= 100
            && (current.sessionPercent ?? 100) < 100
        let resetRolledForward: Bool
        if wasBaselined,
           let oldReset = previous?.sessionResetsAt,
           let newReset = current.sessionResetsAt {
            resetRolledForward = oldReset <= Date()
                && newReset.timeIntervalSince(oldReset) > resetJitterTolerance
        } else {
            resetRolledForward = false
        }

        if becameAvailable || resetRolledForward {
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

        if let nextScheduled = scheduler.nextFireDate(after: now, slots: settings.scheduleSlots),
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

    /// Thresholds already notified for the current session window.
    private var notifiedSessionThresholds: Set<Int> = []
    /// Thresholds already notified for the current weekly window.
    private var notifiedWeeklyThresholds: Set<Int> = []
    /// Reset timestamps last seen -- when these move by more than the jitter
    /// tolerance, a new window has started and thresholds may fire again.
    private var lastSessionResetsAt: Date?
    private var lastWeeklyResetsAt: Date?
    /// False until the first successful usage fetch of this run. That first
    /// fetch only records which thresholds are already crossed -- it never
    /// alerts, so relaunching the app can't re-alert limits hit earlier.
    private var usageBaselined = false
    /// The server recomputes reset timestamps on every poll, so two reads of
    /// the same window can differ by a few seconds. Only a shift bigger than
    /// this counts as a genuinely new window.
    private let resetJitterTolerance: TimeInterval = 120

    private func isNewWindow(_ new: Date, comparedTo old: Date?) -> Bool {
        guard let old else { return true }
        return abs(new.timeIntervalSince(old)) > resetJitterTolerance
    }
    /// nil until the first status check completes, so launching during an
    /// outage never fires a spurious outage/degraded/recovery notification.
    private var lastKnownServiceLevel: ClaudeServiceStatus.Level?

    /// Fires each user-selected usage threshold at most once per window.
    /// Guards against the two big false-alert sources: relaunching the app
    /// (the first fetch baselines silently) and server-side jitter in the
    /// reset timestamps (small shifts don't count as a new window).
    private func notifyUsageThresholdsIfNeeded(for fetched: ClaudeUsage) {
        if let sessionResets = fetched.sessionResetsAt {
            if isNewWindow(sessionResets, comparedTo: lastSessionResetsAt) {
                notifiedSessionThresholds.removeAll()
            }
            lastSessionResetsAt = sessionResets
        }
        if let weeklyResets = fetched.weeklyResetsAt {
            if isNewWindow(weeklyResets, comparedTo: lastWeeklyResetsAt) {
                notifiedWeeklyThresholds.removeAll()
            }
            lastWeeklyResetsAt = weeklyResets
        }

        // Self-healing: usage only rises within a window, so a percent now
        // sitting well below an already-notified threshold means the window
        // really did reset even if the timestamps never showed it.
        if let percent = fetched.sessionPercent {
            notifiedSessionThresholds = notifiedSessionThresholds.filter { $0 <= percent + 10 }
        }
        if let percent = fetched.weeklyPercent {
            notifiedWeeklyThresholds = notifiedWeeklyThresholds.filter { $0 <= percent + 10 }
        }

        let crossedSession = settings.sessionUsageThresholds.sorted().filter { threshold in
            (fetched.sessionPercent ?? 0) >= threshold && !notifiedSessionThresholds.contains(threshold)
        }
        let crossedWeekly = settings.weeklyUsageThresholds.sorted().filter { threshold in
            (fetched.weeklyPercent ?? 0) >= threshold && !notifiedWeeklyThresholds.contains(threshold)
        }
        notifiedSessionThresholds.formUnion(crossedSession)
        notifiedWeeklyThresholds.formUnion(crossedWeekly)

        // First successful fetch after launch: record what's already crossed
        // without alerting -- those limits were hit before this run.
        if !usageBaselined {
            usageBaselined = true
            return
        }

        if let percent = fetched.sessionPercent {
            for threshold in crossedSession {
                let reset = fetched.sessionResetsAt.map { " Resets at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
                sendNotification(
                    identifier: "usage-session-\(threshold)",
                    title: "Session usage reached \(threshold)%",
                    body: "Your 5-hour session window is at \(percent)%.\(reset)"
                )
            }
        }
        if let percent = fetched.weeklyPercent {
            for threshold in crossedWeekly {
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
        defer { lastKnownServiceLevel = newStatus.level }
        guard let previous = lastKnownServiceLevel, previous != newStatus.level else { return }
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
        guard runningInsideProperAppBundle else {
            notificationTestStatus = "Run the installed app bundle to test notifications."
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notificationSettings in
            let status = notificationSettings.authorizationStatus
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .denied:
                    self.notificationTestStatus = "Notifications are turned off for Session Pinger. Turn them on in System Settings > Notifications > Session Pinger, then test again."
                case .notDetermined:
                    do {
                        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        if granted {
                            self.deliverTestNotification()
                        } else {
                            self.notificationTestStatus = "Permission wasn't granted, so macOS won't show notifications."
                        }
                    } catch {
                        self.notificationTestStatus = "macOS couldn't request notification permission: \(error.localizedDescription)"
                    }
                default:
                    self.deliverTestNotification()
                }
            }
        }
    }

    /// Sends the actual test alert and reports delivery errors instead of
    /// failing silently.
    private func deliverTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test notification"
        content.body = "Notifications are working."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "test-notification", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.notificationTestStatus = "macOS rejected the notification: \(error.localizedDescription)"
                } else {
                    self.notificationTestStatus = "Test notification sent -- check the top-right of your screen."
                }
            }
        }
    }

    private var runningInsideProperAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") != nil
    }

    private func requestNotificationPermission() {
        guard runningInsideProperAppBundle else {
            return
        }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
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
        guard runningInsideProperAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

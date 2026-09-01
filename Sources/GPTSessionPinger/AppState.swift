import AppKit
import Foundation
import TrackerDesignSystem
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    @Published var availableUpdate: UpdateInfo?
    @Published var isCheckingForUpdates = false
    @Published var updateCheckError: String?
    @Published var isInstallingUpdate = false
    @Published var installUpdateError: String?
    @Published var usage: GPTUsage?
    @Published var usageError: String?
    @Published var isRefreshingUsage = false
    @Published var serviceStatus: GPTServiceStatus?
    @Published var notificationTestStatus: String?
    @Published var pingStatus: String?
    @Published var isPinging = false

    let settings: SettingsStore
    let history: UsageHistoryStore
    var requestClosePopover: (() -> Void)?
    var requestTogglePopover: (() -> Void)?
    var requestTogglePopoverFromShortcut: (() -> Void)?
    var completePopoverShortcutPress: (() -> Void)?
    var requestShowSettings: (() -> Void)?
    var closeSettingsWindow: (() -> Void)?
    var toggleSettingsWindow: (() -> Void)?
    var requestSaveAndCloseSettings: (() -> Void)?

    private let updateTimer = TrackerInvalidatingTimer()
    private let usageTimer = TrackerInvalidatingTimer()
    private var usageAlerts: [String: TrackerUsageAlertState] = [:]
    private var serviceAlerts = TrackerServiceAlertState()
    private var autoUpdateAttemptedVersions: Set<String> = []
    private let updatesEnabled: Bool

    init(settings: SettingsStore, history: UsageHistoryStore, updatesEnabled: Bool = true) {
        self.settings = settings
        self.history = history
        self.updatesEnabled = updatesEnabled
        if updatesEnabled { scheduleUpdateChecks() }
        scheduleUsageRefreshes()
        requestNotificationPermission()
    }

    private func scheduleUsageRefreshes() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.refreshUsage()
        }
        usageTimer.timer?.invalidate()
        usageTimer.timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refreshUsage() }
        }
    }

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
            let fetched = try await UsageChecker.fetchUsage(
                sessionKey: settings.sessionKey,
                organizationID: settings.organizationID,
                cookieHeader: settings.effectiveCookieHeader
            )
            guard credential == settings.sessionKey, organization == settings.organizationID else { return }
            usage = fetched
            usageError = Self.partialUsageMessage(for: fetched.sourceWarnings)
            if let plan = fetched.planType, !plan.isEmpty {
                settings.accountPlanType = plan
            }
            settings.registerUsageTracks(fetched.tracks)
            history.record(fetched)
            notifyUsageThresholdsIfNeeded(for: fetched)
        } catch {
            guard credential == settings.sessionKey, organization == settings.organizationID else { return }
            usageError = (error as? UsageError)?.localizedDescription ?? error.localizedDescription
        }

        if let status = await statusCheck {
            notifyServiceChangeIfNeeded(newStatus: status)
            serviceStatus = status
        }
        await refreshModelCatalog()
    }

    private func refreshModelCatalog() async {
        guard settings.isConfigured,
              let auth = try? await ChatGPTWebSession.resolve(
                savedCredential: settings.sessionKey,
                accountID: settings.organizationID,
                cookieHeader: settings.effectiveCookieHeader
              ),
              let models = try? await ChatGPTModelCatalog.fetch(
                auth: auth,
                cookieHeader: settings.effectiveCookieHeader
              ),
              !models.isEmpty else { return }
        settings.registerAvailablePingModels(models)
    }

    func clearAccountData() {
        usage = nil
        usageError = nil
        usageAlerts.removeAll()
        pingStatus = nil
    }

    nonisolated static func partialUsageMessage(for warnings: [String]) -> String? {
        guard !warnings.isEmpty else { return nil }
        return "Some usage sources could not be refreshed. " + warnings.joined(separator: " ")
    }

    func pingChatGPT(model: String? = nil, effort: String? = nil, message: String? = nil) {
        Task { [weak self] in
            _ = await self?.sendChatGPTPing(model: model, effort: effort, message: message)
        }
    }

    func sendChatGPTPing(model: String? = nil, effort: String? = nil, message: String? = nil) async -> ChatGPTPingOutcome? {
        guard !isPinging else { return nil }
        isPinging = true
        let wakeActivity = TrackerWakeActivity.shared.begin()
        defer { TrackerWakeActivity.shared.end(wakeActivity) }
        pingStatus = nil
        defer { isPinging = false }
        let requestedModel = model ?? settings.pingModel
        let requestedEffort = effort ?? settings.pingReasoningEffort
        do {
            let auth = try await ChatGPTWebSession.resolve(savedCredential: settings.sessionKey,
                accountID: settings.organizationID, cookieHeader: settings.effectiveCookieHeader)
            let outcome = try await ChatGPTClient.sendPing(
                auth: auth, cookieHeader: settings.effectiveCookieHeader,
                model: requestedModel, modelTitle: settings.pingModelTitle(for: requestedModel),
                mode: .chat, reasoningEffort: requestedEffort, message: message ?? settings.pingMessage,
                conversationID: settings.pingConversationID, parentMessageID: settings.pingParentMessageID
            )
            settings.pingConversationID = outcome.conversationID
            settings.pingParentMessageID = outcome.parentMessageID
            let confirmation = CodexSessionPinger.modelConfirmationText(requestedModel: requestedModel,
                requestedEffort: requestedEffort, confirmedModel: outcome.confirmedModel,
                confirmedEffort: outcome.confirmedReasoningEffort)
            pingStatus = "Ping sent · \(confirmation)"
            return outcome
        } catch {
            pingStatus = (error as? ChatGPTPingError)?.localizedDescription ?? error.localizedDescription
            return nil
        }
    }

    private func notifyUsageThresholdsIfNeeded(for fetched: GPTUsage) {
        var newlyCrossed: [(GPTUsageTrack, Int)] = []
        var newlyUnavailable: [GPTUsageTrack] = []

        for track in fetched.tracks {
            let id = track.preferenceID
            let events = usageAlerts[id, default: TrackerUsageAlertState()].observe(
                percent: track.usedPercent, reset: track.resetsAt, remaining: track.remaining,
                blocked: track.isBlocked, enabled: settings.isAlertEnabled(for: id),
                thresholds: settings.alertThresholds(for: id)
            )
            for event in events {
                switch event {
                case .threshold(let value): newlyCrossed.append((track, value))
                case .exhausted: newlyUnavailable.append(track)
                }
            }
        }

        for (track, threshold) in newlyCrossed {
            let reset = track.resetsAt.map { " Resets \(Self.resetDescription($0))." } ?? ""
            sendNotification(
                identifier: "usage-\(track.preferenceID)-\(threshold)",
                title: "\(track.title) reached \(threshold)%",
                body: "Current usage is \(track.usedPercent ?? threshold)%.\(reset)",
                provider: (track.scope == .codex || track.scope == .workspace) ? .codex : .chatGPT
            )
        }
        for track in newlyUnavailable {
            let reset = track.resetsAt.map { " It resets \(Self.resetDescription($0))." } ?? ""
            sendNotification(
                identifier: "usage-unavailable-\(track.preferenceID)",
                title: "\(track.title) is unavailable",
                body: "The reported allowance has been exhausted.\(reset)",
                provider: (track.scope == .codex || track.scope == .workspace) ? .codex : .chatGPT
            )
        }
    }

    private static func resetDescription(_ date: Date) -> String {
        if date.timeIntervalSinceNow > 86_400 {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return "at " + date.formatted(date: .omitted, time: .shortened)
    }

    private func notifyServiceChangeIfNeeded(newStatus: GPTServiceStatus) {
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
            sendNotification(identifier: "service-outage", title: "OpenAI services are down", body: newStatus.message)
        case .degraded:
            guard settings.notifyOnServiceDegraded else { return }
            sendNotification(identifier: "service-degraded", title: "OpenAI services are degraded", body: newStatus.message)
        case .operational:
            guard settings.notifyOnServiceOutage || settings.notifyOnServiceDegraded else { return }
            sendNotification(identifier: "service-recovered", title: "OpenAI services recovered", body: "All OpenAI services are operational again.")
        }
    }

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

    func checkForUpdates() async {
        guard updatesEnabled else { return }
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateCheckError = nil
        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        switch await UpdateChecker.check(currentVersion: currentVersion) {
        case .upToDate:
            availableUpdate = nil
        case .updateAvailable(let info):
            availableUpdate = info
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

    func sendTestNotification(provider: TrackerNotificationProvider = .codex) {
        notificationTestStatus = nil
        Task { [weak self] in
            self?.notificationTestStatus = await TrackerNotifications.shared.sendTest(provider: provider)
        }
    }

    private func requestNotificationPermission() {
        TrackerNotifications.shared.requestPermission()
    }

    private func sendNotification(identifier: String, title: String, body: String, provider: TrackerNotificationProvider = .openAI) {
        TrackerNotifications.shared.send(provider: provider, event: identifier, title: title, body: body)
    }
}

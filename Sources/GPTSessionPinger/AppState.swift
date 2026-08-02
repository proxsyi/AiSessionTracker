import AppKit
import Foundation
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

    let settings: SettingsStore
    let history: UsageHistoryStore
    var requestClosePopover: (() -> Void)?
    var requestTogglePopover: (() -> Void)?
    var requestShowSettings: (() -> Void)?
    var closeSettingsWindow: (() -> Void)?
    var toggleSettingsWindow: (() -> Void)?
    var requestSaveAndCloseSettings: (() -> Void)?

    private var updateTimer: Timer?
    private var usageTimer: Timer?
    private var usageBaselined = false
    private var notifiedThresholds: [String: Set<Int>] = [:]
    private var notifiedUnavailableTracks: Set<String> = []
    private var lastResetDates: [String: Date] = [:]
    private let resetJitterTolerance: TimeInterval = 120
    private var lastKnownServiceLevel: GPTServiceStatus.Level?
    private var autoUpdateAttemptedVersions: Set<String> = []

    init(settings: SettingsStore, history: UsageHistoryStore) {
        self.settings = settings
        self.history = history
        scheduleUpdateChecks()
        scheduleUsageRefreshes()
        requestNotificationPermission()
    }

    deinit {
        updateTimer?.invalidate()
        usageTimer?.invalidate()
    }

    private func scheduleUsageRefreshes() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.refreshUsage()
        }
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
        async let statusCheck = UsageChecker.fetchServiceStatus()

        do {
            let fetched = try await UsageChecker.fetchUsage(
                sessionKey: settings.sessionKey,
                organizationID: settings.organizationID,
                cookieHeader: settings.effectiveCookieHeader
            )
            usage = fetched
            usageError = nil
            if let plan = fetched.planType, !plan.isEmpty {
                settings.accountPlanType = plan
            }
            settings.registerUsageTracks(fetched.tracks)
            history.record(fetched)
            notifyUsageThresholdsIfNeeded(for: fetched)
        } catch {
            usageError = (error as? UsageError)?.localizedDescription ?? error.localizedDescription
        }

        if let status = await statusCheck {
            notifyServiceChangeIfNeeded(newStatus: status)
            serviceStatus = status
        }
        isRefreshingUsage = false
    }

    func clearAccountData() {
        usage = nil
        usageError = nil
        usageBaselined = false
        notifiedThresholds.removeAll()
        notifiedUnavailableTracks.removeAll()
        lastResetDates.removeAll()
    }

    private func notifyUsageThresholdsIfNeeded(for fetched: GPTUsage) {
        var newlyCrossed: [(GPTUsageTrack, Int)] = []
        var newlyUnavailable: [GPTUsageTrack] = []

        for track in fetched.tracks {
            let id = track.preferenceID
            guard settings.isAlertEnabled(for: id) else { continue }

            if let reset = track.resetsAt {
                if let old = lastResetDates[id], abs(reset.timeIntervalSince(old)) > resetJitterTolerance {
                    notifiedThresholds[id] = []
                    notifiedUnavailableTracks.remove(id)
                }
                lastResetDates[id] = reset
            }

            if let percent = track.usedPercent {
                var alreadyNotified = notifiedThresholds[id] ?? []
                alreadyNotified = alreadyNotified.filter { $0 <= percent + 10 }
                let thresholds = id == "codex-weekly"
                    ? settings.weeklyUsageThresholds
                    : [settings.additionalUsageAlertThreshold]
                let crossed = thresholds.sorted().filter { percent >= $0 && !alreadyNotified.contains($0) }
                alreadyNotified.formUnion(crossed)
                notifiedThresholds[id] = alreadyNotified
                newlyCrossed.append(contentsOf: crossed.map { (track, $0) })
            } else if track.isBlocked || track.remaining == 0 {
                if !notifiedUnavailableTracks.contains(id) {
                    notifiedUnavailableTracks.insert(id)
                    newlyUnavailable.append(track)
                }
            } else {
                notifiedUnavailableTracks.remove(id)
            }
        }

        guard usageBaselined else {
            usageBaselined = true
            return
        }

        for (track, threshold) in newlyCrossed {
            let reset = track.resetsAt.map { " Resets \(Self.resetDescription($0))." } ?? ""
            sendNotification(
                identifier: "usage-\(track.preferenceID)-\(threshold)",
                title: "\(track.title) reached \(threshold)%",
                body: "Current usage is \(track.usedPercent ?? threshold)%.\(reset)"
            )
        }
        for track in newlyUnavailable {
            let reset = track.resetsAt.map { " It resets \(Self.resetDescription($0))." } ?? ""
            sendNotification(
                identifier: "usage-unavailable-\(track.preferenceID)",
                title: "\(track.title) is unavailable",
                body: "The reported allowance has been exhausted.\(reset)"
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
        defer { lastKnownServiceLevel = newStatus.level }
        guard let previous = lastKnownServiceLevel, previous != newStatus.level else { return }
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
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
    }

    func checkForUpdates() async {
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

    func sendTestNotification() {
        notificationTestStatus = nil
        guard runningInsideProperAppBundle else {
            notificationTestStatus = "Run the installed app bundle to test notifications."
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notificationSettings in
            Task { @MainActor in
                guard let self else { return }
                switch notificationSettings.authorizationStatus {
                case .denied:
                    self.notificationTestStatus = "Notifications are turned off for GPT Usage Tracker in System Settings."
                case .notDetermined:
                    do {
                        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        if granted { self.deliverTestNotification() }
                        else { self.notificationTestStatus = "Notification permission was not granted." }
                    } catch {
                        self.notificationTestStatus = "macOS could not request notification permission: \(error.localizedDescription)"
                    }
                default:
                    self.deliverTestNotification()
                }
            }
        }
    }

    private func deliverTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "GPT Usage Tracker"
        content.body = "Usage alerts are working."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "test-notification", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                self?.notificationTestStatus = error.map { "macOS rejected the notification: \($0.localizedDescription)" }
                    ?? "Test notification sent."
            }
        }
    }

    private var runningInsideProperAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") != nil
    }

    private func requestNotificationPermission() {
        guard runningInsideProperAppBundle else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func sendNotification(identifier: String, title: String, body: String) {
        guard runningInsideProperAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
            withCompletionHandler: nil
        )
    }
}

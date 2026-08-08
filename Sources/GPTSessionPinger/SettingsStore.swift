import Foundation

extension Notification.Name {
    static let commandIShortcutSettingChanged = Notification.Name("commandIShortcutSettingChanged")
}

final class SettingsStore: ObservableObject {
    /// Reuse the standalone GPT app's preference domain when this feature
    /// runs inside the combined tracker, without colliding with Claude settings.
    private static let serviceDefaults = UserDefaults(
        suiteName: "com.proxsyi.gptsessionpinger"
    )!

    static let availableThresholds = [25, 50, 75, 90, 95, 100]
    static let defaultWeeklyThresholds = [75, 90]

    private enum Keys {
        static let organizationID = "organizationID"
        static let accountPlanType = "accountPlanType"
        static let showCategoryTabs = "trackerShowCategoryTabs"
        static let showHistoryChart = "trackerShowHistoryChart"
        static let automaticallyShowNewUsageTracks = "trackerAutomaticallyShowNewUsageTracks"
        static let hiddenUsageTrackIDs = "trackerHiddenUsageTrackIDs"
        static let knownUsageTrackIDs = "trackerKnownUsageTrackIDs"
        static let alertEnabledUsageTrackIDs = "trackerAlertEnabledUsageTrackIDs"
        static let weeklyUsageThresholds = "weeklyUsageThresholds"
        static let additionalUsageAlertThreshold = "trackerAdditionalUsageAlertThreshold"
        static let enableCommandIShortcut = "enableCommandIShortcut"
        static let preferClearGlass = "preferClearGlass"
        static let launchAtLogin = "launchAtLogin"
        static let notifyOnServiceOutage = "notifyOnServiceOutage"
        static let notifyOnServiceDegraded = "notifyOnServiceDegraded"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let keychainOwnershipMigrationVersion = "keychainOwnershipMigrationVersion"
        static let trackerMigrationVersion = "trackerMigrationVersion"
    }

    private static let currentKeychainOwnershipMigrationVersion = 2
    private static let currentTrackerMigrationVersion = 1

    @Published var organizationID: String {
        didSet { Self.serviceDefaults.set(organizationID, forKey: Keys.organizationID) }
    }
    @Published var accountPlanType: String {
        didSet { Self.serviceDefaults.set(accountPlanType, forKey: Keys.accountPlanType) }
    }
    @Published var showCategoryTabs: Bool {
        didSet { Self.serviceDefaults.set(showCategoryTabs, forKey: Keys.showCategoryTabs) }
    }
    @Published var showHistoryChart: Bool {
        didSet { Self.serviceDefaults.set(showHistoryChart, forKey: Keys.showHistoryChart) }
    }
    @Published var automaticallyShowNewUsageTracks: Bool {
        didSet { Self.serviceDefaults.set(automaticallyShowNewUsageTracks, forKey: Keys.automaticallyShowNewUsageTracks) }
    }
    @Published private(set) var hiddenUsageTrackIDs: Set<String> {
        didSet { Self.save(hiddenUsageTrackIDs, key: Keys.hiddenUsageTrackIDs) }
    }
    @Published private(set) var knownUsageTrackIDs: Set<String> {
        didSet { Self.save(knownUsageTrackIDs, key: Keys.knownUsageTrackIDs) }
    }
    @Published private(set) var alertEnabledUsageTrackIDs: Set<String> {
        didSet { Self.save(alertEnabledUsageTrackIDs, key: Keys.alertEnabledUsageTrackIDs) }
    }
    @Published var weeklyUsageThresholds: [Int] {
        didSet { Self.saveInts(weeklyUsageThresholds, key: Keys.weeklyUsageThresholds) }
    }
    @Published var additionalUsageAlertThreshold: Int {
        didSet { Self.serviceDefaults.set(additionalUsageAlertThreshold, forKey: Keys.additionalUsageAlertThreshold) }
    }
    @Published var enableCommandIShortcut: Bool {
        didSet {
            Self.serviceDefaults.set(enableCommandIShortcut, forKey: Keys.enableCommandIShortcut)
            NotificationCenter.default.post(name: .commandIShortcutSettingChanged, object: nil)
        }
    }
    @Published var preferClearGlass: Bool {
        didSet { Self.serviceDefaults.set(preferClearGlass, forKey: Keys.preferClearGlass) }
    }
    @Published var launchAtLogin: Bool {
        didSet { Self.serviceDefaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    @Published var notifyOnServiceOutage: Bool {
        didSet { Self.serviceDefaults.set(notifyOnServiceOutage, forKey: Keys.notifyOnServiceOutage) }
    }
    @Published var notifyOnServiceDegraded: Bool {
        didSet { Self.serviceDefaults.set(notifyOnServiceDegraded, forKey: Keys.notifyOnServiceDegraded) }
    }
    @Published var autoUpdateEnabled: Bool {
        didSet { Self.serviceDefaults.set(autoUpdateEnabled, forKey: Keys.autoUpdateEnabled) }
    }
    @Published var sessionKey: String {
        didSet {
            if sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                KeychainStore.delete()
            } else {
                try? KeychainStore.save(sessionKey)
            }
        }
    }
    @Published var cookieHeader: String {
        didSet {
            if cookieHeader.isEmpty {
                KeychainStore.delete(account: "cookieHeader")
            } else {
                try? KeychainStore.save(cookieHeader, account: "cookieHeader")
            }
        }
    }

    init() {
        let defaults = Self.serviceDefaults
        organizationID = defaults.string(forKey: Keys.organizationID) ?? ""
        let storedSessionKey = KeychainStore.load() ?? ""
        let storedCookieHeader = KeychainStore.load(account: "cookieHeader") ?? ""
        sessionKey = storedSessionKey
        cookieHeader = storedCookieHeader
        accountPlanType = defaults.string(forKey: Keys.accountPlanType) ?? ChatGPTWebSession.planType(from: storedSessionKey) ?? ""
        showCategoryTabs = defaults.object(forKey: Keys.showCategoryTabs) == nil ? true : defaults.bool(forKey: Keys.showCategoryTabs)
        showHistoryChart = defaults.object(forKey: Keys.showHistoryChart) == nil ? true : defaults.bool(forKey: Keys.showHistoryChart)
        automaticallyShowNewUsageTracks = defaults.object(forKey: Keys.automaticallyShowNewUsageTracks) == nil ? true : defaults.bool(forKey: Keys.automaticallyShowNewUsageTracks)
        hiddenUsageTrackIDs = Self.loadSet(key: Keys.hiddenUsageTrackIDs)
        knownUsageTrackIDs = Self.loadSet(key: Keys.knownUsageTrackIDs)
        let storedAlertIDs = Self.loadSet(key: Keys.alertEnabledUsageTrackIDs)
        alertEnabledUsageTrackIDs = defaults.object(forKey: Keys.alertEnabledUsageTrackIDs) == nil ? ["codex-weekly"] : storedAlertIDs
        let storedWeekly = Self.loadInts(key: Keys.weeklyUsageThresholds)
        weeklyUsageThresholds = storedWeekly.isEmpty ? Self.defaultWeeklyThresholds : storedWeekly
        let storedAdditionalThreshold = defaults.integer(forKey: Keys.additionalUsageAlertThreshold)
        additionalUsageAlertThreshold = Self.availableThresholds.contains(storedAdditionalThreshold) ? storedAdditionalThreshold : 90
        enableCommandIShortcut = defaults.object(forKey: Keys.enableCommandIShortcut) == nil ? true : defaults.bool(forKey: Keys.enableCommandIShortcut)
        preferClearGlass = defaults.object(forKey: Keys.preferClearGlass) == nil ? true : defaults.bool(forKey: Keys.preferClearGlass)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        notifyOnServiceOutage = defaults.object(forKey: Keys.notifyOnServiceOutage) == nil ? true : defaults.bool(forKey: Keys.notifyOnServiceOutage)
        notifyOnServiceDegraded = defaults.object(forKey: Keys.notifyOnServiceDegraded) == nil ? true : defaults.bool(forKey: Keys.notifyOnServiceDegraded)
        autoUpdateEnabled = defaults.object(forKey: Keys.autoUpdateEnabled) == nil ? true : defaults.bool(forKey: Keys.autoUpdateEnabled)

        migrateKeychainOwnershipIfNeeded(defaults: defaults, storedSessionKey: storedSessionKey, storedCookieHeader: storedCookieHeader)
        removeLegacySessionPreferencesIfNeeded(defaults: defaults)
    }

    var isConfigured: Bool {
        !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var effectiveCookieHeader: String { cookieHeader }

    var maskedSessionKey: String {
        guard sessionKey.count > 4 else { return sessionKey.isEmpty ? "" : "••••" }
        return "••••••••" + sessionKey.suffix(4)
    }

    func isUsageTrackVisible(_ id: String) -> Bool {
        if id.hasPrefix("model-") && hiddenUsageTrackIDs.contains("chatgpt-model-limits") {
            return false
        }
        return !hiddenUsageTrackIDs.contains(id)
    }

    func setUsageTrackVisible(_ id: String, isVisible: Bool) {
        knownUsageTrackIDs.insert(id)
        if isVisible {
            hiddenUsageTrackIDs.remove(id)
        } else {
            hiddenUsageTrackIDs.insert(id)
        }
    }

    func registerUsageTracks(_ tracks: [GPTUsageTrack]) {
        for id in Set(tracks.map(\.preferenceID)) where !knownUsageTrackIDs.contains(id) {
            knownUsageTrackIDs.insert(id)
            if !automaticallyShowNewUsageTracks {
                hiddenUsageTrackIDs.insert(id)
            }
        }
    }

    func isAlertEnabled(for id: String) -> Bool {
        alertEnabledUsageTrackIDs.contains(id)
    }

    func setAlertEnabled(_ enabled: Bool, for id: String) {
        if enabled {
            alertEnabledUsageTrackIDs.insert(id)
        } else {
            alertEnabledUsageTrackIDs.remove(id)
        }
    }

    func clearChatGPTLogin() {
        sessionKey = ""
        cookieHeader = ""
        organizationID = ""
        accountPlanType = ""
    }

    private func migrateKeychainOwnershipIfNeeded(defaults: UserDefaults, storedSessionKey: String, storedCookieHeader: String) {
        guard defaults.integer(forKey: Keys.keychainOwnershipMigrationVersion) < Self.currentKeychainOwnershipMigrationVersion,
              !storedSessionKey.isEmpty else { return }
        try? KeychainStore.save(storedSessionKey)
        if !storedCookieHeader.isEmpty {
            try? KeychainStore.save(storedCookieHeader, account: "cookieHeader")
        }
        defaults.set(Self.currentKeychainOwnershipMigrationVersion, forKey: Keys.keychainOwnershipMigrationVersion)
    }

    private func removeLegacySessionPreferencesIfNeeded(defaults: UserDefaults) {
        guard defaults.integer(forKey: Keys.trackerMigrationVersion) < Self.currentTrackerMigrationVersion else { return }
        [
            "model", "message", "conversationID", "showSessionBar", "showWeeklyBar", "showFable5Bar",
            "notifySessionAvailable", "notifySessionStarted", "autoStartAvailableSessions",
            "showNextPossibleCountdown", "showScheduledCountdown", "countdownFocus", "enableScheduledWake",
            "scheduleSlots", "notifyOnFailure", "sessionUsageThresholds"
        ].forEach(defaults.removeObject(forKey:))
        defaults.set(Self.currentTrackerMigrationVersion, forKey: Keys.trackerMigrationVersion)
    }

    private static func loadSet(key: String) -> Set<String> {
        guard let data = Self.serviceDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(decoded)
    }

    private static func save(_ values: Set<String>, key: String) {
        guard let data = try? JSONEncoder().encode(values.sorted()) else { return }
        Self.serviceDefaults.set(data, forKey: key)
    }

    private static func loadInts(key: String) -> [Int] {
        guard let data = Self.serviceDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return decoded.sorted()
    }

    private static func saveInts(_ values: [Int], key: String) {
        guard let data = try? JSONEncoder().encode(Array(Set(values)).sorted()) else { return }
        Self.serviceDefaults.set(data, forKey: key)
    }
}

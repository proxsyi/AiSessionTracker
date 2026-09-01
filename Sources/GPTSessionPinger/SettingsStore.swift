import Foundation

extension Notification.Name {
    static let commandIShortcutSettingChanged = Notification.Name("commandIShortcutSettingChanged")
}

@MainActor
final class SettingsStore: ObservableObject {
    nonisolated private static let serviceDomain = "com.proxsyi.gptsessionpinger"

    /// Reuse the standalone GPT app's preference domain when this feature
    /// runs inside the combined tracker, without colliding with Claude settings.
    private static let defaultServiceDefaults: UserDefaults = {
        guard let suiteName = defaultsSuiteName(for: Bundle.main.bundleIdentifier) else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()

    nonisolated static func defaultsSuiteName(for bundleIdentifier: String?) -> String? {
        bundleIdentifier == serviceDomain ? nil : serviceDomain
    }

    static let availableThresholds = [25, 50, 75, 90, 95, 100]
    static let defaultWeeklyThresholds = [75, 90]

    private enum Keys {
        static let organizationID = "organizationID"
        static let accountPlanType = "accountPlanType"
        static let pingModel = "chatGPTPingModel"
        static let pingReasoningEffort = "chatGPTPingReasoningEffort"
        static let pingMessage = "chatGPTPingMessage"
        static let pingConversationID = "chatGPTPingConversationID"
        static let pingParentMessageID = "chatGPTPingParentMessageID"
        static let showCategoryTabs = "trackerShowCategoryTabs"
        static let showHistoryChart = "trackerShowHistoryChart"
        static let automaticallyShowNewUsageTracks = "trackerAutomaticallyShowNewUsageTracks"
        static let hiddenUsageTrackIDs = "trackerHiddenUsageTrackIDs"
        static let knownUsageTrackIDs = "trackerKnownUsageTrackIDs"
        static let alertEnabledUsageTrackIDs = "trackerAlertEnabledUsageTrackIDs"
        static let weeklyUsageThresholds = "weeklyUsageThresholds"
        static let usageThresholdsByTrack = "trackerUsageThresholdsByTrack"
        static let enableCommandIShortcut = "enableCommandIShortcut"
        static let preferClearGlass = "preferClearGlass"
        static let launchAtLogin = "launchAtLogin"
        static let notifyOnServiceOutage = "notifyOnServiceOutage"
        static let notifyOnServiceDegraded = "notifyOnServiceDegraded"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let trackerMigrationVersion = "trackerMigrationVersion"
    }

    private static let currentTrackerMigrationVersion = 3

    @Published var organizationID: String {
        didSet { serviceDefaults.set(organizationID, forKey: Keys.organizationID) }
    }
    @Published var accountPlanType: String {
        didSet { serviceDefaults.set(accountPlanType, forKey: Keys.accountPlanType) }
    }
    @Published var pingModel: String { didSet { serviceDefaults.set(pingModel, forKey: Keys.pingModel) } }
    @Published var pingReasoningEffort: String { didSet { serviceDefaults.set(pingReasoningEffort, forKey: Keys.pingReasoningEffort) } }
    @Published var pingMessage: String { didSet { serviceDefaults.set(pingMessage, forKey: Keys.pingMessage) } }
    @Published var pingConversationID: String { didSet { serviceDefaults.set(pingConversationID, forKey: Keys.pingConversationID) } }
    @Published var pingParentMessageID: String { didSet { serviceDefaults.set(pingParentMessageID, forKey: Keys.pingParentMessageID) } }
    @Published var showCategoryTabs: Bool {
        didSet { serviceDefaults.set(showCategoryTabs, forKey: Keys.showCategoryTabs) }
    }
    @Published var showHistoryChart: Bool {
        didSet { serviceDefaults.set(showHistoryChart, forKey: Keys.showHistoryChart) }
    }
    @Published var automaticallyShowNewUsageTracks: Bool {
        didSet { serviceDefaults.set(automaticallyShowNewUsageTracks, forKey: Keys.automaticallyShowNewUsageTracks) }
    }
    @Published private(set) var hiddenUsageTrackIDs: Set<String> {
        didSet { save(hiddenUsageTrackIDs, key: Keys.hiddenUsageTrackIDs) }
    }
    @Published private(set) var knownUsageTrackIDs: Set<String> {
        didSet { save(knownUsageTrackIDs, key: Keys.knownUsageTrackIDs) }
    }
    @Published private(set) var alertEnabledUsageTrackIDs: Set<String> {
        didSet { save(alertEnabledUsageTrackIDs, key: Keys.alertEnabledUsageTrackIDs) }
    }
    @Published var weeklyUsageThresholds: [Int] {
        didSet { saveInts(weeklyUsageThresholds, key: Keys.weeklyUsageThresholds) }
    }
    @Published private(set) var usageThresholdsByTrack: [String: [Int]] {
        didSet { saveIntDictionary(usageThresholdsByTrack, key: Keys.usageThresholdsByTrack) }
    }
    @Published var enableCommandIShortcut: Bool {
        didSet {
            serviceDefaults.set(enableCommandIShortcut, forKey: Keys.enableCommandIShortcut)
            NotificationCenter.default.post(name: .commandIShortcutSettingChanged, object: nil)
        }
    }
    @Published var preferClearGlass: Bool {
        didSet { serviceDefaults.set(preferClearGlass, forKey: Keys.preferClearGlass) }
    }
    @Published var launchAtLogin: Bool {
        didSet { serviceDefaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    @Published var notifyOnServiceOutage: Bool {
        didSet { serviceDefaults.set(notifyOnServiceOutage, forKey: Keys.notifyOnServiceOutage) }
    }
    @Published var notifyOnServiceDegraded: Bool {
        didSet { serviceDefaults.set(notifyOnServiceDegraded, forKey: Keys.notifyOnServiceDegraded) }
    }
    @Published var autoUpdateEnabled: Bool {
        didSet { serviceDefaults.set(autoUpdateEnabled, forKey: Keys.autoUpdateEnabled) }
    }
    @Published var sessionKey: String {
        didSet { persistWebSession() }
    }
    @Published var cookieHeader: String {
        didSet { persistWebSession() }
    }
    @Published private(set) var credentialPersistenceError: String?
    @Published private(set) var availablePingModels: [ChatGPTModelOption] = []

    private let serviceDefaults: UserDefaults
    private let usesKeychain: Bool

    init(defaultsOverride: UserDefaults? = nil, usesKeychain: Bool = true) {
        self.serviceDefaults = defaultsOverride ?? Self.defaultServiceDefaults
        self.usesKeychain = usesKeychain
        credentialPersistenceError = nil
        let defaults = serviceDefaults
        organizationID = defaults.string(forKey: Keys.organizationID) ?? ""
        let storedWebSession = usesKeychain ? KeychainStore.load() : nil
        let storedSessionKey = storedWebSession?.sessionKey ?? ""
        sessionKey = storedSessionKey
        cookieHeader = storedWebSession?.cookieHeader ?? ""
        accountPlanType = defaults.string(forKey: Keys.accountPlanType) ?? ChatGPTWebSession.planType(from: storedSessionKey) ?? ""
        pingModel = defaults.string(forKey: Keys.pingModel) ?? ChatGPTModelCatalog.lowestUsageModelSlug
        pingReasoningEffort = defaults.string(forKey: Keys.pingReasoningEffort) ?? "none"
        pingMessage = defaults.string(forKey: Keys.pingMessage) ?? "Say 1"
        pingConversationID = defaults.string(forKey: Keys.pingConversationID) ?? ""
        pingParentMessageID = defaults.string(forKey: Keys.pingParentMessageID) ?? ""
        showCategoryTabs = defaults.object(forKey: Keys.showCategoryTabs) == nil ? true : defaults.bool(forKey: Keys.showCategoryTabs)
        showHistoryChart = defaults.object(forKey: Keys.showHistoryChart) == nil ? true : defaults.bool(forKey: Keys.showHistoryChart)
        automaticallyShowNewUsageTracks = defaults.object(forKey: Keys.automaticallyShowNewUsageTracks) == nil ? true : defaults.bool(forKey: Keys.automaticallyShowNewUsageTracks)
        hiddenUsageTrackIDs = Self.loadSet(key: Keys.hiddenUsageTrackIDs, defaults: defaults)
        knownUsageTrackIDs = Self.loadSet(key: Keys.knownUsageTrackIDs, defaults: defaults)
        let storedAlertIDs = Self.loadSet(key: Keys.alertEnabledUsageTrackIDs, defaults: defaults)
        let effectiveAlertIDs: Set<String> = defaults.object(forKey: Keys.alertEnabledUsageTrackIDs) == nil ? ["codex-weekly"] : storedAlertIDs
        alertEnabledUsageTrackIDs = effectiveAlertIDs
        let storedWeekly = Self.loadInts(key: Keys.weeklyUsageThresholds, defaults: defaults)
        let effectiveWeekly = storedWeekly.isEmpty ? Self.defaultWeeklyThresholds : storedWeekly
        weeklyUsageThresholds = effectiveWeekly
        let storedTrackThresholds = Self.loadIntDictionary(key: Keys.usageThresholdsByTrack, defaults: defaults)
        usageThresholdsByTrack = storedTrackThresholds.isEmpty
            ? Dictionary(uniqueKeysWithValues: effectiveAlertIDs.map { ($0, effectiveWeekly) })
            : storedTrackThresholds
        enableCommandIShortcut = defaults.object(forKey: Keys.enableCommandIShortcut) == nil ? true : defaults.bool(forKey: Keys.enableCommandIShortcut)
        preferClearGlass = defaults.object(forKey: Keys.preferClearGlass) == nil ? true : defaults.bool(forKey: Keys.preferClearGlass)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        notifyOnServiceOutage = defaults.object(forKey: Keys.notifyOnServiceOutage) == nil ? true : defaults.bool(forKey: Keys.notifyOnServiceOutage)
        notifyOnServiceDegraded = defaults.object(forKey: Keys.notifyOnServiceDegraded) == nil ? true : defaults.bool(forKey: Keys.notifyOnServiceDegraded)
        autoUpdateEnabled = defaults.object(forKey: Keys.autoUpdateEnabled) == nil ? true : defaults.bool(forKey: Keys.autoUpdateEnabled)

        defaults.removeObject(forKey: "keychainOwnershipMigrationVersion")
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
        return alertEnabledUsageTrackIDs.contains(id)
    }

    func setAlertEnabled(_ enabled: Bool, for id: String) {
        if enabled {
            alertEnabledUsageTrackIDs.insert(id)
            if usageThresholdsByTrack[id, default: []].isEmpty {
                usageThresholdsByTrack[id] = Self.defaultWeeklyThresholds
            }
        } else {
            alertEnabledUsageTrackIDs.remove(id)
        }
    }

    func alertThresholds(for id: String) -> [Int] {
        usageThresholdsByTrack[id] ?? Self.defaultWeeklyThresholds
    }

    func setAlertThresholds(_ thresholds: [Int], for id: String) {
        usageThresholdsByTrack[id] = Array(Set(thresholds)).sorted()
    }

    func registerAvailablePingModels(_ models: [ChatGPTModelOption]) {
        guard !models.isEmpty else { return }
        availablePingModels = models
        if let selected = models.first(where: { $0.slug == pingModel && !$0.isWorkMode }) {
            normalizePingEffort(for: selected)
        } else if let lowest = ChatGPTModelCatalog.lowestUsageOption(in: models, workMode: false) {
            pingModel = lowest.slug
            normalizePingEffort(for: lowest)
        }
    }

    func pingModelOption(for slug: String) -> ChatGPTModelOption? {
        availablePingModels.first(where: { $0.slug == slug })
    }

    func pingModelTitle(for slug: String) -> String {
        pingModelOption(for: slug)?.title ?? ChatGPTModelCatalog.fallbackTitle(for: slug)
    }

    func normalizePingEffort(for model: ChatGPTModelOption) {
        let efforts = model.selectableEfforts
        if !efforts.contains(where: { $0.id == pingReasoningEffort }) {
            pingReasoningEffort = efforts.first?.id ?? "default"
        }
    }

    func clearChatGPTLogin() {
        sessionKey = ""
        cookieHeader = ""
        organizationID = ""
        accountPlanType = ""
        pingConversationID = ""
        pingParentMessageID = ""
    }

    private func removeLegacySessionPreferencesIfNeeded(defaults: UserDefaults) {
        guard defaults.integer(forKey: Keys.trackerMigrationVersion) < Self.currentTrackerMigrationVersion else { return }
        if pingModel == "gpt-5.4-mini" {
            pingModel = ChatGPTModelCatalog.lowestUsageModelSlug
        }
        if pingModel == ChatGPTModelCatalog.lowestUsageModelSlug {
            pingReasoningEffort = "none"
        }
        [
            "model", "message", "conversationID", "showSessionBar", "showWeeklyBar", "showFable5Bar",
            "notifySessionAvailable", "notifySessionStarted", "autoStartAvailableSessions",
            "showNextPossibleCountdown", "showScheduledCountdown", "countdownFocus", "enableScheduledWake",
            "scheduleSlots", "notifyOnFailure", "sessionUsageThresholds"
        ].forEach(defaults.removeObject(forKey:))
        let obsoletePlaceholders = Set([
            "codex-rolling-5h", "code-review-weekly", "code-review-rolling-5h",
            "chatgpt-message-usage", "chatgpt-model-limits"
        ])
        knownUsageTrackIDs.subtract(obsoletePlaceholders)
        hiddenUsageTrackIDs.subtract(obsoletePlaceholders)
        alertEnabledUsageTrackIDs.subtract(obsoletePlaceholders)
        defaults.set(Self.currentTrackerMigrationVersion, forKey: Keys.trackerMigrationVersion)
    }

    private func persistWebSession() {
        guard usesKeychain else { return }
        do {
            try KeychainStore.save(sessionKey: sessionKey, cookieHeader: cookieHeader)
            credentialPersistenceError = nil
        } catch {
            credentialPersistenceError = error.localizedDescription
        }
    }

    private static func loadSet(key: String, defaults: UserDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(decoded)
    }

    private func save(_ values: Set<String>, key: String) {
        guard let data = try? JSONEncoder().encode(values.sorted()) else { return }
        serviceDefaults.set(data, forKey: key)
    }

    private static func loadInts(key: String, defaults: UserDefaults) -> [Int] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return decoded.sorted()
    }

    private func saveInts(_ values: [Int], key: String) {
        guard let data = try? JSONEncoder().encode(Array(Set(values)).sorted()) else { return }
        serviceDefaults.set(data, forKey: key)
    }

    private static func loadIntDictionary(key: String, defaults: UserDefaults) -> [String: [Int]] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data) else { return [:] }
        return decoded.mapValues { Array(Set($0)).sorted() }
    }

    private func saveIntDictionary(_ values: [String: [Int]], key: String) {
        let normalized = values.mapValues { Array(Set($0)).sorted() }
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        serviceDefaults.set(data, forKey: key)
    }
}

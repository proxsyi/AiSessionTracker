import Foundation

extension Notification.Name {
    static let commandUShortcutSettingChanged = Notification.Name("commandUShortcutSettingChanged")
}

enum CountdownFocus: String, CaseIterable, Identifiable {
    case nextPossible
    case scheduled

    var id: String { rawValue }
    var label: String { self == .nextPossible ? "Next possible" : "Scheduled" }
}

final class SettingsStore: ObservableObject {
    private static let serviceDomain = "com.proxsyi.claudesessionpinger"

    /// Reuse the standalone Claude app's preference domain when this feature
    /// runs inside the combined tracker, without colliding with GPT settings.
    private static let serviceDefaults: UserDefaults = {
        guard let suiteName = defaultsSuiteName(for: Bundle.main.bundleIdentifier) else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()

    static func defaultsSuiteName(for bundleIdentifier: String?) -> String? {
        bundleIdentifier == serviceDomain ? nil : serviceDomain
    }

    /// Usage-alert percentages the user can pick from in Settings.
    static let availableThresholds = [25, 50, 75, 90, 95, 100]
    static let defaultSessionThresholds = [75, 90]
    static let defaultWeeklyThresholds = [75, 90]

    static let defaultSlots: [ScheduleSlot] = [
        ScheduleSlot(hour: 5, minute: 0),
        ScheduleSlot(hour: 10, minute: 0),
        ScheduleSlot(hour: 15, minute: 0),
        ScheduleSlot(hour: 20, minute: 0)
    ]

    private enum Keys {
        static let organizationID = "organizationID"
        static let model = "model"
        static let message = "message"
        static let conversationID = "conversationID"
        static let showSessionBar = "showSessionBar"
        static let showWeeklyBar = "showWeeklyBar"
        static let showFable5Bar = "showFable5Bar"
        static let notifySessionAvailable = "notifySessionAvailable"
        static let notifySessionStarted = "notifySessionStarted"
        static let autoStartAvailableSessions = "autoStartAvailableSessions"
        static let enableCommandUShortcut = "enableCommandUShortcut"
        static let preferClearGlass = "preferClearGlass"
        static let showNextPossibleCountdown = "showNextPossibleCountdown"
        static let showScheduledCountdown = "showScheduledCountdown"
        static let countdownFocus = "countdownFocus"
        static let enableScheduledWake = "enableScheduledWake"
        static let scheduleSlots = "scheduleSlots"
        static let launchAtLogin = "launchAtLogin"
        static let notifyOnFailure = "notifyOnFailure"
        static let notifyOnServiceOutage = "notifyOnServiceOutage"
        static let notifyOnServiceDegraded = "notifyOnServiceDegraded"
        static let sessionUsageThresholds = "sessionUsageThresholds"
        static let weeklyUsageThresholds = "weeklyUsageThresholds"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let proxsyiDefaultsMigrated = "proxsyiDefaultsMigrated"
    }

    private static let legacyBundleIdentifier = "com.cash.claudesessionpinger"

    @Published var organizationID: String {
        didSet { Self.serviceDefaults.set(organizationID, forKey: Keys.organizationID) }
    }
    @Published var model: String {
        didSet { Self.serviceDefaults.set(model, forKey: Keys.model) }
    }
    @Published var message: String {
        didSet { Self.serviceDefaults.set(message, forKey: Keys.message) }
    }
    @Published var conversationID: String {
        didSet { Self.serviceDefaults.set(conversationID, forKey: Keys.conversationID) }
    }
    @Published var showSessionBar: Bool {
        didSet { Self.serviceDefaults.set(showSessionBar, forKey: Keys.showSessionBar) }
    }
    @Published var showWeeklyBar: Bool {
        didSet { Self.serviceDefaults.set(showWeeklyBar, forKey: Keys.showWeeklyBar) }
    }
    @Published var showFable5Bar: Bool {
        didSet { Self.serviceDefaults.set(showFable5Bar, forKey: Keys.showFable5Bar) }
    }
    @Published var notifySessionAvailable: Bool {
        didSet { Self.serviceDefaults.set(notifySessionAvailable, forKey: Keys.notifySessionAvailable) }
    }
    @Published var notifySessionStarted: Bool {
        didSet { Self.serviceDefaults.set(notifySessionStarted, forKey: Keys.notifySessionStarted) }
    }
    @Published var autoStartAvailableSessions: Bool {
        didSet { Self.serviceDefaults.set(autoStartAvailableSessions, forKey: Keys.autoStartAvailableSessions) }
    }
    @Published var enableCommandUShortcut: Bool {
        didSet {
            Self.serviceDefaults.set(enableCommandUShortcut, forKey: Keys.enableCommandUShortcut)
            NotificationCenter.default.post(name: .commandUShortcutSettingChanged, object: nil)
        }
    }
    @Published var preferClearGlass: Bool {
        didSet { Self.serviceDefaults.set(preferClearGlass, forKey: Keys.preferClearGlass) }
    }
    @Published var showNextPossibleCountdown: Bool {
        didSet { Self.serviceDefaults.set(showNextPossibleCountdown, forKey: Keys.showNextPossibleCountdown) }
    }
    @Published var showScheduledCountdown: Bool {
        didSet { Self.serviceDefaults.set(showScheduledCountdown, forKey: Keys.showScheduledCountdown) }
    }
    @Published var countdownFocus: CountdownFocus {
        didSet { Self.serviceDefaults.set(countdownFocus.rawValue, forKey: Keys.countdownFocus) }
    }
    @Published var enableScheduledWake: Bool {
        didSet { Self.serviceDefaults.set(enableScheduledWake, forKey: Keys.enableScheduledWake) }
    }
    @Published var scheduleSlots: [ScheduleSlot] {
        didSet {
            if let data = try? JSONEncoder().encode(scheduleSlots) {
                Self.serviceDefaults.set(data, forKey: Keys.scheduleSlots)
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { Self.serviceDefaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    @Published var notifyOnFailure: Bool {
        didSet { Self.serviceDefaults.set(notifyOnFailure, forKey: Keys.notifyOnFailure) }
    }
    @Published var notifyOnServiceOutage: Bool {
        didSet { Self.serviceDefaults.set(notifyOnServiceOutage, forKey: Keys.notifyOnServiceOutage) }
    }
    /// Notify when Claude's status page reports degraded performance (minor
    /// issues), separately from full outages.
    @Published var notifyOnServiceDegraded: Bool {
        didSet { Self.serviceDefaults.set(notifyOnServiceDegraded, forKey: Keys.notifyOnServiceDegraded) }
    }
    @Published var sessionUsageThresholds: [Int] {
        didSet {
            if let data = try? JSONEncoder().encode(sessionUsageThresholds) {
                Self.serviceDefaults.set(data, forKey: Keys.sessionUsageThresholds)
            }
        }
    }
    @Published var weeklyUsageThresholds: [Int] {
        didSet {
            if let data = try? JSONEncoder().encode(weeklyUsageThresholds) {
                Self.serviceDefaults.set(data, forKey: Keys.weeklyUsageThresholds)
            }
        }
    }
    /// When true, new releases are downloaded and installed automatically as
    /// soon as the daily check finds one.
    @Published var autoUpdateEnabled: Bool {
        didSet { Self.serviceDefaults.set(autoUpdateEnabled, forKey: Keys.autoUpdateEnabled) }
    }
    @Published var sessionKey: String {
        didSet { persistWebSession() }
    }
    /// The full Cookie header captured by the built-in login (every claude.ai
    /// cookie, not just sessionKey), stored in the keychain alongside the key.
    @Published var cookieHeader: String {
        didSet { persistWebSession() }
    }

    init() {
        let defaults = Self.serviceDefaults
        Self.migrateLegacyDefaultsIfNeeded(into: defaults)
        organizationID = defaults.string(forKey: Keys.organizationID) ?? ""
        let storedModel = defaults.string(forKey: Keys.model) ?? ""
        model = storedModel.isEmpty ? "claude-haiku-4-5-20251001" : storedModel
        message = defaults.string(forKey: Keys.message) ?? "Say 1"
        conversationID = defaults.string(forKey: Keys.conversationID) ?? ""
        showSessionBar = defaults.object(forKey: Keys.showSessionBar) == nil ? true : defaults.bool(forKey: Keys.showSessionBar)
        showWeeklyBar = defaults.object(forKey: Keys.showWeeklyBar) == nil ? true : defaults.bool(forKey: Keys.showWeeklyBar)
        showFable5Bar = defaults.object(forKey: Keys.showFable5Bar) == nil ? false : defaults.bool(forKey: Keys.showFable5Bar)
        notifySessionAvailable = defaults.object(forKey: Keys.notifySessionAvailable) == nil ? true : defaults.bool(forKey: Keys.notifySessionAvailable)
        notifySessionStarted = defaults.object(forKey: Keys.notifySessionStarted) == nil ? true : defaults.bool(forKey: Keys.notifySessionStarted)
        autoStartAvailableSessions = defaults.bool(forKey: Keys.autoStartAvailableSessions)
        enableCommandUShortcut = defaults.object(forKey: Keys.enableCommandUShortcut) == nil ? true : defaults.bool(forKey: Keys.enableCommandUShortcut)
        preferClearGlass = defaults.object(forKey: Keys.preferClearGlass) == nil ? true : defaults.bool(forKey: Keys.preferClearGlass)
        showNextPossibleCountdown = defaults.object(forKey: Keys.showNextPossibleCountdown) == nil ? true : defaults.bool(forKey: Keys.showNextPossibleCountdown)
        showScheduledCountdown = defaults.object(forKey: Keys.showScheduledCountdown) == nil ? true : defaults.bool(forKey: Keys.showScheduledCountdown)
        countdownFocus = CountdownFocus(rawValue: defaults.string(forKey: Keys.countdownFocus) ?? "") ?? .nextPossible
        enableScheduledWake = defaults.object(forKey: Keys.enableScheduledWake) == nil ? true : defaults.bool(forKey: Keys.enableScheduledWake)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        notifyOnFailure = defaults.object(forKey: Keys.notifyOnFailure) == nil ? true : defaults.bool(forKey: Keys.notifyOnFailure)
        notifyOnServiceOutage = defaults.object(forKey: Keys.notifyOnServiceOutage) == nil ? true : defaults.bool(forKey: Keys.notifyOnServiceOutage)
        notifyOnServiceDegraded = defaults.object(forKey: Keys.notifyOnServiceDegraded) == nil ? true : defaults.bool(forKey: Keys.notifyOnServiceDegraded)
        if let data = defaults.data(forKey: Keys.sessionUsageThresholds),
           let decoded = try? JSONDecoder().decode([Int].self, from: data) {
            sessionUsageThresholds = decoded
        } else {
            sessionUsageThresholds = SettingsStore.defaultSessionThresholds
        }
        if let data = defaults.data(forKey: Keys.weeklyUsageThresholds),
           let decoded = try? JSONDecoder().decode([Int].self, from: data) {
            weeklyUsageThresholds = decoded
        } else {
            weeklyUsageThresholds = SettingsStore.defaultWeeklyThresholds
        }
        let storedWebSession = KeychainStore.load()
        sessionKey = storedWebSession?.sessionKey ?? ""
        cookieHeader = storedWebSession?.cookieHeader ?? ""
        defaults.removeObject(forKey: "keychainOwnershipMigrationVersion")
        autoUpdateEnabled = defaults.object(forKey: Keys.autoUpdateEnabled) == nil ? true : defaults.bool(forKey: Keys.autoUpdateEnabled)
        if let data = defaults.data(forKey: Keys.scheduleSlots),
           let decoded = try? JSONDecoder().decode([ScheduleSlot].self, from: data),
           ScheduleRules.isValid(decoded) {
            scheduleSlots = decoded
        } else {
            scheduleSlots = SettingsStore.defaultSlots
        }
    }

    private func persistWebSession() {
        try? KeychainStore.save(sessionKey: sessionKey, cookieHeader: cookieHeader)
    }

    private static func migrateLegacyDefaultsIfNeeded(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.proxsyiDefaultsMigrated) else { return }
        if let legacyValues = defaults.persistentDomain(forName: legacyBundleIdentifier) {
            for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: Keys.proxsyiDefaultsMigrated)
    }

    var isConfigured: Bool {
        !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Cookie header requests should send: the full captured login
    /// cookies when they still match the current session key, otherwise just
    /// the session key (e.g. after a manual key paste).
    var effectiveCookieHeader: String {
        let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMatchingSessionCookie = cookieHeader
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("sessionKey=\(trimmedKey)")
        if !trimmedKey.isEmpty, hasMatchingSessionCookie {
            return cookieHeader
        }
        return "sessionKey=\(trimmedKey)"
    }

    var maskedSessionKey: String {
        guard sessionKey.count > 4 else { return sessionKey.isEmpty ? "" : "••••" }
        let suffix = sessionKey.suffix(4)
        return "••••••••" + suffix
    }
}

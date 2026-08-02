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
        static let keychainOwnershipMigrationVersion = "keychainOwnershipMigrationVersion"
        static let proxsyiDefaultsMigrated = "proxsyiDefaultsMigrated"
    }

    private static let currentKeychainOwnershipMigrationVersion = 2

    @Published var organizationID: String {
        didSet { UserDefaults.standard.set(organizationID, forKey: Keys.organizationID) }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }
    @Published var message: String {
        didSet { UserDefaults.standard.set(message, forKey: Keys.message) }
    }
    @Published var conversationID: String {
        didSet { UserDefaults.standard.set(conversationID, forKey: Keys.conversationID) }
    }
    @Published var showSessionBar: Bool {
        didSet { UserDefaults.standard.set(showSessionBar, forKey: Keys.showSessionBar) }
    }
    @Published var showWeeklyBar: Bool {
        didSet { UserDefaults.standard.set(showWeeklyBar, forKey: Keys.showWeeklyBar) }
    }
    @Published var showFable5Bar: Bool {
        didSet { UserDefaults.standard.set(showFable5Bar, forKey: Keys.showFable5Bar) }
    }
    @Published var notifySessionAvailable: Bool {
        didSet { UserDefaults.standard.set(notifySessionAvailable, forKey: Keys.notifySessionAvailable) }
    }
    @Published var notifySessionStarted: Bool {
        didSet { UserDefaults.standard.set(notifySessionStarted, forKey: Keys.notifySessionStarted) }
    }
    @Published var autoStartAvailableSessions: Bool {
        didSet { UserDefaults.standard.set(autoStartAvailableSessions, forKey: Keys.autoStartAvailableSessions) }
    }
    @Published var enableCommandUShortcut: Bool {
        didSet {
            UserDefaults.standard.set(enableCommandUShortcut, forKey: Keys.enableCommandUShortcut)
            NotificationCenter.default.post(name: .commandUShortcutSettingChanged, object: nil)
        }
    }
    @Published var preferClearGlass: Bool {
        didSet { UserDefaults.standard.set(preferClearGlass, forKey: Keys.preferClearGlass) }
    }
    @Published var showNextPossibleCountdown: Bool {
        didSet { UserDefaults.standard.set(showNextPossibleCountdown, forKey: Keys.showNextPossibleCountdown) }
    }
    @Published var showScheduledCountdown: Bool {
        didSet { UserDefaults.standard.set(showScheduledCountdown, forKey: Keys.showScheduledCountdown) }
    }
    @Published var countdownFocus: CountdownFocus {
        didSet { UserDefaults.standard.set(countdownFocus.rawValue, forKey: Keys.countdownFocus) }
    }
    @Published var enableScheduledWake: Bool {
        didSet { UserDefaults.standard.set(enableScheduledWake, forKey: Keys.enableScheduledWake) }
    }
    @Published var scheduleSlots: [ScheduleSlot] {
        didSet {
            if let data = try? JSONEncoder().encode(scheduleSlots) {
                UserDefaults.standard.set(data, forKey: Keys.scheduleSlots)
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    @Published var notifyOnFailure: Bool {
        didSet { UserDefaults.standard.set(notifyOnFailure, forKey: Keys.notifyOnFailure) }
    }
    @Published var notifyOnServiceOutage: Bool {
        didSet { UserDefaults.standard.set(notifyOnServiceOutage, forKey: Keys.notifyOnServiceOutage) }
    }
    /// Notify when OpenAI's status page reports degraded performance (minor
    /// issues), separately from full outages.
    @Published var notifyOnServiceDegraded: Bool {
        didSet { UserDefaults.standard.set(notifyOnServiceDegraded, forKey: Keys.notifyOnServiceDegraded) }
    }
    @Published var sessionUsageThresholds: [Int] {
        didSet {
            if let data = try? JSONEncoder().encode(sessionUsageThresholds) {
                UserDefaults.standard.set(data, forKey: Keys.sessionUsageThresholds)
            }
        }
    }
    @Published var weeklyUsageThresholds: [Int] {
        didSet {
            if let data = try? JSONEncoder().encode(weeklyUsageThresholds) {
                UserDefaults.standard.set(data, forKey: Keys.weeklyUsageThresholds)
            }
        }
    }
    /// When true, new releases are downloaded and installed automatically as
    /// soon as the daily check finds one.
    @Published var autoUpdateEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUpdateEnabled, forKey: Keys.autoUpdateEnabled) }
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
    /// The full Cookie header captured by the built-in login (every ChatGPT
    /// cookie, not just sessionKey), stored in the keychain alongside the key.
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
        let defaults = UserDefaults.standard
        organizationID = defaults.string(forKey: Keys.organizationID) ?? ""
        let storedModel = defaults.string(forKey: Keys.model) ?? ""
        // Earlier GPT previews briefly inherited the old app's preference
        // domain. A Claude model slug is never valid for this app, so replace
        // it with the GPT automatic model and persist that correction.
        let normalizedModel = storedModel == "auto"
            || storedModel == "gpt-5.4-mini"
            || storedModel.lowercased().contains("claude")
            ? "gpt-5-4-t-mini"
            : (storedModel.isEmpty ? "gpt-5-4-t-mini" : storedModel)
        model = normalizedModel
        if normalizedModel != storedModel {
            defaults.set(normalizedModel, forKey: Keys.model)
        }
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
        let storedSessionKey = KeychainStore.load() ?? ""
        let storedCookieHeader = KeychainStore.load(account: "cookieHeader") ?? ""
        sessionKey = storedSessionKey
        cookieHeader = storedCookieHeader
        // Re-create legacy keychain items under the current stable signing
        // identity. Versioning this migration lets an older, incomplete
        // migration be repaired once without repeating it every launch.
        if defaults.integer(forKey: Keys.keychainOwnershipMigrationVersion) < Self.currentKeychainOwnershipMigrationVersion,
           !storedSessionKey.isEmpty {
            try? KeychainStore.save(storedSessionKey)
            if !storedCookieHeader.isEmpty {
                try? KeychainStore.save(storedCookieHeader, account: "cookieHeader")
            }
            defaults.set(Self.currentKeychainOwnershipMigrationVersion, forKey: Keys.keychainOwnershipMigrationVersion)
        }
        autoUpdateEnabled = defaults.object(forKey: Keys.autoUpdateEnabled) == nil ? true : defaults.bool(forKey: Keys.autoUpdateEnabled)
        if let data = defaults.data(forKey: Keys.scheduleSlots),
           let decoded = try? JSONDecoder().decode([ScheduleSlot].self, from: data),
           ScheduleRules.isValid(decoded) {
            scheduleSlots = decoded
        } else {
            scheduleSlots = SettingsStore.defaultSlots
        }
    }

    var isConfigured: Bool {
        !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Cookie header requests should send: the full captured login
    /// cookies when they still match the current session key, otherwise just
    /// the session key (e.g. after a manual key paste).
    var effectiveCookieHeader: String {
        cookieHeader
    }

    var maskedSessionKey: String {
        guard sessionKey.count > 4 else { return sessionKey.isEmpty ? "" : "••••" }
        let suffix = sessionKey.suffix(4)
        return "••••••••" + suffix
    }
}

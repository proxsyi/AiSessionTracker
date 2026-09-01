import XCTest
@testable import CombinedSessionTracker

@MainActor
final class SettingsPersistenceTests: XCTestCase {
    func testEveryClaudeToggleSurvivesSaveAndReload() throws {
        let name = "test.claude-settings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaultsOverride: defaults, usesKeychain: false)
        let paths: [ReferenceWritableKeyPath<SettingsStore, Bool>] = [
            \.showSessionBar, \.showWeeklyBar, \.showHistoryChart, \.notifySessionAvailable, \.notifySessionStarted,
            \.autoStartAvailableSessions, \.enableCommandUShortcut, \.preferClearGlass, \.showNextPossibleCountdown,
            \.showScheduledCountdown, \.enableScheduledWake, \.launchAtLogin, \.notifyOnFailure, \.notifyOnSuccess,
            \.scheduledPingsEnabled, \.notifyOnServiceOutage, \.notifyOnServiceDegraded, \.autoUpdateEnabled
        ]
        for value in [false, true] {
            for path in paths { store[keyPath: path] = value }
            let reloaded = SettingsStore(defaultsOverride: defaults, usesKeychain: false)
            for path in paths { XCTAssertEqual(reloaded[keyPath: path], value, "\(path)") }
        }
        store.model = "claude-haiku-4-5-20251001"
        store.message = "Say 1"
        store.conversationID = "saved-claude-chat"
        store.organizationID = "test-org"
        store.scheduleSlots = [.init(hour: 5, minute: 30), .init(hour: 10, minute: 30)]
        store.countdownFocus = .scheduled
        store.sessionUsageThresholds = []
        store.weeklyUsageThresholds = [25, 95]
        let reloaded = SettingsStore(defaultsOverride: defaults, usesKeychain: false)
        XCTAssertEqual(reloaded.model, store.model)
        XCTAssertEqual(reloaded.message, store.message)
        XCTAssertEqual(reloaded.conversationID, store.conversationID)
        XCTAssertEqual(reloaded.organizationID, store.organizationID)
        XCTAssertEqual(reloaded.scheduleSlots, store.scheduleSlots)
        XCTAssertEqual(reloaded.countdownFocus, .scheduled)
        XCTAssertEqual(reloaded.sessionUsageThresholds, [])
        XCTAssertEqual(reloaded.weeklyUsageThresholds, [25, 95])
    }
}

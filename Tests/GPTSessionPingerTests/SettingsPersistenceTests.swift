import XCTest
@testable import GPTTrackerFeature

@MainActor
final class SettingsPersistenceTests: XCTestCase {
    func testCodexPingerRoundTripsEveryPreferenceWithoutScheduling() throws {
        let name = "test.codex-settings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaultsOverride: defaults, usesKeychain: false)
        let pinger = CodexSessionPinger(settings: settings, defaultsOverride: defaults)
        let paths: [WritableKeyPath<CodexSessionPinger.Preferences, Bool>] = [
            \.enabled, \.notifyOnFailure, \.notifyOnSuccess, \.notifySessionAvailable, \.notifySessionStarted,
            \.showNextPossibleCountdown, \.showScheduledCountdown, \.autoStartAvailableSessions, \.enableScheduledWake
        ]
        var draft = pinger.preferences
        draft.slots = [.init(hour: 5, minute: 30), .init(hour: 10, minute: 30)]
        draft.model = "gpt-5.6-luna-wm"
        draft.reasoningEffort = "min"
        draft.message = "Say 1"
        draft.countdownFocus = .scheduled
        for value in [false, true] {
            for path in paths { draft[keyPath: path] = value }
            pinger.applyPreferences(draft)
            let reloaded = CodexSessionPinger(settings: settings, defaultsOverride: defaults)
            XCTAssertEqual(reloaded.preferences, draft)
            XCTAssertNil(reloaded.nextFireDate, "A test instance must not schedule real pings")
        }
        var invalid = draft
        invalid.slots = [.init(hour: 5, minute: 0), .init(hour: 6, minute: 0)]
        pinger.applyPreferences(invalid)
        XCTAssertEqual(pinger.preferences, draft)
    }

    func testEveryUsageAndAppSettingRoundTripsAndCountersStayIndependent() throws {
        let name = "test.gpt-settings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaultsOverride: defaults, usesKeychain: false)
        let paths: [ReferenceWritableKeyPath<SettingsStore, Bool>] = [
            \.showCategoryTabs, \.showHistoryChart, \.automaticallyShowNewUsageTracks, \.enableCommandIShortcut,
            \.preferClearGlass, \.launchAtLogin, \.notifyOnServiceOutage, \.notifyOnServiceDegraded, \.autoUpdateEnabled
        ]
        for value in [false, true] {
            for path in paths { store[keyPath: path] = value }
            let reloaded = SettingsStore(defaultsOverride: defaults, usesKeychain: false)
            for path in paths { XCTAssertEqual(reloaded[keyPath: path], value, "\(path)") }
        }
        store.setUsageTrackVisible("codex-weekly", isVisible: false)
        store.setUsageTrackVisible("model-messages", isVisible: true)
        store.setAlertEnabled(true, for: "codex-weekly")
        store.setAlertThresholds([25, 95], for: "codex-weekly")
        store.setAlertEnabled(false, for: "model-messages")
        store.setAlertThresholds([], for: "model-messages")
        store.pingConversationID = "saved-chatgpt-chat"
        store.pingParentMessageID = "saved-parent"
        store.pingModel = "gpt-5-3-mini"
        store.pingReasoningEffort = "none"
        store.pingMessage = "Say 1"
        let reloaded = SettingsStore(defaultsOverride: defaults, usesKeychain: false)
        XCTAssertFalse(reloaded.isUsageTrackVisible("codex-weekly"))
        XCTAssertTrue(reloaded.isUsageTrackVisible("model-messages"))
        XCTAssertTrue(reloaded.isAlertEnabled(for: "codex-weekly"))
        XCTAssertFalse(reloaded.isAlertEnabled(for: "model-messages"))
        XCTAssertEqual(reloaded.alertThresholds(for: "codex-weekly"), [25, 95])
        XCTAssertEqual(reloaded.alertThresholds(for: "model-messages"), [])
        XCTAssertEqual(reloaded.pingConversationID, store.pingConversationID)
        XCTAssertEqual(reloaded.pingParentMessageID, store.pingParentMessageID)
        XCTAssertEqual(reloaded.pingModel, store.pingModel)
        XCTAssertEqual(reloaded.pingReasoningEffort, store.pingReasoningEffort)
        XCTAssertEqual(reloaded.pingMessage, store.pingMessage)
    }
}

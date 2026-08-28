import XCTest

final class SharedDesignContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProviderSettingsUseTheSharedWindowRailCardsAndRows() throws {
        for relativePath in [
            "Sources/ClaudeSessionPinger/SettingsView.swift",
            "Sources/GPTSessionPinger/SettingsView.swift"
        ] {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
            XCTAssertTrue(source.contains("TrackerSettingsWindow("), relativePath)
            XCTAssertTrue(source.contains("TrackerSettingsCard("), relativePath)
            XCTAssertTrue(source.contains("TrackerSettingsToggleRow("), relativePath)
            XCTAssertTrue(source.contains("TrackerSettingsFieldLabel("), relativePath)
            XCTAssertTrue(source.contains("TrackerSettingsFooter("), relativePath)
            XCTAssertTrue(source.contains("TrackerSettingsThresholdPicker("), relativePath)
            XCTAssertFalse(source.contains("private enum SettingsTab"), relativePath)
            XCTAssertFalse(source.contains("indicatorWidth"), relativePath)
            XCTAssertFalse(source.contains("tabDragGesture"), relativePath)
        }
    }

    func testProviderMenusUseTheSharedStackCardsRowsStatusAndSessionCard() throws {
        for relativePath in [
            "Sources/ClaudeSessionPinger/MenuBarContentView.swift",
            "Sources/GPTSessionPinger/MenuBarContentView.swift"
        ] {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
            XCTAssertTrue(source.contains("TrackerMenuStack"), relativePath)
            XCTAssertTrue(source.contains("TrackerMenuCard("), relativePath)
            XCTAssertTrue(source.contains("TrackerMenuUsageRow("), relativePath)
            XCTAssertTrue(source.contains("TrackerMenuServiceStatus("), relativePath)
            XCTAssertTrue(source.contains("TrackerMenuSessionCard("), relativePath)
            XCTAssertFalse(source.contains("trackerMenuCardLayout()"), relativePath)
        }
    }

    func testCodexPingerKeepsClaudeFeatureParityWithoutSharingProviderState() throws {
        let pinger = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/CodexSessionPinger.swift"
        ))
        let settings = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/SettingsView.swift"
        ))
        let wake = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/CodexWakeSupport.swift"
        ))

        for feature in [
            "conversationID", "parentMessageID", "PingRecord", "successRateText",
            "autoStartAvailableSessions", "notifySessionAvailable", "notifySessionStarted",
            "showNextPossibleCountdown", "showScheduledCountdown", "countdownFocus",
            "installWakeSupport", "testWakeSupport"
        ] {
            XCTAssertTrue(pinger.contains(feature), feature)
        }
        XCTAssertTrue(settings.contains("Open pinger chat"))
        XCTAssertTrue(settings.contains("Start fresh chat"))
        XCTAssertTrue(settings.contains("Wake Mac for scheduled pings"))
        XCTAssertTrue(wake.contains("codexWakeSupportScheduledWakeEpochs"))
        XCTAssertFalse(wake.contains("wakeSupportScheduledWakeEpochs\""))
    }

    func testWakeHelperKeepsClaudeAndCodexPowerEventsIndependent() throws {
        let helper = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/SessionPingerWakeHelper/main.c"
        ))
        let claudeWake = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/ClaudeSessionPinger/WakeSupport.swift"
        ))
        let codexWake = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/CodexWakeSupport.swift"
        ))

        XCTAssertTrue(helper.contains("#define HELPER_VERSION \"3\""))
        XCTAssertTrue(helper.contains("com.proxsyi.sessiontracker.claude"))
        XCTAssertTrue(helper.contains("com.proxsyi.sessiontracker.codex"))
        XCTAssertTrue(claudeWake.contains("[\"schedule\", \"claude\""))
        XCTAssertTrue(claudeWake.contains("[\"cancel\", \"claude\""))
        XCTAssertTrue(codexWake.contains("[\"schedule\", \"codex\""))
        XCTAssertTrue(codexWake.contains("[\"cancel\", \"codex\""))
    }

    func testCombinedSettingsKeepProviderNavigationMountedAndCentralizeWakeSetup() throws {
        let combined = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/ClaudeSessionPinger/CombinedViews.swift"
        ))
        let claudeSettings = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/ClaudeSessionPinger/SettingsView.swift"
        ))
        let gptSettings = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/SettingsView.swift"
        ))

        XCTAssertTrue(combined.contains("case system = \"System\""))
        XCTAssertTrue(combined.contains("settingsLayer(isActive:"))
        XCTAssertTrue(combined.contains("Ready for Claude and Codex"))
        XCTAssertTrue(combined.contains("Install wake support"))
        XCTAssertTrue(claudeSettings.contains("Set up in System"))
        XCTAssertTrue(gptSettings.contains("Set up in System"))
        XCTAssertFalse(claudeSettings.contains("settingsCard { usageBehaviorSection }"))
        XCTAssertFalse(gptSettings.contains("settingsCard { usageExplanationSection }"))
    }

    func testCombinedAppExposesOptInSettingsPreviewForAccessibilityVerification() throws {
        let app = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/ClaudeSessionPinger/App.swift"
        ))

        XCTAssertTrue(app.contains("--show-settings-window-for-testing"))
        XCTAssertTrue(app.contains("settingsWindowController?.show()"))
    }

    func testStandaloneGPTAppCannotExposeOrStartCodexPinging() throws {
        let app = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/App.swift"
        ))
        let feature = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/CombinedFeature.swift"
        ))
        let menu = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/MenuBarContentView.swift"
        ))

        XCTAssertTrue(app.contains("CodexSessionPinger(settings: settings)"))
        XCTAssertTrue(feature.contains("hostAllowsPinging: true"))
        XCTAssertTrue(menu.contains("if embeddedTab != nil, tab == .codex"))
    }

    func testCodexMenuKeepsResetAndPingDiagnosticsOutOfTheDashboard() throws {
        let menu = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/MenuBarContentView.swift"
        ))

        XCTAssertTrue(menu.contains("if tab == .chatGPT, let reset = primaryResetDate(for: tracks)"))
        XCTAssertFalse(menu.contains("status: codexSessionPinger.status"))
        XCTAssertFalse(menu.contains("codexStatusColor"))
    }

    func testGPTAlertThresholdsAreStoredAndReadPerCounter() throws {
        let settingsStore = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/SettingsStore.swift"
        ))
        let appState = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/AppState.swift"
        ))
        let settingsView = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/GPTSessionPinger/SettingsView.swift"
        ))

        XCTAssertTrue(settingsStore.contains("usageThresholdsByTrack: [String: [Int]]"))
        XCTAssertTrue(appState.contains("settings.alertThresholds(for: id)"))
        XCTAssertTrue(settingsView.contains("thresholdBinding(for: row.id)"))
        XCTAssertFalse(appState.contains("let thresholds = settings.weeklyUsageThresholds"))
    }
}

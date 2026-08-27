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

    func testProviderMenuCardsUseTheSharedLayout() throws {
        for relativePath in [
            "Sources/ClaudeSessionPinger/MenuBarContentView.swift",
            "Sources/GPTSessionPinger/MenuBarContentView.swift"
        ] {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
            XCTAssertTrue(source.contains("trackerMenuCardLayout()"), relativePath)
        }
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

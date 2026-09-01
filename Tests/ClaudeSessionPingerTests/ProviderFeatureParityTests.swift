import XCTest
import TrackerDesignSystem
@testable import CombinedSessionTracker

final class ProviderFeatureParityTests: XCTestCase {
    func testSharedScheduleEditorSupportsMinutePrecisionAndSameValidation() {
        let times = [TrackerScheduleTime(hour: 5, minute: 30), .init(hour: 10, minute: 30)]
        XCTAssertNil(TrackerScheduleRules.validationMessage(times))
        XCTAssertEqual(TrackerScheduleRules.firstAvailableTime(addingTo: times), .init(hour: 0, minute: 0))
        XCTAssertNotNil(TrackerScheduleRules.validationMessage([.init(hour: 5, minute: 30), .init(hour: 10, minute: 29)]))
        XCTAssertEqual(ScheduleRules.validationMessage(for: [.init(hour: 5, minute: 30), .init(hour: 10, minute: 29)]),
            TrackerScheduleRules.validationMessage([.init(hour: 5, minute: 30), .init(hour: 10, minute: 29)]))
    }

    func testCommonSettingsAreImplementedByTheSameControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/ClaudeSessionPinger/SettingsView.swift", "Sources/GPTSessionPinger/SettingsView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path))
            for control in ["TrackerScheduleEditor(", "TrackerSessionDisplaySettings(", "TrackerPingAlertSettings(",
                            "Use lowest usage", "Refresh models", "Show weekly trend", "Clear weekly trend history",
                            "TrackerActivitySettings(", "TrackerAccountSettings(", "TrackerPingSettings(",
                            "TrackerServiceAlertSettings(", "TrackerWakeSettings(", "TrackerUsageAlertSetting("] {
                XCTAssertTrue(source.contains(control), "\(path): missing \(control)")
            }
            XCTAssertFalse(source.contains("(suggested) —"))
            XCTAssertFalse(source.contains("(lowest usage)"))
        }
    }
}

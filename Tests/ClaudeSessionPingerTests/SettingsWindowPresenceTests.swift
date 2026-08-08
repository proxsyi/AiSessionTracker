import AppKit
import XCTest
@testable import CombinedSessionTracker

@MainActor
final class SettingsWindowPresenceTests: XCTestCase {
    func testSettingsWindowStaysAboveNormalWindowsWhenMenuBarActivates() {
        let window = NSWindow()

        SettingsWindowController.configureWindowPresence(window)

        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.collectionBehavior.contains(.auxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenDisallowsTiling))
    }
}

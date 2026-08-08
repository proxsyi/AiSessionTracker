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

    func testFocusIsRestoredOnlyForAnUnclickedMenuBarHover() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        XCTAssertTrue(SettingsWindowController.shouldRestoreFocusForMenuBarHover(
            mouseLocation: NSPoint(x: 960, y: 1078),
            pressedMouseButtons: 0,
            screenFrames: [screen]
        ))
        XCTAssertFalse(SettingsWindowController.shouldRestoreFocusForMenuBarHover(
            mouseLocation: NSPoint(x: 960, y: 900),
            pressedMouseButtons: 0,
            screenFrames: [screen]
        ))
        XCTAssertFalse(SettingsWindowController.shouldRestoreFocusForMenuBarHover(
            mouseLocation: NSPoint(x: 960, y: 1078),
            pressedMouseButtons: 1,
            screenFrames: [screen]
        ))
    }
}

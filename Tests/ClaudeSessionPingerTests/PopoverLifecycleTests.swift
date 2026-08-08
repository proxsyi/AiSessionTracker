import AppKit
import XCTest
@testable import CombinedSessionTracker

@MainActor
final class PopoverLifecycleTests: XCTestCase {
    func testNormalPopoverClosesWhenAppDeactivates() {
        XCTAssertTrue(StatusBarController.shouldCloseOnDeactivate(
            shortcutKeyIsDown: false,
            popoverBehavior: .transient
        ))
    }

    func testShortcutKeyUpCannotImmediatelyCloseProtectedPopover() {
        XCTAssertFalse(StatusBarController.shouldCloseOnDeactivate(
            shortcutKeyIsDown: true,
            popoverBehavior: .applicationDefined
        ))
    }

    func testApplicationDefinedProtectionOwnsOutsideClickDismissal() {
        XCTAssertFalse(StatusBarController.shouldCloseOnDeactivate(
            shortcutKeyIsDown: false,
            popoverBehavior: .applicationDefined
        ))
    }
}

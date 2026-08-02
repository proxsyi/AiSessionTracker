import XCTest
@testable import GPTUsageTracker

final class HotKeyPressGateTests: XCTestCase {
    func testOneTogglePerPressReleasePair() {
        var gate = HotKeyPressGate()

        XCTAssertTrue(gate.handle(.pressed, at: 1))
        XCTAssertFalse(gate.handle(.pressed, at: 1.1))
        XCTAssertFalse(gate.handle(.released, at: 1.2))
        XCTAssertTrue(gate.handle(.pressed, at: 1.3))
    }

    func testHeldKeyRepeatsNeverRetoggle() {
        var gate = HotKeyPressGate()

        XCTAssertTrue(gate.handle(.pressed, at: 1))
        XCTAssertFalse(gate.handle(.pressed, at: 1.5))
        XCTAssertFalse(gate.handle(.pressed, at: 1.55))
        XCTAssertFalse(gate.handle(.pressed, at: 1.6))
    }

    func testNextPressRecoversAfterMissingRelease() {
        var gate = HotKeyPressGate()

        XCTAssertTrue(gate.handle(.pressed, at: 1))
        XCTAssertTrue(gate.handle(.pressed, at: 2))
    }

    func testResetAllowsImmediateRegistrationCyclePress() {
        var gate = HotKeyPressGate()
        XCTAssertTrue(gate.handle(.pressed, at: 1))

        gate.reset()

        XCTAssertTrue(gate.handle(.pressed, at: 1.1))
    }
}

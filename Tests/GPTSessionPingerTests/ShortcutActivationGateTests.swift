import Testing
@testable import GPTUsageTracker

@Suite("Shortcut activation gate")
struct ShortcutActivationGateTests {
    @Test("accepts the first callback")
    func acceptsFirstCallback() {
        var gate = ShortcutActivationGate()
        let accepted = gate.shouldHandle(at: 10)

        #expect(accepted)
    }

    @Test("suppresses a second event path for the same key press")
    func suppressesDuplicateCallback() {
        var gate = ShortcutActivationGate(minimumInterval: 0.2)
        let first = gate.shouldHandle(at: 10)
        let duplicate = gate.shouldHandle(at: 10.01)

        #expect(first)
        #expect(!duplicate)
    }

    @Test("accepts a later physical key press")
    func acceptsLaterPress() {
        var gate = ShortcutActivationGate(minimumInterval: 0.2)
        let first = gate.shouldHandle(at: 10)
        let later = gate.shouldHandle(at: 10.21)

        #expect(first)
        #expect(later)
    }
}

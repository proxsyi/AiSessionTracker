import Testing
@testable import GPTUsageTracker

@Suite("Shortcut press cycle")
struct ShortcutPressCycleTests {
    @Test("one physical press activates exactly once")
    func onePressOneActivation() {
        var cycle = ShortcutPressCycle()
        let down = cycle.handle(.keyDown)
        let duplicateDown = cycle.handle(.keyDown)
        let up = cycle.handle(.keyUp)
        let duplicateUp = cycle.handle(.keyUp)

        #expect(down)
        #expect(!duplicateDown)
        #expect(!up)
        #expect(!duplicateUp)
    }

    @Test("a later press activates again")
    func laterPressActivatesAgain() {
        var cycle = ShortcutPressCycle()
        let first = cycle.handle(.keyDown)
        _ = cycle.handle(.keyUp)
        let second = cycle.handle(.keyDown)

        #expect(first)
        #expect(second)
    }

    @Test("reset recovers a missed release")
    func resetRecoversMissedRelease() {
        var cycle = ShortcutPressCycle()
        _ = cycle.handle(.keyDown)
        cycle.reset()
        let recovered = cycle.handle(.keyDown)

        #expect(recovered)
    }
}

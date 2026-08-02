/// Converts any number of key callbacks into one activation per physical
/// down/up cycle.
struct ShortcutPressCycle {
    enum Event {
        case keyDown
        case keyUp
    }

    private var isPressed = false

    mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .keyDown:
            guard !isPressed else { return false }
            isPressed = true
            return true
        case .keyUp:
            isPressed = false
            return false
        }
    }

    mutating func reset() {
        isPressed = false
    }
}

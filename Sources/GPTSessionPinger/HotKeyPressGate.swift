import Foundation

/// Converts Carbon press/release callbacks into one toggle per physical key
/// press. If macOS drops a release callback, the next press recovers after a
/// quiet gap; auto-repeat events keep refreshing the gap and cannot re-toggle.
struct HotKeyPressGate {
    enum Event {
        case pressed
        case released
    }

    private(set) var isDown = false
    private var lastPressedAt = TimeInterval.leastNormalMagnitude
    private let missedReleaseRecoveryInterval: TimeInterval

    init(missedReleaseRecoveryInterval: TimeInterval = 0.8) {
        self.missedReleaseRecoveryInterval = missedReleaseRecoveryInterval
    }

    mutating func handle(_ event: Event, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        switch event {
        case .released:
            isDown = false
            return false
        case .pressed:
            let quietGap = uptime - lastPressedAt
            lastPressedAt = uptime
            if isDown, quietGap >= missedReleaseRecoveryInterval {
                isDown = false
            }
            guard !isDown else { return false }
            isDown = true
            return true
        }
    }

    mutating func reset() {
        isDown = false
        lastPressedAt = .leastNormalMagnitude
    }
}

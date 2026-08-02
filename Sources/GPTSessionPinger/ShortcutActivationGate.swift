import Foundation

/// Collapses duplicate callbacks produced when the same shortcut is observed
/// by both the focused-app and global event paths.
struct ShortcutActivationGate {
    private var lastHandledAt: TimeInterval?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0.2) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldHandle(
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        if let lastHandledAt, uptime - lastHandledAt < minimumInterval {
            return false
        }
        lastHandledAt = uptime
        return true
    }
}

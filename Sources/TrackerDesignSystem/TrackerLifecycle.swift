import Foundation

/// Owns a Foundation timer and always invalidates it when its host is released.
/// Hosts mutate `timer` from their main-actor isolation. The unchecked
/// conformance only permits this cleanup object to invalidate the timer from
/// its nonisolated deinitializer.
public final class TrackerInvalidatingTimer: @unchecked Sendable {
    public var timer: Timer?

    public init() {}

    deinit {
        timer?.invalidate()
    }
}

/// Owns a task that must be cancelled when its host is released.
public final class TrackerCancellableTask: @unchecked Sendable {
    public var task: Task<Void, Never>?

    public init() {}

    deinit {
        task?.cancel()
    }
}

/// Removes a block-based NotificationCenter observation exactly once.
public final class TrackerNotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    public init(center: NotificationCenter = .default, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    public func invalidate() {
        if let token {
            center.removeObserver(token)
            self.token = nil
        }
    }

    deinit {
        invalidate()
    }
}

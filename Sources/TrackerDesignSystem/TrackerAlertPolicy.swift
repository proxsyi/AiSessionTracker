import Foundation

/// One counter owns its baseline and window. A late-arriving counter, missing
/// data, or a settings change must not replay thresholds already passed.
public struct TrackerUsageAlertState {
    public enum Event: Equatable { case threshold(Int), exhausted }
    private var hasBaseline = false
    private var wasEnabled = false
    private var previousThresholds: Set<Int> = []
    private var fired: Set<Int> = []
    private var lastPercent: Int?
    private var lastReset: Date?
    private var wasExhausted = false

    public init() {}

    public mutating func observe(
        percent: Int?, reset: Date?, remaining: Int? = nil, blocked: Bool = false,
        enabled: Bool, thresholds: [Int], now: Date = Date()
    ) -> [Event] {
        guard percent != nil || remaining != nil || blocked else { return [] }
        let selection = Set(thresholds.filter { (1...100).contains($0) })
        let newWindow: Bool
        if let old = lastReset, let reset {
            newWindow = old <= now && reset.timeIntervalSince(old) > 120
        } else {
            newWindow = lastReset == nil && reset == nil
                && (lastPercent ?? 0) - (percent ?? lastPercent ?? 0) > 10
        }
        if newWindow { fired.removeAll() }
        if let reset { lastReset = reset }
        let exhausted = blocked || remaining == 0
        let baseline = !hasBaseline || !wasEnabled || !enabled
        var events: [Event] = []
        if let percent {
            let crossed = selection.filter { percent >= $0 }
            let newlyEnabled = selection.subtracting(previousThresholds)
            if !baseline && lastPercent != nil {
                events = crossed.subtracting(fired).subtracting(newlyEnabled).sorted().map(Event.threshold)
            }
            fired.formUnion(crossed)
            lastPercent = percent
        } else if exhausted && !wasExhausted && !baseline {
            events = [.exhausted]
        }
        hasBaseline = true
        wasEnabled = enabled
        previousThresholds = selection
        wasExhausted = exhausted
        return events
    }
}

public struct TrackerSessionAvailabilityState {
    private var lastPercent: Int?
    private var lastReset: Date?
    public init() {}

    public mutating func observe(percent: Int?, reset: Date?, now: Date = Date()) -> Bool {
        guard let percent else { return false }
        defer { lastPercent = percent; lastReset = reset }
        guard let previous = lastPercent else { return false }
        if previous >= 100 && percent < 100 { return true }
        guard percent < 100, let old = lastReset, old <= now else { return false }
        return reset == nil || reset!.timeIntervalSince(old) > 120
    }
}

public struct TrackerServiceAlertState {
    public enum Level { case operational, degraded, outage }
    private var previous: Level?
    private var reportedProblem = false
    public init() {}

    public mutating func observe(_ level: Level, outages: Bool, degraded: Bool) -> Bool {
        defer { previous = level }
        guard let previous, previous != level else { return false }
        switch level {
        case .outage:
            if outages { reportedProblem = true }
            return outages
        case .degraded:
            if degraded { reportedProblem = true }
            return degraded
        case .operational:
            defer { reportedProblem = false }
            return reportedProblem && (outages || degraded)
        }
    }
}

public enum TrackerPingAlertPolicy {
    public enum Success: Equatable { case pingSent, scheduledPingSent }

    /// A reply proves delivery, not that a new billing window began. Return
    /// only one success alert, even if both success switches are on.
    public static func success(manual: Bool, pingSent: Bool, scheduledPingSent: Bool) -> Success? {
        if !manual && scheduledPingSent { return .scheduledPingSent }
        return pingSent ? .pingSent : nil
    }
}

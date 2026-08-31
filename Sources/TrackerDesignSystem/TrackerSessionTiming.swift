import Foundation

public struct TrackerScheduleTime: Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

public enum TrackerSessionTiming {
    public static func allowsAutomaticPing(now: Date, lastSuccess: Date?) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= 60
    }

    public static func nextScheduledDate(after now: Date, slots: [TrackerScheduleTime], calendar: Calendar = .autoupdatingCurrent) -> Date? {
        slots.filter { (0...23).contains($0.hour) && (0...59).contains($0.minute) }
            .compactMap { slot in
                calendar.nextDate(after: now, matching: DateComponents(hour: slot.hour, minute: slot.minute, second: 0),
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first)
            }.min()
    }

    public static func nextPossibleDate(now: Date, reset: Date?, percent: Int?, lastSuccess: Date?) -> Date {
        // A reported reset remains authoritative after it passes. A later
        // ping in that window must not invent a fresh five-hour countdown.
        if let reset { return max(now, reset) }
        if let percent, percent < 100 { return now }
        if let lastSuccess { return max(now, lastSuccess.addingTimeInterval(5 * 60 * 60)) }
        return now
    }
}

/// One instance per provider: only the calculation and timer implementation
/// are shared, never the saved schedule, pending timer, or countdown state.
@MainActor
public final class TrackerDailyScheduler {
    public var onFire: (() -> Void)?
    public var onNextFireDateChange: ((Date?) -> Void)?
    public private(set) var nextFireDate: Date?
    private let timer = TrackerInvalidatingTimer()
    private let clock: () -> Date
    private let calendar: Calendar
    private var slots: [TrackerScheduleTime] = []
    private(set) var generation = 0

    public init(clock: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.clock = clock
        self.calendar = calendar
    }

    public func schedule(slots: [TrackerScheduleTime]) {
        self.slots = slots
        generation += 1
        timer.timer?.invalidate()
        timer.timer = nil
        let now = clock()
        nextFireDate = TrackerSessionTiming.nextScheduledDate(after: now, slots: slots, calendar: calendar)
        onNextFireDateChange?(nextFireDate)
        guard let nextFireDate else { return }
        let expectedGeneration = generation
        let nextTimer = Timer(timeInterval: max(nextFireDate.timeIntervalSince(now), 0.01), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire(generation: expectedGeneration) }
        }
        RunLoop.main.add(nextTimer, forMode: .common)
        timer.timer = nextTimer
    }

    func fire(generation expectedGeneration: Int) {
        guard expectedGeneration == generation, let due = nextFireDate else { return }
        let isDue = clock() >= due
        // Advance the countdown before network work, even if that work is
        // skipped because another ping already owns execution.
        schedule(slots: slots)
        if isDue { onFire?() }
    }

    public func stop() { schedule(slots: []) }
}

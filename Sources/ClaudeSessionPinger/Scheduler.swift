import Foundation
import TrackerDesignSystem

@MainActor
final class Scheduler {
    private let scheduler = TrackerDailyScheduler()
    var onFire: (() -> Void)?
    var onNextFireDateChange: ((Date?) -> Void)?

    init() {
        scheduler.onFire = { [weak self] in self?.onFire?() }
        scheduler.onNextFireDateChange = { [weak self] in self?.onNextFireDateChange?($0) }
    }

    func nextFireDate(after date: Date = Date(), slots: [ScheduleSlot]) -> Date? {
        TrackerSessionTiming.nextScheduledDate(after: date, slots: slots.map { .init(hour: $0.hour, minute: $0.minute) })
    }

    func schedule(slots: [ScheduleSlot]) {
        scheduler.schedule(slots: slots.map { .init(hour: $0.hour, minute: $0.minute) })
    }

    func stop() {
        scheduler.stop()
    }
}

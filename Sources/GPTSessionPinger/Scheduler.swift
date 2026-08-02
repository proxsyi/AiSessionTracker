import Foundation

final class Scheduler {
    private var timer: Timer?
    var onFire: (() -> Void)?

    func nextFireDate(after date: Date = Date(), slots: [ScheduleSlot]) -> Date? {
        guard !slots.isEmpty else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        var candidates: [Date] = []
        for dayOffset in 0...1 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: date)) else { continue }
            for slot in slots {
                if let candidate = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: dayStart), candidate > date {
                    candidates.append(candidate)
                }
            }
        }
        return candidates.min()
    }

    func schedule(slots: [ScheduleSlot]) {
        timer?.invalidate()
        guard let next = nextFireDate(slots: slots) else { return }
        let interval = max(next.timeIntervalSinceNow, 1)
        let newTimer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.onFire?()
            self?.schedule(slots: slots)
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

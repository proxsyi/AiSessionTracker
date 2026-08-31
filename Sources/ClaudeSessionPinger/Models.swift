import Foundation
import TrackerDesignSystem

struct PingRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let success: Bool
    let summary: String
}

struct ScheduleSlot: Codable, Equatable, Sendable {
    var hour: Int
    var minute: Int
}

enum ScheduleRules {
    static let minimumSpacingMinutes = 5 * 60

    static func validationMessage(for slots: [ScheduleSlot]) -> String? {
        TrackerScheduleRules.validationMessage(slots.map { .init(hour: $0.hour, minute: $0.minute) })
    }

    static func isValid(_ slots: [ScheduleSlot]) -> Bool {
        validationMessage(for: slots) == nil
    }

    static func firstAvailableHour(addingTo slots: [ScheduleSlot]) -> Int? {
        for hour in 0...23 {
            let candidate = slots + [ScheduleSlot(hour: hour, minute: 0)]
            if isValid(candidate) { return hour }
        }
        return nil
    }

    private static func minutesSinceMidnight(_ slot: ScheduleSlot) -> Int {
        slot.hour * 60 + slot.minute
    }
}

enum PingStatus: Equatable {
    case idle
    case sending
    case success
    case failure
}

struct PingOutcome {
    let conversationID: String
    let replyText: String
    let matchedExpected: Bool
}

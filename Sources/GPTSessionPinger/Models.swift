import Foundation

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
        guard !slots.isEmpty else {
            return "Add at least one scheduled session."
        }
        guard slots.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else {
            return "Choose a valid time for every scheduled session."
        }
        guard slots.count > 1 else { return nil }

        let minutes = slots.map(minutesSinceMidnight).sorted()
        for index in minutes.indices {
            let current = minutes[index]
            let next = index == minutes.count - 1 ? minutes[0] + 24 * 60 : minutes[index + 1]
            if next - current < minimumSpacingMinutes {
                return "Scheduled sessions must be at least 5 hours apart, including overnight."
            }
        }
        return nil
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

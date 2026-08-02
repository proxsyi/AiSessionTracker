import Foundation

enum SessionAvailability: Equatable {
    case unavailable
    case availableNow
    case waiting(until: Date)
}

enum SessionAvailabilityResolver {
    static func resolve(
        usage: GPTUsage?,
        model: String,
        availableModels: [String],
        now: Date
    ) -> SessionAvailability {
        if let track = usage?.modelTrack(for: model), track.isBlocked {
            guard let reset = track.resetsAt else { return .unavailable }
            return reset <= now ? .availableNow : .waiting(until: reset)
        }
        if usage?.blockedFeatures.contains(where: { blocked in
            blocked.caseInsensitiveCompare(model) == .orderedSame
        }) == true {
            return .unavailable
        }
        if availableModels.contains(where: { $0.caseInsensitiveCompare(model) == .orderedSame }) {
            return .availableNow
        }
        return .unavailable
    }
}

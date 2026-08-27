import Foundation
import UserNotifications

/// A combined-app-only scheduler for a light Codex prompt. Its state is kept
/// separate from the normal ChatGPT pinger so each service always reuses its
/// own dedicated conversation.
@MainActor
final class CodexSessionPinger: ObservableObject {
    struct ScheduleSlot: Codable, Hashable, Identifiable {
        var hour: Int
        var minute: Int

        var id: String { "\\(hour)-\\(minute)" }
        var dateComponents: DateComponents { DateComponents(hour: hour, minute: minute) }
    }

    private enum Keys {
        static let enabled = "codexSessionPingerEnabled"
        static let model = "codexSessionPingerModel"
        static let reasoningEffort = "codexSessionPingerReasoningEffort"
        static let message = "codexSessionPingerMessage"
        static let conversationID = "codexSessionPingerConversationID"
        static let parentMessageID = "codexSessionPingerParentMessageID"
        static let slots = "codexSessionPingerScheduleSlots"
        static let lastResult = "codexSessionPingerLastResult"
        static let lastSuccess = "codexSessionPingerLastSuccess"
        static let notifyOnFailure = "codexSessionPingerNotifyOnFailure"
        static let notifyOnSuccess = "codexSessionPingerNotifyOnSuccess"
    }

    private static let defaults = UserDefaults(suiteName: "com.proxsyi.sessiontracker") ?? .standard
    private static let minimumSpacing: TimeInterval = 5 * 60 * 60

    @Published var enabled: Bool { didSet { save(); reschedule() } }
    @Published var model: String { didSet { save() } }
    @Published var reasoningEffort: String { didSet { save() } }
    @Published var message: String { didSet { save() } }
    @Published var conversationID: String { didSet { save() } }
    @Published var parentMessageID: String { didSet { save() } }
    @Published var slots: [ScheduleSlot] { didSet { save(); reschedule() } }
    @Published var notifyOnFailure: Bool { didSet { save() } }
    @Published var notifyOnSuccess: Bool { didSet { save() } }
    @Published private(set) var isPinging = false
    @Published private(set) var status: String?
    @Published private(set) var nextFireDate: Date?
    @Published private(set) var lastSuccess: Date?

    private let settings: SettingsStore
    private var timer: Timer?

    init(settings: SettingsStore) {
        self.settings = settings
        let defaults = Self.defaults
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        model = defaults.string(forKey: Keys.model) ?? "gpt-5.4-mini"
        reasoningEffort = defaults.string(forKey: Keys.reasoningEffort) ?? "low"
        message = defaults.string(forKey: Keys.message) ?? "Say 1"
        conversationID = defaults.string(forKey: Keys.conversationID) ?? ""
        parentMessageID = defaults.string(forKey: Keys.parentMessageID) ?? ""
        if let data = defaults.data(forKey: Keys.slots),
           let decoded = try? JSONDecoder().decode([ScheduleSlot].self, from: data),
           Self.validationMessage(for: decoded) == nil {
            slots = decoded
        } else {
            slots = [5, 10, 15, 20].map { ScheduleSlot(hour: $0, minute: 0) }
        }
        status = defaults.string(forKey: Keys.lastResult)
        lastSuccess = defaults.object(forKey: Keys.lastSuccess) as? Date
        notifyOnFailure = defaults.object(forKey: Keys.notifyOnFailure) as? Bool ?? true
        notifyOnSuccess = defaults.object(forKey: Keys.notifyOnSuccess) as? Bool ?? true
        reschedule()
    }

    deinit { timer?.invalidate() }

    var scheduleValidationMessage: String? { Self.validationMessage(for: slots) }

    private static func validationMessage(for slots: [ScheduleSlot]) -> String? {
        let sorted = slots.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        guard !sorted.isEmpty else { return "Add at least one scheduled Codex ping." }
        guard sorted.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else {
            return "Choose a valid time for every scheduled Codex ping."
        }
        guard sorted.count > 1 else { return nil }
        let minutes = sorted.map { $0.hour * 60 + $0.minute }
        for index in minutes.indices {
            let next = index == minutes.count - 1 ? minutes[0] + 24 * 60 : minutes[index + 1]
            if next - minutes[index] < 5 * 60 {
                return "Scheduled Codex pings must be at least 5 hours apart, including overnight."
            }
        }
        return nil
    }

    func pingNow() { Task { await sendPing(manual: true) } }

    func startFreshChat() {
        conversationID = ""
        parentMessageID = ""
        status = "The next Codex ping will use a new dedicated chat."
    }

    func nextPossibleSessionDate(now: Date = Date(), resetDate: Date?) -> Date {
        if let resetDate, resetDate > now { return resetDate }
        if let lastSuccess { return max(now, lastSuccess.addingTimeInterval(Self.minimumSpacing)) }
        return now
    }

    func reschedule() {
        timer?.invalidate()
        guard enabled, scheduleValidationMessage == nil, let next = nextDate(after: Date()) else {
            nextFireDate = nil
            return
        }
        nextFireDate = next
        let timer = Timer(timeInterval: max(next.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.sendPing(manual: false)
                self?.reschedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func nextDate(after date: Date) -> Date? {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: date)
        return (0...1).compactMap { offset in
            guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: day) else { return nil }
            return slots.compactMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: candidateDay) }
                .filter { $0 > date }
                .min()
        }.min()
    }

    private func sendPing(manual: Bool) async {
        guard !isPinging else { return }
        guard settings.isConfigured else {
            status = "Sign in to ChatGPT before sending a Codex ping."
            return
        }
        isPinging = true
        status = nil
        defer { isPinging = false }
        do {
            let auth = try await ChatGPTWebSession.resolve(
                savedCredential: settings.sessionKey,
                accountID: settings.organizationID,
                cookieHeader: settings.effectiveCookieHeader
            )
            let outcome = try await ChatGPTClient.sendPing(
                auth: auth,
                cookieHeader: settings.effectiveCookieHeader,
                model: model,
                reasoningEffort: reasoningEffort,
                message: message,
                conversationID: conversationID,
                parentMessageID: parentMessageID
            )
            conversationID = outcome.conversationID
            parentMessageID = outcome.parentMessageID
            lastSuccess = Date()
            status = manual ? "Codex ping sent in its dedicated chat." : "Scheduled Codex ping sent in its dedicated chat."
            Self.defaults.set(lastSuccess, forKey: Keys.lastSuccess)
            save()
            if !manual && notifyOnSuccess {
                let content = UNMutableNotificationContent()
                content.title = "Scheduled Codex ping sent"
                content.body = "The dedicated Codex chat was updated."
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "codex-session-ping-success", content: content, trigger: nil))
            }
        } catch {
            status = (error as? ChatGPTPingError)?.localizedDescription ?? error.localizedDescription
            save()
            if !manual && notifyOnFailure {
                let content = UNMutableNotificationContent()
                content.title = "Scheduled Codex ping failed"
                content.body = status ?? "Sign in again from Settings and retry."
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "codex-session-ping-failure", content: content, trigger: nil))
            }
        }
    }

    private func save() {
        let defaults = Self.defaults
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(model, forKey: Keys.model)
        defaults.set(reasoningEffort, forKey: Keys.reasoningEffort)
        defaults.set(message, forKey: Keys.message)
        defaults.set(conversationID, forKey: Keys.conversationID)
        defaults.set(parentMessageID, forKey: Keys.parentMessageID)
        defaults.set(notifyOnFailure, forKey: Keys.notifyOnFailure)
        defaults.set(notifyOnSuccess, forKey: Keys.notifyOnSuccess)
        defaults.set(status, forKey: Keys.lastResult)
        if let data = try? JSONEncoder().encode(slots) { defaults.set(data, forKey: Keys.slots) }
    }
}

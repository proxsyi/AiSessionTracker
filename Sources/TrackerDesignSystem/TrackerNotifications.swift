import Foundation
import UserNotifications

public enum TrackerNotificationProvider: String, CaseIterable, Sendable {
    case claude, codex, chatGPT, openAI
    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .chatGPT: return "ChatGPT"
        case .openAI: return "OpenAI"
        }
    }
}

/// Shared delivery for the combined app and both standalone products. macOS
/// remains in charge of permission, Focus, banners, and sound preferences.
@MainActor
public final class TrackerNotifications: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = TrackerNotifications()
    public private(set) var lastError: String?
    private var permissionRequested = false
    public nonisolated static let presentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]

    public static func request(provider: TrackerNotificationProvider, event: String, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = provider.title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "tracker.\(provider.rawValue)"
        content.userInfo = ["provider": provider.rawValue]
        return UNNotificationRequest(identifier: "tracker.\(provider.rawValue).\(event)", content: content, trigger: nil)
    }

    private var hasAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    public func configure() {
        guard hasAppBundle else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    public func requestPermission() {
        guard hasAppBundle, !permissionRequested else { return }
        permissionRequested = true
        configure()
        Task {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            catch { lastError = error.localizedDescription }
        }
    }

    public func send(provider: TrackerNotificationProvider, event: String, title: String, body: String) {
        Task { _ = await deliver(provider: provider, event: event, title: title, body: body) }
    }

    /// nil means macOS accepted the request, not proof that a banner appeared.
    public func deliver(provider: TrackerNotificationProvider, event: String, title: String, body: String) async -> String? {
        guard hasAppBundle else { return "Run the installed app bundle to test notifications." }
        configure()
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .denied {
                let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "this app"
                lastError = "Notifications are off for \(appName). Enable them in System Settings → Notifications."
                return lastError
            }
            if settings.authorizationStatus == .notDetermined,
               try await !center.requestAuthorization(options: [.alert, .sound]) {
                lastError = "Notification permission was not granted."
                return lastError
            }
            try await center.add(Self.request(provider: provider, event: event, title: title, body: body))
            lastError = nil
            return nil
        } catch {
            lastError = "macOS rejected the notification: \(error.localizedDescription)"
            return lastError
        }
    }

    public func sendTest(provider: TrackerNotificationProvider) async -> String {
        let error = await deliver(provider: provider, event: "test", title: "\(provider.title) notification test", body: "Test alert from Session Tracker.")
        return error ?? "Test sent. Focus and macOS notification settings control the banner and sound."
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions)
    }

    /// Opt-in diagnostic exercises the production delivery path and verifies
    /// both provider requests coexist in Notification Center. No usage or
    /// provider preferences are changed, and no account messages are sent.
    public func verifyDelivery() async -> String {
        guard hasAppBundle else { return "{\"passed\":false,\"error\":\"App bundle required\"}" }
        let event = "verification-" + UUID().uuidString
        let providers: [TrackerNotificationProvider] = [.claude, .codex]
        let center = UNUserNotificationCenter.current()
        var results: [[String: Any]] = []
        for provider in providers {
            let error = await deliver(provider: provider, event: event, title: "\(provider.title) notification test", body: "Verifying provider alerts. This is a test, not a usage warning.")
            results.append(["provider": provider.rawValue, "accepted": error == nil, "error": error ?? ""])
        }
        let identifiers = providers.map { "tracker.\($0.rawValue).\(event)" }
        var delivered: Set<String> = []
        for _ in 0..<20 {
            delivered = Set(await center.deliveredNotifications().map { $0.request.identifier })
            if identifiers.allSatisfy(delivered.contains) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let settings = await center.notificationSettings()
        let report: [String: Any] = [
            "passed": identifiers.allSatisfy(delivered.contains), "results": results,
            "deliveredProviders": zip(providers, identifiers).filter { delivered.contains($0.1) }.map { $0.0.rawValue },
            "authorizationStatus": settings.authorizationStatus.rawValue,
            "alertSetting": settings.alertSetting.rawValue, "soundSetting": settings.soundSetting.rawValue
        ]
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"passed\":false}" }
        return text
    }
}

import Combine
import SwiftUI

public enum GPTCombinedTab: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case chatGPT = "ChatGPT"

    public var id: String { rawValue }
}

public struct GPTMenuBarMeterOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Owns the GPT side of the combined app while keeping its cookies, usage
/// history, preferences, and alerts isolated from Claude.
@MainActor
public final class GPTFeatureState: ObservableObject {
    let settings = SettingsStore()
    let history = UsageHistoryStore()
    lazy var appState = AppState(settings: settings, history: history, updatesEnabled: false)
    lazy var codexSessionPinger = CodexSessionPinger(settings: settings, hostAllowsPinging: true)
    private var cancellables = Set<AnyCancellable>()

    public init() {
        _ = appState
        _ = codexSessionPinger
        appState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        codexSessionPinger.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        appState.$usage
            .sink { [weak self] usage in self?.codexSessionPinger.updateUsage(usage) }
            .store(in: &cancellables)
    }

    public var codexWeeklyPercent: Int? {
        guard let weekly = appState.usage?.weeklyTrack,
              settings.isUsageTrackVisible(weekly.preferenceID) else { return nil }
        return weekly.usedPercent
    }

    public var menuBarMeterOptions: [GPTMenuBarMeterOption] {
        var options: [GPTMenuBarMeterOption] = []
        for track in appState.usage?.tracks ?? []
            where track.usedPercent != nil && settings.isUsageTrackVisible(track.preferenceID) {
            let option = GPTMenuBarMeterOption(id: track.preferenceID, title: track.title)
            if !options.contains(where: { $0.id == option.id }) { options.append(option) }
        }
        return options
    }

    public func menuBarPercent(for preferenceID: String) -> Int? {
        guard settings.isUsageTrackVisible(preferenceID) else { return nil }
        return appState.usage?.tracks.first(where: { $0.preferenceID == preferenceID })?.usedPercent
    }

    public var displayedPlan: String? {
        let plan = appState.usage?.planType ?? settings.accountPlanType
        guard !plan.isEmpty else { return nil }
        return plan.replacingOccurrences(of: "_", with: " ").capitalized + " account"
    }

    public var prefersClearGlass: Bool { settings.preferClearGlass }
    public var commandIEnabled: Bool { settings.enableCommandIShortcut }
    public var wakeHelperInstalled: Bool { codexSessionPinger.wakeHelperInstalled }
    public var wakeSupportStatus: String { codexSessionPinger.wakeSupportStatus }
    public var isInstallingWakeSupport: Bool { codexSessionPinger.isInstallingWakeSupport }

    public func refreshIfStale() async {
        await appState.refreshUsageIfStale()
    }

    public func refresh() async {
        await appState.refreshUsage()
    }

    public func sessionTimingSnapshot(now: Date) -> [String: Any] {
        let pinger = codexSessionPinger
        return ["scheduleEnabled": pinger.enabled,
            "slots": pinger.slots.map { String(format: "%02d:%02d", $0.hour, $0.minute) },
            "nextScheduled": pinger.nextFireDate?.timeIntervalSince1970 as Any? ?? NSNull(),
            "scheduledSeconds": pinger.nextFireDate.map { max(0, $0.timeIntervalSince(now)) } as Any? ?? NSNull(),
            "nextPossible": pinger.nextPossibleSessionDate(now: now).timeIntervalSince1970,
            "possibleSeconds": max(0, pinger.nextPossibleSessionDate(now: now).timeIntervalSince(now)),
            "reportedReset": appState.usage?.rollingFiveHourResetsAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "usageLoaded": appState.usage != nil]
    }

    /// Opt-in signed-app diagnostic. It never creates or resets a chat and
    /// reports only identifiers and results, never account credentials.
    public func verifyCodexChatReuse() async -> String {
        let originalID = codexSessionPinger.conversationID
        let originalChatGPTID = settings.pingConversationID
        guard !originalID.isEmpty, originalID != originalChatGPTID else {
            return "{\"passed\":false,\"error\":\"A distinct existing Codex Work chat is required\"}"
        }
        var results: [[String: Any]] = []
        for _ in 0..<2 {
            let started = Date()
            let status = await codexSessionPinger.testConnection()
            let record = codexSessionPinger.records.last
            let passed = record?.success == true && (record?.date ?? .distantPast) >= started
                && record?.conversationID == originalID
                && codexSessionPinger.conversationID == originalID
                && record?.model?.hasSuffix("-wm") == true
                && settings.pingConversationID == originalChatGPTID
            results.append(["passed": passed, "conversationID": codexSessionPinger.conversationID, "status": status])
            if !passed { break }
        }
        let report: [String: Any] = [
            "passed": results.count == 2 && results.allSatisfy { $0["passed"] as? Bool == true },
            "originalConversationID": originalID,
            "chatGPTConversationUnchanged": settings.pingConversationID == originalChatGPTID,
            "pings": results
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{\"passed\":false}" }
        return json
    }

    public func refreshWakeSupportState() {
        codexSessionPinger.refreshWakeSupportState()
    }

    public func setLaunchAtLoginPreference(_ enabled: Bool) {
        settings.launchAtLogin = enabled
    }

    public func configureWindowActions(
        close: @escaping () -> Void,
        togglePopover: @escaping () -> Void
    ) {
        appState.closeSettingsWindow = close
        appState.requestTogglePopover = togglePopover
    }

    public func saveAndCloseSettings() {
        appState.requestSaveAndCloseSettings?()
    }
}

@MainActor
public struct GPTCombinedMenuContent: View {
    @ObservedObject private var feature: GPTFeatureState
    private let tab: GPTCombinedTab

    public init(feature: GPTFeatureState, tab: GPTCombinedTab) {
        self.feature = feature
        self.tab = tab
    }

    public var body: some View {
        MenuBarContentView(embeddedTab: tab == .codex ? .codex : .chatGPT)
            .environmentObject(feature.settings)
            .environmentObject(feature.history)
            .environmentObject(feature.appState)
            .environmentObject(feature.codexSessionPinger)
    }
}

@MainActor
public struct GPTCombinedSettingsContent: View {
    @ObservedObject private var feature: GPTFeatureState
    private let topLeadingInset: CGFloat
    private let tab: GPTCombinedTab
    private let serviceVisibility: Binding<Bool>?
    private let isActive: Bool
    private let onOpenSystemSettings: (() -> Void)?

    public init(
        feature: GPTFeatureState,
        tab: GPTCombinedTab,
        topLeadingInset: CGFloat,
        serviceVisibility: Binding<Bool>? = nil,
        isActive: Bool = true,
        onOpenSystemSettings: (() -> Void)? = nil
    ) {
        self.feature = feature
        self.tab = tab
        self.topLeadingInset = topLeadingInset
        self.serviceVisibility = serviceVisibility
        self.isActive = isActive
        self.onOpenSystemSettings = onOpenSystemSettings
    }

    public var body: some View {
        SettingsView(
            topLeadingInset: topLeadingInset,
            saveOnDisappear: true,
            showsUpdateControls: false,
            combinedMode: true,
            settingsScope: tab == .codex ? .codex : .chatGPT,
            serviceVisibility: serviceVisibility,
            isActive: isActive,
            onOpenSystemSettings: onOpenSystemSettings
        )
            .environmentObject(feature.settings)
            .environmentObject(feature.history)
            .environmentObject(feature.appState)
            .environmentObject(feature.codexSessionPinger)
    }
}

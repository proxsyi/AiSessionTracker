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
    lazy var codexSessionPinger = CodexSessionPinger(settings: settings)
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

    public func refreshIfStale() async {
        await appState.refreshUsageIfStale()
    }

    public func refresh() async {
        await appState.refreshUsage()
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

    public init(feature: GPTFeatureState, tab: GPTCombinedTab, topLeadingInset: CGFloat, serviceVisibility: Binding<Bool>? = nil) {
        self.feature = feature
        self.tab = tab
        self.topLeadingInset = topLeadingInset
        self.serviceVisibility = serviceVisibility
    }

    public var body: some View {
        SettingsView(
            topLeadingInset: topLeadingInset,
            saveOnDisappear: true,
            showsUpdateControls: false,
            combinedMode: true,
            settingsScope: tab == .codex ? .codex : .chatGPT,
            serviceVisibility: serviceVisibility
        )
            .environmentObject(feature.settings)
            .environmentObject(feature.history)
            .environmentObject(feature.appState)
            .environmentObject(feature.codexSessionPinger)
    }
}

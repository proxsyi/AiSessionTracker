import AppKit
import GPTTrackerFeature
import SwiftUI

enum CombinedServiceTab: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case chatGPT = "ChatGPT"

    var id: String { rawValue }
}

enum ClaudeMenuBarMeterSource: String, CaseIterable, Identifiable {
    case session
    case weekly
    case fable5

    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: return "Claude session (5 hour)"
        case .weekly: return "Claude weekly (7 day)"
        case .fable5: return "Claude Fable 5 weekly"
        }
    }
}

@MainActor
final class CombinedSelectionStore: ObservableObject {
    private static let selectedTabKey = "combinedSelectedServiceTab"
    private static let claudeVisibleKey = "combinedClaudeVisible"
    private static let codexVisibleKey = "combinedCodexVisible"
    private static let chatGPTVisibleKey = "combinedChatGPTVisible"
    private static let menuBarIconVisibleKey = "combinedMenuBarIconVisible"
    private static let claudePercentVisibleKey = "combinedClaudePercentVisible"
    private static let gptPercentVisibleKey = "combinedGPTPercentVisible"
    private static let claudeMeterSourceKey = "combinedClaudeMeterSource"
    private static let gptMeterSourceKey = "combinedGPTMeterSource"

    @Published var selectedTab: CombinedServiceTab {
        didSet {
            ensureSelectedTabIsVisible()
            UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.selectedTabKey)
        }
    }
    @Published var claudeVisible: Bool { didSet { saveVisibility() } }
    @Published var codexVisible: Bool { didSet { saveVisibility() } }
    @Published var chatGPTVisible: Bool { didSet { saveVisibility() } }
    @Published var menuBarIconVisible: Bool { didSet { saveMenuBarPresentation() } }
    @Published var claudePercentVisible: Bool { didSet { saveMenuBarPresentation() } }
    @Published var gptPercentVisible: Bool { didSet { saveMenuBarPresentation() } }
    @Published var claudeMeterSource: ClaudeMenuBarMeterSource {
        didSet { UserDefaults.standard.set(claudeMeterSource.rawValue, forKey: Self.claudeMeterSourceKey) }
    }
    @Published var gptMeterSourceID: String {
        didSet { UserDefaults.standard.set(gptMeterSourceID, forKey: Self.gptMeterSourceKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        selectedTab = CombinedServiceTab(
            rawValue: defaults.string(forKey: Self.selectedTabKey) ?? ""
        ) ?? .claude
        claudeVisible = defaults.object(forKey: Self.claudeVisibleKey) as? Bool ?? true
        codexVisible = defaults.object(forKey: Self.codexVisibleKey) as? Bool ?? true
        chatGPTVisible = defaults.object(forKey: Self.chatGPTVisibleKey) as? Bool ?? true
        menuBarIconVisible = defaults.object(forKey: Self.menuBarIconVisibleKey) as? Bool ?? true
        claudePercentVisible = defaults.object(forKey: Self.claudePercentVisibleKey) as? Bool ?? true
        gptPercentVisible = defaults.object(forKey: Self.gptPercentVisibleKey) as? Bool ?? true
        claudeMeterSource = ClaudeMenuBarMeterSource(
            rawValue: defaults.string(forKey: Self.claudeMeterSourceKey) ?? ""
        ) ?? .session
        gptMeterSourceID = defaults.string(forKey: Self.gptMeterSourceKey) ?? "codex-weekly"
        ensureSelectedTabIsVisible()
        ensureMenuBarItemIsReachable()
    }

    var visibleTabs: [CombinedServiceTab] {
        CombinedServiceTab.allCases.filter(isVisible)
    }

    func isVisible(_ tab: CombinedServiceTab) -> Bool {
        switch tab {
        case .claude: return claudeVisible
        case .codex: return codexVisible
        case .chatGPT: return chatGPTVisible
        }
    }

    private func saveVisibility() {
        // A tracker with no visible dashboard cannot be opened or configured.
        if !claudeVisible && !codexVisible && !chatGPTVisible { claudeVisible = true }
        let defaults = UserDefaults.standard
        defaults.set(claudeVisible, forKey: Self.claudeVisibleKey)
        defaults.set(codexVisible, forKey: Self.codexVisibleKey)
        defaults.set(chatGPTVisible, forKey: Self.chatGPTVisibleKey)
        ensureSelectedTabIsVisible()
    }

    private func saveMenuBarPresentation() {
        ensureMenuBarItemIsReachable()
        let defaults = UserDefaults.standard
        defaults.set(menuBarIconVisible, forKey: Self.menuBarIconVisibleKey)
        defaults.set(claudePercentVisible, forKey: Self.claudePercentVisibleKey)
        defaults.set(gptPercentVisible, forKey: Self.gptPercentVisibleKey)
    }

    private func ensureMenuBarItemIsReachable() {
        if !menuBarIconVisible && !claudePercentVisible && !gptPercentVisible {
            menuBarIconVisible = true
        }
    }

    func claudePercent(from usage: ClaudeUsage?) -> Int? {
        switch claudeMeterSource {
        case .session: return usage?.sessionPercent
        case .weekly: return usage?.weeklyPercent
        case .fable5: return usage?.fable5Percent
        }
    }

    func gptSourceIsVisible() -> Bool {
        if gptMeterSourceID.hasPrefix("model-")
            || gptMeterSourceID.hasPrefix("feature-")
            || gptMeterSourceID.hasPrefix("chatgpt-") {
            return chatGPTVisible
        }
        return codexVisible
    }

    private func ensureSelectedTabIsVisible() {
        if !isVisible(selectedTab), let firstVisible = visibleTabs.first {
            selectedTab = firstVisible
        }
    }
}

struct CombinedMenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var selection: CombinedSelectionStore
    @ObservedObject var gptFeature: GPTFeatureState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            serviceTabs
            ScrollView {
                selectedContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(height: 410)
            actionsSection
        }
        .claudeGlassContainer(spacing: 12)
        .environment(\.claudeClearGlass, settings.preferClearGlass)
        .padding(16)
        .frame(width: 360)
        .background(WindowGlassBackground(clearGlass: settings.preferClearGlass).ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusBarController.dualUsageImage(
                claudePercent: selection.claudePercent(from: appState.usage),
                gptPercent: gptFeature.menuBarPercent(for: selection.gptMeterSourceID)
            ))
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Session Tracker")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ClaudeTheme.textPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(ClaudeTheme.textSecondary)
            }
            Spacer()
        }
    }

    private var headerSubtitle: String {
        switch selection.selectedTab {
        case .claude: return claudeAccountLabel
        case .codex: return gptFeature.displayedPlan ?? "Codex usage"
        case .chatGPT: return gptFeature.displayedPlan ?? "ChatGPT usage"
        }
    }

    private var claudeAccountLabel: String {
        guard let rawPlan = appState.usage?.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPlan.isEmpty else { return "Claude account" }
        let plan = rawPlan
            .replacingOccurrences(of: "claude_", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return "\(plan) account"
    }

    private var serviceTabs: some View {
        Picker("Service", selection: $selection.selectedTab) {
            ForEach(selection.visibleTabs) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection.selectedTab {
        case .claude:
            MenuBarContentView(embedded: true)
        case .codex:
            GPTCombinedMenuContent(feature: gptFeature, tab: .codex)
        case .chatGPT:
            GPTCombinedMenuContent(feature: gptFeature, tab: .chatGPT)
        }
    }

    private var actionsSection: some View {
        HStack {
            Button("Settings") {
                appState.requestShowSettings?()
                appState.requestClosePopover?()
            }
            .claudeGhostButton()
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .claudeGhostButton()
        }
    }
}

struct CombinedSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var selection: CombinedSelectionStore
    @ObservedObject var gptFeature: GPTFeatureState
    @State private var showingMenuBarSettings = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if selection.selectedTab == .claude {
                    SettingsView(
                        topLeadingInset: 0,
                        saveOnDisappear: true,
                        frameWidth: 500,
                        frameHeight: 640,
                        showsUpdateControls: false,
                        serviceVisibility: $selection.claudeVisible,
                        serviceDisplayName: "Claude"
                    )
                } else {
                    GPTCombinedSettingsContent(
                        feature: gptFeature,
                        tab: selection.selectedTab == .codex ? .codex : .chatGPT,
                        topLeadingInset: 0,
                        serviceVisibility: selection.selectedTab == .codex ? $selection.codexVisible : $selection.chatGPTVisible
                    )
                }
            }
            .padding(.top, 52)

            HStack(spacing: 8) {
                Picker("Settings service", selection: $selection.selectedTab) {
                    ForEach(CombinedServiceTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    showingMenuBarSettings = true
                } label: {
                    Label("Menu Bar", systemImage: "menubar.rectangle")
                }
                .claudeGhostButton()
            }
            .frame(width: 484, height: 34)
            .padding(8)
        }
        .frame(width: 500, height: 700)
        .background(WindowGlassBackground(clearGlass: true).ignoresSafeArea())
        .onAppear {
            gptFeature.configureWindowActions(
                close: { appState.closeSettingsWindow?() },
                togglePopover: { appState.requestTogglePopover?() }
            )
        }
        .sheet(isPresented: $showingMenuBarSettings) {
            menuBarSettingsSheet
        }
    }

    private var menuBarSettingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Menu Bar")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { showingMenuBarSettings = false }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show combined star-and-ring icon", isOn: $selection.menuBarIconVisible)

                Divider()

                Toggle("Show Claude percentage", isOn: $selection.claudePercentVisible)
                Picker("Claude percentage source", selection: $selection.claudeMeterSource) {
                    ForEach(ClaudeMenuBarMeterSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .disabled(!selection.claudePercentVisible && !selection.menuBarIconVisible)

                Divider()

                Toggle("Show GPT percentage", isOn: $selection.gptPercentVisible)
                if gptMenuBarMeterOptions.isEmpty {
                    Text("No visible GPT percentage counters are currently reported.")
                        .font(.system(size: 11))
                        .foregroundColor(ClaudeTheme.textSecondary)
                } else {
                    Picker("GPT percentage source", selection: $selection.gptMeterSourceID) {
                        ForEach(gptMenuBarMeterOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .disabled(!selection.gptPercentVisible && !selection.menuBarIconVisible)
                }
            }
            .padding(16)
            .glassPanel()

            Text("The icon and text use the selected real usage counters. If a selected counter is not reported by the account, that part stays hidden instead of being estimated. At least one icon or percentage remains enabled so the app is always reachable.")
                .font(.system(size: 11))
                .foregroundColor(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
        .background(WindowGlassBackground(clearGlass: true).ignoresSafeArea())
        .onAppear { selectFirstAvailableGPTMeterIfNeeded() }
        .onChange(of: gptMenuBarMeterOptions) { _ in selectFirstAvailableGPTMeterIfNeeded() }
    }

    private var gptMenuBarMeterOptions: [GPTMenuBarMeterOption] {
        gptFeature.menuBarMeterOptions
    }

    private func selectFirstAvailableGPTMeterIfNeeded() {
        guard !gptMenuBarMeterOptions.contains(where: { $0.id == selection.gptMeterSourceID }),
              let first = gptMenuBarMeterOptions.first else { return }
        selection.gptMeterSourceID = first.id
    }
}

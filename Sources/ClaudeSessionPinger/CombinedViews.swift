import AppKit
import GPTTrackerFeature
import SwiftUI
import TrackerDesignSystem

enum CombinedServiceTab: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case chatGPT = "ChatGPT"

    var id: String { rawValue }
}

private enum CombinedSettingsSection: String, CaseIterable, Identifiable {
    case system = "System"
    case claude = "Claude"
    case codex = "Codex"
    case chatGPT = "ChatGPT"

    var id: String { rawValue }
}

enum ClaudeMenuBarMeterSource: String, CaseIterable, Identifiable {
    case session
    case weekly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: return "Claude session (5 hour)"
        case .weekly: return "Claude weekly (7 day)"
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
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var selection: CombinedSelectionStore
    @ObservedObject var gptFeature: GPTFeatureState
    @State private var showingMenuBarSettings = false
    @State private var selectedSection: CombinedSettingsSection = .claude
    @State private var selectedSettingsTab: TrackerSettingsTab = .general
    @State private var initializedSelection = false
    @State private var launchAtLogin = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                systemSettings
                    .settingsLayer(isActive: selectedSection == .system)

                SettingsView(
                    topLeadingInset: 0,
                    saveOnDisappear: true,
                    frameWidth: 500,
                    frameHeight: 640,
                    showsUpdateControls: false,
                    serviceVisibility: $selection.claudeVisible,
                    serviceDisplayName: "Claude",
                    isActive: selectedSection == .claude,
                    onOpenSystemSettings: { selectedSection = .system },
                    selectedTab: $selectedSettingsTab
                )
                .settingsLayer(isActive: selectedSection == .claude)

                GPTCombinedSettingsContent(
                    feature: gptFeature,
                    tab: .codex,
                    topLeadingInset: 0,
                    serviceVisibility: $selection.codexVisible,
                    isActive: selectedSection == .codex,
                    onOpenSystemSettings: { selectedSection = .system },
                    selectedTab: $selectedSettingsTab
                )
                .settingsLayer(isActive: selectedSection == .codex)

                GPTCombinedSettingsContent(
                    feature: gptFeature,
                    tab: .chatGPT,
                    topLeadingInset: 0,
                    serviceVisibility: $selection.chatGPTVisible,
                    isActive: selectedSection == .chatGPT,
                    selectedTab: $selectedSettingsTab
                )
                .settingsLayer(isActive: selectedSection == .chatGPT)
            }
            .padding(.top, 52)

            HStack(spacing: 8) {
                Picker("Settings service", selection: $selectedSection) {
                    ForEach(CombinedSettingsSection.allCases) { section in
                        Text(section.rawValue).tag(section)
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
            if !initializedSelection {
                selectedSection = settingsSection(for: selection.selectedTab)
                initializedSelection = true
            }
            gptFeature.configureWindowActions(
                close: { appState.closeSettingsWindow?() },
                togglePopover: { appState.requestTogglePopover?() }
            )
            refreshWakeSetupState()
            launchAtLogin = LoginItemManager.isEnabled
        }
        .onChange(of: selectedSection) { section in
            if let service = serviceTab(for: section) { selection.selectedTab = service }
            refreshWakeSetupState()
        }
        .onChange(of: appState.isInstallingWakeSupport) { installing in
            if !installing { refreshWakeSetupState() }
        }
        .sheet(isPresented: $showingMenuBarSettings) {
            menuBarSettingsSheet
        }
    }

    private var systemSettings: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                Text("System setup")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundColor(ClaudeTheme.textPrimary)
            .padding(.horizontal, 20)
            .frame(height: 58)

            Divider()

            ScrollView {
                TrackerSettingsCard(clearGlass: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(text: "Wake support")
                        Label(
                            appState.wakeHelperInstalled ? "Ready for Claude and Codex" : "Setup required",
                            systemImage: appState.wakeHelperInstalled ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(appState.wakeHelperInstalled ? ClaudeTheme.accent : .orange)

                        if !appState.wakeHelperInstalled {
                            Button(appState.isInstallingWakeSupport ? "Installing…" : "Install wake support") {
                                appState.installWakeSupport()
                            }
                            .claudePrimaryButton()
                            .disabled(appState.isInstallingWakeSupport)
                            .help("Installs one restricted helper used by both Claude and Codex schedules. Each provider is enabled separately in its App settings.")
                        }

                        if appState.isInstallingWakeSupport {
                            Text(appState.wakeSupportStatus)
                                .font(.system(size: 10))
                                .foregroundColor(ClaudeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()
                        HStack {
                            Text("Launch at login")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Toggle("", isOn: $launchAtLogin)
                                .labelsHidden()
                                .toggleStyle(TrackerGlassToggleStyle(accent: ClaudeTheme.accent, clearGlass: true))
                        }
                        .help("Starts Session Tracker automatically after you sign in to this Mac.")
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)

            Divider()
            TrackerSettingsFooter(
                accent: ClaudeTheme.accent,
                testTitle: "Refresh status",
                onTest: refreshWakeSetupState,
                onCancel: { appState.closeSettingsWindow?() },
                onSave: {
                    settings.launchAtLogin = launchAtLogin
                    gptFeature.setLaunchAtLoginPreference(launchAtLogin)
                    LoginItemManager.setEnabled(launchAtLogin)
                    appState.closeSettingsWindow?()
                }
            ) { EmptyView() }
        }
        .frame(width: 500, height: 640)
        .background(WindowGlassBackground(clearGlass: true).ignoresSafeArea())
    }

    private func refreshWakeSetupState() {
        appState.refreshWakeTestResult()
        gptFeature.refreshWakeSupportState()
    }

    private func settingsSection(for service: CombinedServiceTab) -> CombinedSettingsSection {
        switch service {
        case .claude: return .claude
        case .codex: return .codex
        case .chatGPT: return .chatGPT
        }
    }

    private func serviceTab(for section: CombinedSettingsSection) -> CombinedServiceTab? {
        switch section {
        case .system: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .chatGPT: return .chatGPT
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
            .help("Uses only real account-reported counters. Unavailable counters stay hidden, and at least one menu-bar element remains enabled.")
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

private extension View {
    func settingsLayer(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

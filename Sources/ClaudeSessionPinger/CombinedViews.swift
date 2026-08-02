import AppKit
import GPTTrackerFeature
import SwiftUI

enum CombinedServiceTab: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case chatGPT = "ChatGPT"

    var id: String { rawValue }
}

@MainActor
final class CombinedSelectionStore: ObservableObject {
    private static let selectedTabKey = "combinedSelectedServiceTab"
    private static let claudeVisibleKey = "combinedClaudeVisible"
    private static let codexVisibleKey = "combinedCodexVisible"
    private static let chatGPTVisibleKey = "combinedChatGPTVisible"

    @Published var selectedTab: CombinedServiceTab {
        didSet {
            ensureSelectedTabIsVisible()
            UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.selectedTabKey)
        }
    }
    @Published var claudeVisible: Bool { didSet { saveVisibility() } }
    @Published var codexVisible: Bool { didSet { saveVisibility() } }
    @Published var chatGPTVisible: Bool { didSet { saveVisibility() } }

    init() {
        let defaults = UserDefaults.standard
        selectedTab = CombinedServiceTab(
            rawValue: defaults.string(forKey: Self.selectedTabKey) ?? ""
        ) ?? .claude
        claudeVisible = defaults.object(forKey: Self.claudeVisibleKey) as? Bool ?? true
        codexVisible = defaults.object(forKey: Self.codexVisibleKey) as? Bool ?? true
        chatGPTVisible = defaults.object(forKey: Self.chatGPTVisibleKey) as? Bool ?? true
        ensureSelectedTabIsVisible()
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
            .frame(maxHeight: 555)
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
                claudePercent: appState.usage?.sessionPercent,
                gptPercent: gptFeature.codexWeeklyPercent
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
            if let summary = selectedUsageSummary {
                Text(summary)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(ClaudeTheme.textPrimary)
            }
        }
    }

    private var headerSubtitle: String {
        switch selection.selectedTab {
        case .claude: return "Claude session usage and pinger"
        case .codex: return gptFeature.displayedPlan ?? "Codex usage"
        case .chatGPT: return gptFeature.displayedPlan ?? "ChatGPT usage"
        }
    }

    private var selectedUsageSummary: String? {
        switch selection.selectedTab {
        case .claude:
            return appState.usage?.sessionPercent.map { "\($0)% session" }
        case .codex:
            return gptFeature.codexWeeklyPercent.map { "\($0)% weekly" }
        case .chatGPT:
            return nil
        }
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

            Picker("Settings service", selection: $selection.selectedTab) {
                ForEach(CombinedServiceTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
    }
}

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

    @Published var selectedTab: CombinedServiceTab {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.selectedTabKey) }
    }

    init() {
        selectedTab = CombinedServiceTab(
            rawValue: UserDefaults.standard.string(forKey: Self.selectedTabKey) ?? ""
        ) ?? .claude
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
            ForEach(CombinedServiceTab.allCases) { tab in
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

private enum CombinedSettingsSide: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case gpt = "GPT"
    var id: String { rawValue }
}

struct CombinedSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var selection: CombinedSelectionStore
    @ObservedObject var gptFeature: GPTFeatureState

    private var settingsSide: Binding<CombinedSettingsSide> {
        Binding(
            get: { selection.selectedTab == .claude ? .claude : .gpt },
            set: { newSide in
                selection.selectedTab = newSide == .claude ? .claude : .codex
            }
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if settingsSide.wrappedValue == .claude {
                SettingsView(
                    topLeadingInset: 126,
                    saveOnDisappear: true,
                    frameWidth: 500,
                    frameHeight: 640,
                    showsUpdateControls: false
                )
            } else {
                GPTCombinedSettingsContent(feature: gptFeature, topLeadingInset: 126)
            }

            Picker("Settings service", selection: settingsSide) {
                ForEach(CombinedSettingsSide.allCases) { side in
                    Text(side.rawValue).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 118, height: 34)
            .padding(.leading, 8)
            .padding(.top, 8)
        }
        .frame(width: 500, height: 640)
        .onAppear {
            gptFeature.configureWindowActions(
                close: { appState.closeSettingsWindow?() },
                togglePopover: { appState.requestTogglePopover?() }
            )
        }
    }
}

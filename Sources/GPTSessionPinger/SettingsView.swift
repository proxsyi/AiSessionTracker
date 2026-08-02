import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case usage = "Usage"
    case alerts = "Alerts"
    case app = "App"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .usage: return "chart.line.uptrend.xyaxis"
        case .alerts: return "bell.fill"
        case .app: return "gearshape.fill"
        }
    }
}

private struct UsageSettingRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let scope: GPTUsageScope
    let isReported: Bool
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var history: UsageHistoryStore
    let topLeadingInset: CGFloat
    let saveOnDisappear: Bool
    let showsUpdateControls: Bool
    let combinedMode: Bool
    let settingsScope: UsageDisplayTab?
    let serviceVisibility: Binding<Bool>?

    @State private var selectedTab: SettingsTab = .general
    @State private var showCategoryTabs = true
    @State private var showHistoryChart = true
    @State private var automaticallyShowNewUsageTracks = true
    @State private var hiddenTrackIDs: Set<String> = []
    @State private var alertTrackIDs: Set<String> = []
    @State private var weeklyThresholds: Set<Int> = []
    @State private var additionalAlertThreshold = 90
    @State private var enableCommandIShortcut = true
    @State private var preferClearGlass = true
    @State private var launchAtLogin = false
    @State private var notifyOnServiceOutage = true
    @State private var notifyOnServiceDegraded = true
    @State private var autoUpdate = true
    @State private var showingLogin = false
    @State private var showKeys = false
    @State private var isClearingLogin = false

    init(
        topLeadingInset: CGFloat = 0,
        saveOnDisappear: Bool = false,
        showsUpdateControls: Bool = true,
        combinedMode: Bool = false,
        settingsScope: UsageDisplayTab? = nil,
        serviceVisibility: Binding<Bool>? = nil
    ) {
        self.topLeadingInset = topLeadingInset
        self.saveOnDisappear = saveOnDisappear
        self.showsUpdateControls = showsUpdateControls
        self.combinedMode = combinedMode
        self.settingsScope = settingsScope
        self.serviceVisibility = serviceVisibility
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.leading, 8 + topLeadingInset)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                tabContent.padding(20)
            }
            .scrollIndicators(.hidden)
            .clipped()
            Divider()
            footer.background(WindowGlassBackground(clearGlass: preferClearGlass))
        }
        .environment(\.gptClearGlass, preferClearGlass)
        .frame(width: 500, height: 640)
        .background(WindowGlassBackground(clearGlass: preferClearGlass).ignoresSafeArea())
        .onAppear {
            loadCurrentValues()
            appState.requestSaveAndCloseSettings = { save(showPopoverAfterClose: true) }
        }
        .onDisappear {
            if saveOnDisappear { save(closeWindow: false) }
            appState.requestSaveAndCloseSettings = nil
        }
        .sheet(isPresented: $showingLogin) {
            CookieLoginSheet { capture in handleLoginCapture(capture) }
        }
    }

    private var tabBar: some View {
        GeometryReader { proxy in
            if #available(macOS 26.0, *) {
                let railGlass = preferClearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
                let tabCount = CGFloat(SettingsTab.allCases.count)
                let indicatorWidth = max((proxy.size.width - 8) / tabCount, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(GPTTheme.accent.opacity(0.88))
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75))
                        .frame(width: indicatorWidth, height: 30)
                        .offset(x: indicatorWidth * CGFloat(selectedTabIndex))
                        .animation(.easeInOut(duration: 0.20), value: selectedTab)
                    HStack(spacing: 0) {
                        ForEach(SettingsTab.allCases) { tab in
                            Button { selectTab(tab) } label: {
                                Label(tab.rawValue, systemImage: tab.symbol)
                                    .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .contentShape(Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selectedTab == tab ? Color.white : GPTTheme.textSecondary)
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule(style: .continuous))
                .glassEffect(railGlass, in: Capsule(style: .continuous))
                .simultaneousGesture(tabDragGesture(width: proxy.size.width))
            } else {
                Picker("Settings section", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .frame(height: 42)
    }

    private var selectedTabIndex: Int { SettingsTab.allCases.firstIndex(of: selectedTab) ?? 0 }

    private func selectTab(_ tab: SettingsTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
    }

    private func tabDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3).onChanged { value in
            let available = max(width - 8, 1)
            let x = min(max(value.location.x - 4, 0), available - 1)
            let index = min(Int(x / (available / CGFloat(SettingsTab.allCases.count))), SettingsTab.allCases.count - 1)
            selectTab(SettingsTab.allCases[index])
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selectedTab {
            case .general:
                accountSection.padding(14).glassPanel()
                displaySection.padding(14).glassPanel()
            case .usage:
                trackedUsageSection.padding(14).glassPanel()
                usageExplanationSection.padding(14).glassPanel()
            case .alerts:
                if settingsScope != .chatGPT {
                    weeklyAlertsSection.padding(14).glassPanel()
                }
                optionalAlertsSection.padding(14).glassPanel()
                serviceAlertsSection.padding(14).glassPanel()
            case .app:
                appSection.padding(14).glassPanel()
                if showsUpdateControls {
                    updatesSection.padding(14).glassPanel()
                }
            }
        }
        .gptGlassContainer()
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Account")
            if settings.isConfigured {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ChatGPT connected").font(.system(size: 12, weight: .semibold)).foregroundColor(GPTTheme.textPrimary)
                        Text("Plan: \(planName)").font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
                    }
                    Spacer()
                    Button("Switch account") { showingLogin = true }.gptPrimaryButton()
                    Button(isClearingLogin ? "Clearing…" : "Log out") { clearLogin() }
                        .gptGhostButton().disabled(isClearingLogin)
                }
            } else {
                Text("Sign in through the private in-app browser to read this account's usage counters.")
                    .font(.system(size: 11)).foregroundColor(GPTTheme.textSecondary)
                Button("Log in to ChatGPT") { showingLogin = true }.gptPrimaryButton()
            }
            Button { showKeys.toggle() } label: {
                Label("Connection details", systemImage: showKeys ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(GPTTheme.textSecondary)
            if showKeys {
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("Access token", settings.maskedSessionKey.isEmpty ? "Not stored" : settings.maskedSessionKey)
                    detailRow("Account ID", settings.organizationID.isEmpty ? "Not reported" : settings.organizationID)
                    detailRow("App browser cookies", settings.cookieHeader.isEmpty ? "Not stored" : "Stored securely in Keychain")
                }
            }
            Text("Logging out clears this app's Keychain login and embedded-browser data. Safari and Claude Session Pinger are unaffected.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(text: "Menu display")
            if let serviceVisibility, let settingsScope {
                toggleRow("Show \(settingsScope.rawValue) dashboard", isOn: serviceVisibility)
                Text("Hiding it removes its dashboard and menu-bar meter. You can turn it back on from the service selector above.")
                    .font(.system(size: 10))
                    .foregroundColor(GPTTheme.textSecondary)
            }
            if !combinedMode {
                toggleRow("Show Codex and ChatGPT tabs", isOn: $showCategoryTabs)
            }
            if settingsScope != .chatGPT {
                toggleRow("Show Codex weekly trend", isOn: $showHistoryChart)
            }
            toggleRow("Automatically show newly discovered limits", isOn: $automaticallyShowNewUsageTracks)
            Text(displayExplanation)
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private var trackedUsageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(text: "Tracked usage")
            Text("Every known or account-reported counter can be hidden independently. Rolling windows remain separate from weekly, monthly, credit and remaining-task limits.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            groupTitle(settingsScope?.rawValue ?? "Codex and ChatGPT")
            ForEach(scopedUsageRows) { row in
                usageToggle(row)
            }
        }
    }

    private var usageExplanationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(text: "Tracking behavior")
            Text("The tracker displays exactly what ChatGPT reports. It never invents a percentage or substitutes one window for another.")
                .font(.system(size: 11)).foregroundColor(GPTTheme.textPrimary)
            Text(usageTrackingExplanation)
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private var weeklyAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Codex weekly usage alerts")
            toggleRow("Enable weekly usage alerts", isOn: alertBinding(for: "codex-weekly"))
            thresholdButtons(selection: $weeklyThresholds)
            Text("Choose every threshold you want. Each sends once per reported weekly reset window; the first refresh after launch is only a baseline.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private var optionalAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Per-limit usage alerts")
            Text("Turn on exactly the Codex or ChatGPT counters you want notifications for. These are off by default and remain separate from weekly alerts.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            Picker("Alert threshold", selection: $additionalAlertThreshold) {
                ForEach(SettingsStore.availableThresholds, id: \.self) { Text("\($0)%").tag($0) }
            }
            .pickerStyle(.menu)
            Text("Enabled percentage-based limits notify at this threshold. Exhausted remaining-use limits notify once when they become unavailable.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            ForEach(scopedUsageRows.filter { $0.id != "codex-weekly" && $0.isReported }) { row in
                toggleRow(row.title, isOn: alertBinding(for: row.id))
            }
        }
    }

    private var serviceAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Service alerts")
            toggleRow("OpenAI service outages", isOn: $notifyOnServiceOutage)
            toggleRow("OpenAI degraded performance", isOn: $notifyOnServiceDegraded)
            Button("Send test notification") { appState.sendTestNotification() }.gptGhostButton()
            if let status = appState.notificationTestStatus {
                Text(status).font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(text: "App")
            toggleRow("Launch at login", isOn: $launchAtLogin)
            toggleRow("Command-I opens the tracker", isOn: $enableCommandIShortcut)
            toggleRow("Use clear Liquid Glass", isOn: $preferClearGlass)
            if settingsScope != .chatGPT {
                HStack {
                    Button("Clear Codex trend history") { history.clear() }.gptGhostButton()
                    Spacer()
                    Text("Local samples only").font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
                }
            }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(text: "Updates")
            toggleRow("Install updates automatically", isOn: $autoUpdate)
            Text("Current version: \(currentVersion)").font(.system(size: 11)).foregroundColor(GPTTheme.textPrimary)
            if let update = appState.availableUpdate {
                Text("Version \(update.version) is available.").font(.system(size: 11)).foregroundColor(GPTTheme.accent)
            } else if let error = appState.updateCheckError {
                Text(error).font(.system(size: 10)).foregroundColor(.red)
            } else {
                Text("You're on the latest version.").font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
            Button(appState.isCheckingForUpdates ? "Checking…" : "Check for updates") {
                Task { await appState.checkForUpdates() }
            }
            .gptGhostButton().disabled(appState.isCheckingForUpdates)
        }
    }

    private var footer: some View {
        HStack {
            Button(appState.isRefreshingUsage ? "Refreshing…" : "Refresh usage") {
                Task { await appState.refreshUsage() }
            }
            .gptGhostButton().disabled(appState.isRefreshingUsage)
            Spacer()
            Button("Cancel") { appState.closeSettingsWindow?() }.gptGhostButton()
            Button("Save") { save() }.gptPrimaryButton()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var usageSettingRows: [UsageSettingRow] {
        let live = appState.usage?.tracks ?? []
        var rows: [UsageSettingRow] = []
        let hasLiveModels = live.contains { $0.scope == .chatGPTModel }
        for known in KnownUsageTrack.all where known.id != "chatgpt-model-limits" || !hasLiveModels {
            let reported = live.contains { $0.preferenceID == known.id }
            rows.append(UsageSettingRow(id: known.id, title: known.title, detail: known.detail, scope: known.scope, isReported: reported))
        }
        for track in live where !rows.contains(where: { $0.id == track.preferenceID }) {
            rows.append(UsageSettingRow(
                id: track.preferenceID,
                title: track.title,
                detail: track.windowSeconds.map(windowDescription) ?? track.remainingText ?? "Account-reported usage counter",
                scope: track.scope,
                isReported: true
            ))
        }
        return rows
    }

    private var scopedUsageRows: [UsageSettingRow] {
        usageSettingRows.filter { row in
            switch settingsScope {
            case .codex:
                return row.scope == .codex || row.scope == .workspace
            case .chatGPT:
                return row.scope == .chatGPTModel || row.scope == .chatGPTFeature
            case nil:
                return true
            }
        }
    }

    private var displayExplanation: String {
        switch settingsScope {
        case .codex:
            return "The trend plots only server-reported Codex weekly percentages. It is sampled locally while this Mac is running and never mixes in rolling-window or ChatGPT counters."
        case .chatGPT:
            return "ChatGPT displays only account-reported model and feature limits. Session Tracker keeps it separate from Codex usage."
        case nil:
            return combinedMode
                ? "Session Tracker keeps Codex and ChatGPT as separate top-level tabs."
                : "With tabs off, the menu combines Codex and ChatGPT into one dashboard."
        }
    }

    private var usageTrackingExplanation: String {
        switch settingsScope {
        case .codex:
            return "Codex weekly, rolling, code-review, credit, and workspace limits remain separate. The trend is built only from the reported Codex weekly percentage."
        case .chatGPT:
            return "Some documented limits—especially rolling uploads, voice, video and screen share—appear only when ChatGPT exposes a counter to this account."
        case nil:
            return "Rolling windows, weekly windows, model limits, feature allowances, credits, and remaining-task counters remain separate."
        }
    }

    private func usageToggle(_ row: UsageSettingRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 11, weight: .medium)).foregroundColor(GPTTheme.textPrimary)
                Text(row.detail + (row.isReported ? " · Live" : " · Not reported"))
                    .font(.system(size: 9)).foregroundColor(row.isReported ? GPTTheme.textSecondary : GPTTheme.textSecondary.opacity(0.65))
            }
            Spacer()
            Toggle("", isOn: visibilityBinding(for: row.id)).labelsHidden().toggleStyle(GPTGlassToggleStyle())
                .accessibilityLabel(Text("Show \(row.title)"))
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundColor(GPTTheme.textPrimary)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(GPTGlassToggleStyle()).accessibilityLabel(Text(title))
        }
    }

    private func thresholdButtons(selection: Binding<Set<Int>>) -> some View {
        HStack(spacing: 6) {
            ForEach(SettingsStore.availableThresholds, id: \.self) { value in
                Button("\(value)%") {
                    if selection.wrappedValue.contains(value) { selection.wrappedValue.remove(value) }
                    else { selection.wrappedValue.insert(value) }
                }
                .buttonStyle(.bordered)
                .tint(selection.wrappedValue.contains(value) ? GPTTheme.accent : .gray)
                .controlSize(.small)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 9, design: .monospaced)).foregroundColor(GPTTheme.textPrimary).lineLimit(1)
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(GPTTheme.textSecondary)
    }

    private func visibilityBinding(for id: String) -> Binding<Bool> {
        Binding(get: { !hiddenTrackIDs.contains(id) }, set: { visible in
            if visible { hiddenTrackIDs.remove(id) } else { hiddenTrackIDs.insert(id) }
        })
    }

    private func alertBinding(for id: String) -> Binding<Bool> {
        Binding(get: { alertTrackIDs.contains(id) }, set: { enabled in
            if enabled { alertTrackIDs.insert(id) } else { alertTrackIDs.remove(id) }
        })
    }

    private func windowDescription(_ seconds: Int) -> String {
        if seconds % 604_800 == 0 { return "Rolling \(seconds / 604_800)-day window" }
        if seconds % 3_600 == 0 { return "Rolling \(seconds / 3_600)-hour window" }
        return "Rolling \(seconds / 60)-minute window"
    }

    private var planName: String {
        let value = appState.usage?.planType ?? settings.accountPlanType
        return value.isEmpty ? "Unknown" : value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private func loadCurrentValues() {
        showCategoryTabs = settings.showCategoryTabs
        showHistoryChart = settings.showHistoryChart
        automaticallyShowNewUsageTracks = settings.automaticallyShowNewUsageTracks
        hiddenTrackIDs = settings.hiddenUsageTrackIDs
        alertTrackIDs = settings.alertEnabledUsageTrackIDs
        weeklyThresholds = Set(settings.weeklyUsageThresholds)
        additionalAlertThreshold = settings.additionalUsageAlertThreshold
        enableCommandIShortcut = settings.enableCommandIShortcut
        preferClearGlass = settings.preferClearGlass
        launchAtLogin = settings.launchAtLogin
        notifyOnServiceOutage = settings.notifyOnServiceOutage
        notifyOnServiceDegraded = settings.notifyOnServiceDegraded
        autoUpdate = settings.autoUpdateEnabled
    }

    private func save(showPopoverAfterClose: Bool = false, closeWindow: Bool = true) {
        settings.showCategoryTabs = showCategoryTabs
        settings.showHistoryChart = showHistoryChart
        settings.automaticallyShowNewUsageTracks = automaticallyShowNewUsageTracks
        for row in usageSettingRows {
            settings.setUsageTrackVisible(row.id, isVisible: !hiddenTrackIDs.contains(row.id))
            settings.setAlertEnabled(alertTrackIDs.contains(row.id), for: row.id)
        }
        settings.weeklyUsageThresholds = weeklyThresholds.sorted()
        settings.additionalUsageAlertThreshold = additionalAlertThreshold
        settings.enableCommandIShortcut = enableCommandIShortcut
        settings.preferClearGlass = preferClearGlass
        settings.launchAtLogin = launchAtLogin
        settings.notifyOnServiceOutage = notifyOnServiceOutage
        settings.notifyOnServiceDegraded = notifyOnServiceDegraded
        settings.autoUpdateEnabled = autoUpdate
        LoginItemManager.setEnabled(launchAtLogin)
        if closeWindow { appState.closeSettingsWindow?() }
        if showPopoverAfterClose {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { appState.requestTogglePopover?() }
        }
    }

    private func handleLoginCapture(_ capture: ChatGPTLoginCapture) {
        settings.sessionKey = capture.sessionKey
        settings.organizationID = capture.organizationID ?? ""
        settings.cookieHeader = capture.cookieHeader
        settings.accountPlanType = capture.planType ?? ChatGPTWebSession.planType(from: capture.sessionKey) ?? ""
        appState.clearAccountData()
        Task { await appState.refreshUsage() }
    }

    private func clearLogin() {
        guard !isClearingLogin else { return }
        isClearingLogin = true
        Task {
            await ChatGPTWebsiteData.clear()
            settings.clearChatGPTLogin()
            appState.clearAccountData()
            isClearingLogin = false
        }
    }
}

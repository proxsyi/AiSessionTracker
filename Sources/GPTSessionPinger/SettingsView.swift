import AppKit
import SwiftUI
import TrackerDesignSystem

private struct UsageSettingRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let scope: GPTUsageScope
    let supportsPercentageAlerts: Bool
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var history: UsageHistoryStore
    @EnvironmentObject var codexSessionPinger: CodexSessionPinger
    let topLeadingInset: CGFloat
    let saveOnDisappear: Bool
    let frameWidth: CGFloat
    let frameHeight: CGFloat
    let showsUpdateControls: Bool
    let combinedMode: Bool
    let settingsScope: UsageDisplayTab?
    let serviceVisibility: Binding<Bool>?

    @State private var selectedTab: TrackerSettingsTab = .general
    @State private var showCategoryTabs = true
    @State private var showHistoryChart = true
    @State private var automaticallyShowNewUsageTracks = true
    @State private var hiddenTrackIDs: Set<String> = []
    @State private var alertTrackIDs: Set<String> = []
    @State private var trackThresholds: [String: Set<Int>] = [:]
    @State private var enableCommandIShortcut = true
    @State private var preferClearGlass = true
    @State private var launchAtLogin = false
    @State private var notifyOnServiceOutage = true
    @State private var notifyOnServiceDegraded = true
    @State private var autoUpdate = true
    @State private var showingLogin = false
    @State private var showKeys = false
    @State private var isClearingLogin = false
    @State private var pingModel = "gpt-5.4-mini"
    @State private var pingReasoningEffort = "low"
    @State private var pingMessage = "Say 1"
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String?

    init(
        topLeadingInset: CGFloat = 0,
        saveOnDisappear: Bool = false,
        frameWidth: CGFloat = 500,
        frameHeight: CGFloat = 640,
        showsUpdateControls: Bool = true,
        combinedMode: Bool = false,
        settingsScope: UsageDisplayTab? = nil,
        serviceVisibility: Binding<Bool>? = nil
    ) {
        self.topLeadingInset = topLeadingInset
        self.saveOnDisappear = saveOnDisappear
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.showsUpdateControls = showsUpdateControls
        self.combinedMode = combinedMode
        self.settingsScope = settingsScope
        self.serviceVisibility = serviceVisibility
    }

    var body: some View {
        TrackerSettingsWindow(
            selectedTab: $selectedTab,
            accent: GPTTheme.accent,
            secondary: GPTTheme.textSecondary,
            clearGlass: preferClearGlass,
            topLeadingInset: topLeadingInset,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            content: { tabContent },
            footer: { footer }
        )
        .environment(\.gptClearGlass, preferClearGlass)
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

    @ViewBuilder
    private var tabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selectedTab {
            case .general:
                settingsCard { accountSection }
                settingsCard { displaySection }
                if combinedMode && settingsScope == .codex {
                    settingsCard { codexSessionPingerSection }
                    settingsCard { codexSessionActivitySection }
                } else if settingsScope != .codex {
                    settingsCard { pingSection }
                }
                settingsCard { activitySection }
            case .usage:
                settingsCard { trackedUsageSection }
                if combinedMode && settingsScope == .codex {
                    settingsCard { codexSessionDisplaySection }
                }
                settingsCard { usageDisplaySection }
                settingsCard { usageExplanationSection }
            case .alerts:
                settingsCard { usageAlertsSection }
                if combinedMode && settingsScope == .codex {
                    settingsCard { codexPingAlertsSection }
                }
                settingsCard { serviceAlertsSection }
            case .app:
                settingsCard { appSection }
                if showsUpdateControls {
                    settingsCard { updatesSection }
                }
            }
        }
        .trackerSettingsCardStack()
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        TrackerSettingsCard(clearGlass: preferClearGlass, content: content)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Account")
            if settings.isConfigured {
                Button("Log in again") { showingLogin = true }.gptPrimaryButton()
                Text("Using a previously captured session (\(settings.maskedSessionKey)). Plan: \(planName).")
                    .font(.system(size: 11)).foregroundColor(GPTTheme.textSecondary)
            } else {
                Text("Sign in through the private in-app browser to read this account's usage counters.")
                    .font(.system(size: 11)).foregroundColor(GPTTheme.textSecondary)
                Button("Log in to ChatGPT") { showingLogin = true }.gptPrimaryButton()
            }
            Button { showKeys.toggle() } label: {
                Label("Keys", systemImage: showKeys ? "chevron.down" : "chevron.right")
            }
            .gptGhostButton()
            if showKeys {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("Access token", settings.maskedSessionKey.isEmpty ? "Not stored" : settings.maskedSessionKey)
                    detailRow("Account ID", settings.organizationID.isEmpty ? "Not reported" : settings.organizationID)
                    detailRow("App browser cookies", settings.cookieHeader.isEmpty ? "Not stored" : "Stored securely in Keychain")
                    if settings.isConfigured {
                        Button(isClearingLogin ? "Clearing…" : "Log out") { clearLogin() }
                            .gptGhostButton()
                            .disabled(isClearingLogin)
                        Text("Logging out clears this app's Keychain login and embedded-browser data. Safari and Claude Session Pinger are unaffected.")
                            .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
                    }
                }
            }
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
            Text(displayExplanation)
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private var pingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(text: "Ping")
            Text("Pings use one shared ChatGPT conversation and the signed-in browser session.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Model")
                Picker("Model", selection: $pingModel) {
                    Text("GPT-5.4 mini (recommended) — gpt-5.4-mini").tag("gpt-5.4-mini")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(GPTTheme.accent)
                Text("Uses the lowest supported reasoning effort for this model. The same model is used for every ping.")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Reasoning effort")
                Picker("Reasoning effort", selection: $pingReasoningEffort) {
                    Text("Low (recommended)").tag("low")
                    Text("None").tag("none")
                    Text("Medium").tag("medium")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(GPTTheme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Message")
                TextField("Say 1", text: $pingMessage)
                    .textFieldStyle(.plain)
                    .gptGlassField()
            }
            HStack {
                Button(appState.isPinging ? "Pinging…" : "Ping now") { appState.pingChatGPT() }
                    .gptPrimaryButton().disabled(appState.isPinging || !settings.isConfigured)
                if let pingStatus = appState.pingStatus {
                    Text(pingStatus).font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
                }
            }
        }
    }

    private var codexSessionPingerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Codex session pinger")
            toggleRow("Schedule Codex pings", isOn: $codexSessionPinger.enabled)
            Text("Pings use one dedicated Codex chat and the same signed-in ChatGPT session. A successful send reuses this chat on every future ping.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Model")
                Picker("Model", selection: $codexSessionPinger.model) {
                    Text("GPT-5.4 mini (recommended) — gpt-5.4-mini").tag("gpt-5.4-mini")
                }
                .labelsHidden().pickerStyle(.menu).tint(GPTTheme.accent)
                Text("The lowest-cost configured model is used with low reasoning effort.")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Reasoning effort")
                Picker("Reasoning effort", selection: $codexSessionPinger.reasoningEffort) {
                    Text("Low (recommended)").tag("low")
                    Text("None").tag("none")
                    Text("Medium").tag("medium")
                }
                .labelsHidden().pickerStyle(.menu).tint(GPTTheme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Message")
                TextField("Say 1", text: $codexSessionPinger.message)
                    .textFieldStyle(.plain).gptGlassField()
            }
            fieldLabel("Schedule")
            ForEach(codexSessionPinger.slots.indices, id: \.self) { index in
                HStack {
                    Stepper(value: Binding(
                        get: { codexSessionPinger.slots[index].hour },
                        set: { codexSessionPinger.slots[index].hour = $0 }
                    ), in: 0...23) {
                        HStack(spacing: 6) {
                            Text(codexTimeNumbers(for: codexSessionPinger.slots[index].hour))
                                .frame(width: 40, alignment: .trailing)
                            Text(codexTimePeriod(for: codexSessionPinger.slots[index].hour))
                                .frame(width: 22, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(GPTTheme.textPrimary)
                    }
                    .controlSize(.small)
                    Spacer()
                    Button { removeCodexSlot(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundColor(GPTTheme.textSecondary)
                }
            }
            Button("Add time") { addCodexSlot() }.gptGhostButton()
            if let message = codexSessionPinger.scheduleValidationMessage {
                Text(message).font(.system(size: 10)).foregroundColor(.red)
            } else {
                Text("Every scheduled Codex ping must be at least 5 hours from the ones before and after it, including overnight.")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
        }
    }

    private var codexSessionActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Activity")
            HStack {
                fieldLabel("Success rate")
                Spacer()
                Text(codexSessionPinger.successRateText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(GPTTheme.textPrimary)
            }
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Last result")
                Spacer()
                Text(codexSessionPinger.lastResultText)
                    .font(.system(size: 11))
                    .foregroundColor(GPTTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            if let activeModel = codexSessionPinger.activeModel {
                Text("Last successful model: \(activeModel)")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
            Text(codexSessionPinger.conversationID.isEmpty
                ? "The first Codex ping will create one dedicated chat and reuse it afterward."
                : "Codex pings are reusing one dedicated chat.")
                .font(.system(size: 11)).foregroundColor(GPTTheme.textSecondary)
            if !codexSessionPinger.conversationID.isEmpty {
                HStack {
                    Button("Open pinger chat") {
                        if let url = codexSessionPinger.conversationURL { NSWorkspace.shared.open(url) }
                    }
                    .gptGhostButton()
                    Spacer()
                    Button("Start fresh chat") { codexSessionPinger.startFreshChat() }.gptGhostButton()
                }
            }
            if let status = codexSessionPinger.status {
                Text(status).font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
        }
    }

    private var codexSessionDisplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Session display")
            toggleRow("Next possible session", isOn: $codexSessionPinger.showNextPossibleCountdown)
            toggleRow("Scheduled session", isOn: $codexSessionPinger.showScheduledCountdown)
            if codexSessionPinger.showNextPossibleCountdown && codexSessionPinger.showScheduledCountdown {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Main focus")
                    Picker("Main focus", selection: $codexSessionPinger.countdownFocus) {
                        ForEach(CodexSessionPinger.CountdownFocus.allCases) { focus in
                            Text(focus.label).tag(focus)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(GPTTheme.accent)
                    Text("The other enabled countdown appears underneath in gray.")
                        .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
                }
            }
            toggleRow("Start sessions when available", isOn: $codexSessionPinger.autoStartAvailableSessions)
            Text("Off by default. Starts an available Codex session unless the next scheduled ping is within five hours. A successful ping prevents another start for five hours.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private func addCodexSlot() {
        let current = codexSessionPinger.slots
        for hour in 0...23 {
            let candidate = current + [CodexSessionPinger.ScheduleSlot(hour: hour, minute: 0)]
            let minutes = candidate.map { $0.hour * 60 + $0.minute }.sorted()
            let valid = minutes.enumerated().allSatisfy { index, minute in
                let next = index == minutes.count - 1 ? minutes[0] + 24 * 60 : minutes[index + 1]
                return next - minute >= 5 * 60
            }
            if valid {
                codexSessionPinger.slots.append(CodexSessionPinger.ScheduleSlot(hour: hour, minute: 0))
                return
            }
        }
    }

    private func removeCodexSlot(at index: Int) {
        guard codexSessionPinger.slots.count > 1 else { return }
        codexSessionPinger.slots.remove(at: index)
    }

    private func codexTimeNumbers(for hour: Int) -> String {
        let normalized = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%2d:00", normalized)
    }

    private func codexTimePeriod(for hour: Int) -> String {
        hour < 12 ? "AM" : "PM"
    }

    @ViewBuilder
    private var activitySection: some View {
        if combinedMode && settingsScope == .codex {
            EmptyView()
        } else if settingsScope == .codex {
            codexActivitySection
        } else {
            pingActivitySection
        }
    }

    private var pingActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Activity")
            Text(settings.pingConversationID.isEmpty
                ? "The next ping will create one dedicated ChatGPT chat and reuse it afterward."
                : "Pings are reusing one dedicated ChatGPT chat.")
                .font(.system(size: 11)).foregroundColor(GPTTheme.textSecondary)
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Last result")
                Spacer()
                Text(appState.pingStatus ?? "No pings yet")
                    .font(.system(size: 10))
                    .foregroundColor(GPTTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            if !settings.pingConversationID.isEmpty {
                HStack {
                    Button("Open pinger chat") { openPingerChat() }.gptGhostButton()
                    Spacer()
                    Button("Start fresh chat") {
                        settings.pingConversationID = ""
                        settings.pingParentMessageID = ""
                        appState.pingStatus = "The next ping will use a new shared chat."
                    }
                    .gptGhostButton()
                }
            }
        }
    }

    private var codexActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Activity")
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Last result")
                Spacer()
                Text(appState.usageError ?? (appState.usage == nil ? "No usage data yet" : "Usage refreshed"))
                    .font(.system(size: 10))
                    .foregroundColor(appState.usageError == nil ? GPTTheme.textPrimary : .red)
                    .multilineTextAlignment(.trailing)
            }
            Text(appState.usage == nil
                ? "Refresh usage after signing in to load this account's Codex counters."
                : "Codex counters are read from the same signed-in ChatGPT account and refreshed every five minutes.")
                .font(.system(size: 11)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private var trackedUsageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(text: "Tracked usage")
            Text("Every counter currently reported by this account can be hidden independently. Rolling windows remain separate from weekly, monthly, credit and remaining-task limits.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            groupTitle(settingsScope?.rawValue ?? "Codex and ChatGPT")
            if scopedUsageRows.isEmpty {
                Text("No usage counters are currently reported for this section. Refresh usage after signing in to check again.")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            } else {
                ForEach(scopedUsageRows) { row in usageToggle(row) }
            }
        }
    }

    private var usageDisplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Usage display")
            if settingsScope != .chatGPT {
                toggleRow("Show Codex weekly trend", isOn: $showHistoryChart)
            }
            toggleRow("Automatically show newly discovered limits", isOn: $automaticallyShowNewUsageTracks)
            Text("These controls affect only visible, account-reported counters. They do not change the limits themselves.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
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

    private var usageAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Usage alerts")
            Text("Turn on exactly the live counters you want notifications for. The first refresh after launch is only a baseline.")
                .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            if !scopedUsageRows.isEmpty {
                Text("Each percentage counter has its own thresholds. Remaining-use counters notify once when ChatGPT reports them unavailable.")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
                ForEach(scopedUsageRows) { row in
                    toggleRow(row.title, isOn: alertBinding(for: row.id))
                    if row.supportsPercentageAlerts {
                        thresholdButtons(selection: thresholdBinding(for: row.id))
                            .disabled(!alertTrackIDs.contains(row.id))
                    }
                }
            } else {
                Text("No alertable usage counters are currently reported for this section.")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
        }
    }

    private var codexPingAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Ping alerts")
            toggleRow("Ping failures", isOn: $codexSessionPinger.notifyOnFailure)
            toggleRow("New session available", isOn: $codexSessionPinger.notifySessionAvailable)
            toggleRow("Session started by app", isOn: $codexSessionPinger.notifySessionStarted)
            toggleRow("Scheduled ping sent", isOn: $codexSessionPinger.notifyOnSuccess)
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
            if combinedMode && settingsScope == .codex {
                toggleRow("Wake Mac for scheduled pings", isOn: $codexSessionPinger.enableScheduledWake)
                if codexSessionPinger.enableScheduledWake {
                    Text(codexSessionPinger.wakeSupportStatus)
                        .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let result = codexSessionPinger.wakeTestResult {
                        Label(result.message, systemImage: codexWakeResultSymbol(result.outcome))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(codexWakeResultColor(result.outcome))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !codexSessionPinger.wakeHelperInstalled {
                        Button(codexSessionPinger.isInstallingWakeSupport ? "Installing…" : "Install wake support") {
                            codexSessionPinger.installWakeSupport()
                        }
                        .gptPrimaryButton()
                        .disabled(codexSessionPinger.isInstallingWakeSupport)
                    } else {
                        Button("Run 2-minute closed-lid test") {
                            codexSessionPinger.testWakeSupport()
                        }
                        .gptGhostButton()
                    }
                    Text("Uses isolated Codex wake records, so changing Codex schedules never cancels Claude wake events. Keep the MacBook connected to power for closed-lid pings.")
                        .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
                }
            }
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

    private func codexWakeResultSymbol(_ outcome: CodexWakeTestOutcome) -> String {
        switch outcome {
        case .pending: return "clock"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func codexWakeResultColor(_ outcome: CodexWakeTestOutcome) -> Color {
        switch outcome {
        case .pending: return GPTTheme.textSecondary
        case .passed: return GPTTheme.accent
        case .failed: return .orange
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
        TrackerSettingsFooter(
            accent: GPTTheme.accent,
            testTitle: isTestingConnection || appState.isRefreshingUsage ? "Testing…" : "Test connection",
            testDisabled: isTestingConnection || appState.isRefreshingUsage,
            saveDisabled: combinedMode && settingsScope == .codex && codexSessionPinger.scheduleValidationMessage != nil,
            onTest: runConnectionTest,
            onCancel: { appState.closeSettingsWindow?() },
            onSave: { save() }
        ) {
            if let connectionTestResult {
                Text(connectionTestResult)
                    .font(.system(size: 10))
                    .foregroundColor(connectionTestResult.lowercased().contains("sent") ? GPTTheme.accent : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runConnectionTest() {
        isTestingConnection = true
        connectionTestResult = nil
        if combinedMode && settingsScope == .codex {
            Task {
                let result = await codexSessionPinger.testConnection()
                await MainActor.run {
                    connectionTestResult = result
                    isTestingConnection = false
                }
            }
        } else {
            Task {
                await appState.refreshUsage()
                await MainActor.run {
                    connectionTestResult = appState.usageError ?? "Connection succeeded and usage refreshed."
                    isTestingConnection = false
                }
            }
        }
    }

    private var usageSettingRows: [UsageSettingRow] {
        var rows: [UsageSettingRow] = []
        for track in appState.usage?.tracks ?? [] where !rows.contains(where: { $0.id == track.preferenceID }) {
            rows.append(UsageSettingRow(
                id: track.preferenceID,
                title: track.title,
                detail: track.windowSeconds.map(windowDescription)
                    ?? track.remainingText
                    ?? track.valueText
                    ?? "Account-reported usage counter",
                scope: track.scope,
                supportsPercentageAlerts: track.usedPercent != nil
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
                Text(row.detail + " · Live")
                    .font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: visibilityBinding(for: row.id)).labelsHidden().toggleStyle(GPTGlassToggleStyle())
                .accessibilityLabel(Text("Show \(row.title)"))
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        TrackerSettingsToggleRow(title, isOn: isOn, accent: GPTTheme.accent, clearGlass: preferClearGlass)
    }

    private func fieldLabel(_ text: String) -> some View {
        TrackerSettingsFieldLabel(text)
    }

    private func thresholdButtons(selection: Binding<Set<Int>>) -> some View {
        TrackerSettingsThresholdPicker(
            values: SettingsStore.availableThresholds,
            selection: selection,
            accent: GPTTheme.accent,
            clearGlass: preferClearGlass
        )
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
            if enabled {
                alertTrackIDs.insert(id)
                if trackThresholds[id, default: []].isEmpty {
                    trackThresholds[id] = Set(SettingsStore.defaultWeeklyThresholds)
                }
            } else {
                alertTrackIDs.remove(id)
            }
        })
    }

    private func thresholdBinding(for id: String) -> Binding<Set<Int>> {
        Binding(
            get: { trackThresholds[id] ?? Set(SettingsStore.defaultWeeklyThresholds) },
            set: { trackThresholds[id] = $0 }
        )
    }

    private func windowDescription(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return "Rolling \(seconds / 86_400)-day window" }
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
        trackThresholds = Dictionary(uniqueKeysWithValues: usageSettingRows.map {
            ($0.id, Set(settings.alertThresholds(for: $0.id)))
        })
        enableCommandIShortcut = settings.enableCommandIShortcut
        preferClearGlass = settings.preferClearGlass
        launchAtLogin = settings.launchAtLogin
        notifyOnServiceOutage = settings.notifyOnServiceOutage
        notifyOnServiceDegraded = settings.notifyOnServiceDegraded
        autoUpdate = settings.autoUpdateEnabled
        pingModel = settings.pingModel
        pingReasoningEffort = settings.pingReasoningEffort
        pingMessage = settings.pingMessage
    }

    private func save(showPopoverAfterClose: Bool = false, closeWindow: Bool = true) {
        settings.showCategoryTabs = showCategoryTabs
        settings.showHistoryChart = showHistoryChart
        settings.automaticallyShowNewUsageTracks = automaticallyShowNewUsageTracks
        for row in usageSettingRows {
            settings.setUsageTrackVisible(row.id, isVisible: !hiddenTrackIDs.contains(row.id))
            settings.setAlertEnabled(alertTrackIDs.contains(row.id), for: row.id)
        }
        for row in usageSettingRows {
            settings.setAlertThresholds(
                Array(trackThresholds[row.id] ?? Set(SettingsStore.defaultWeeklyThresholds)),
                for: row.id
            )
        }
        settings.enableCommandIShortcut = enableCommandIShortcut
        settings.preferClearGlass = preferClearGlass
        settings.launchAtLogin = launchAtLogin
        settings.notifyOnServiceOutage = notifyOnServiceOutage
        settings.notifyOnServiceDegraded = notifyOnServiceDegraded
        settings.autoUpdateEnabled = autoUpdate
        settings.pingModel = pingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-5.4-mini" : pingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.pingReasoningEffort = pingReasoningEffort
        settings.pingMessage = pingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say 1" : pingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func openPingerChat() {
        guard !settings.pingConversationID.isEmpty,
              let url = URL(string: "https://chatgpt.com/c/\(settings.pingConversationID)") else { return }
        NSWorkspace.shared.open(url)
    }
}

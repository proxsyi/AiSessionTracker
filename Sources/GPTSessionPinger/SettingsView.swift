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
    let isActive: Bool
    let onOpenSystemSettings: (() -> Void)?
    let sharedSelectedTab: Binding<TrackerSettingsTab>?

    @State private var codexDraft = CodexSessionPinger.Preferences()
    @State private var discardChanges = false
    @State private var localSelectedTab: TrackerSettingsTab = .general
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
    @State private var pingModel = ChatGPTModelCatalog.lowestUsageModelSlug
    @State private var pingReasoningEffort = "none"
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
        serviceVisibility: Binding<Bool>? = nil,
        isActive: Bool = true,
        onOpenSystemSettings: (() -> Void)? = nil,
        selectedTab: Binding<TrackerSettingsTab>? = nil
    ) {
        self.topLeadingInset = topLeadingInset
        self.saveOnDisappear = saveOnDisappear
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.showsUpdateControls = showsUpdateControls
        self.combinedMode = combinedMode
        self.settingsScope = settingsScope
        self.serviceVisibility = serviceVisibility
        self.isActive = isActive
        self.onOpenSystemSettings = onOpenSystemSettings
        self.sharedSelectedTab = selectedTab
    }

    private var selectedTab: Binding<TrackerSettingsTab> {
        sharedSelectedTab ?? $localSelectedTab
    }

    var body: some View {
        TrackerSettingsWindow(
            selectedTab: selectedTab,
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
            discardChanges = false
            loadCurrentValues()
            installSaveActionIfActive()
        }
        .onChange(of: isActive) { active in
            if active {
                discardChanges = false
                loadCurrentValues()
                installSaveActionIfActive()
            } else if saveOnDisappear && !discardChanges {
                save(closeWindow: false)
            }
        }
        .onDisappear {
            if saveOnDisappear && isActive && !discardChanges { save(closeWindow: false) }
            if isActive { appState.requestSaveAndCloseSettings = nil }
        }
        .sheet(isPresented: $showingLogin) {
            CookieLoginSheet { capture in handleLoginCapture(capture) }
        }
    }

    private func installSaveActionIfActive() {
        guard isActive else { return }
        appState.requestSaveAndCloseSettings = { save(showPopoverAfterClose: true) }
    }

    @ViewBuilder
    private var tabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selectedTab.wrappedValue {
            case .general:
                settingsCard { accountSection }
                settingsCard { displaySection }
                if combinedMode && settingsScope == .codex {
                    settingsCard { codexSessionPingerSection }
                    settingsCard { codexSessionActivitySection }
                } else if settingsScope != .codex {
                    settingsCard { pingSection }
                }
                if !(combinedMode && settingsScope == .codex) { settingsCard { activitySection } }
            case .usage:
                settingsCard { trackedUsageSection }
                if combinedMode && settingsScope == .codex {
                    settingsCard { codexSessionDisplaySection }
                }
                settingsCard { usageDisplaySection }
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
        TrackerAccountSettings(connected: settings.isConfigured, provider: "ChatGPT",
            status: settings.isConfigured ? "Connected · \(planName)" : nil, error: settings.credentialPersistenceError,
            busy: isClearingLogin || appState.isPinging || codexSessionPinger.isPinging || isTestingConnection,
            accent: GPTTheme.accent, onLogin: { showingLogin = true }, onLogout: clearLogin) {
            Button { showKeys.toggle() } label: {
                Label("Keys", systemImage: showKeys ? "chevron.down" : "chevron.right")
            }.gptGhostButton()
            if showKeys {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("Access token", settings.maskedSessionKey.isEmpty ? "Not stored" : settings.maskedSessionKey)
                    detailRow("Account ID", settings.organizationID.isEmpty ? "Not reported" : settings.organizationID)
                    detailRow("App browser cookies", settings.cookieHeader.isEmpty ? "Not stored" : "Stored in Keychain")
                }
            }
        }
    }

    private var displaySection: some View {
        TrackerSettingsSection("Menu display") {
            if let serviceVisibility, let settingsScope {
                toggleRow("Show \(settingsScope.rawValue) dashboard", isOn: serviceVisibility, help: "Also controls this provider's menu-bar meter.")
            }
            if !combinedMode {
                toggleRow("Show Codex and ChatGPT tabs", isOn: $showCategoryTabs)
            }
        }
    }

    private var pingSection: some View {
        TrackerSettingsSection("Ping") {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Model")
                Picker("Model", selection: $pingModel) {
                    ForEach(pingModelOptions(for: pingModel, workMode: false)) { option in
                        Text(modelPickerTitle(option)).tag(option.slug)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(GPTTheme.accent)
                .help("Uses this model for every ping in one shared ChatGPT conversation.")
                .onChange(of: pingModel) { selected in
                    pingReasoningEffort = normalizedEffort(pingReasoningEffort, for: selected, workMode: false)
                }
                modelActions(workMode: false)
            }
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Reasoning effort")
                Picker("Reasoning effort", selection: $pingReasoningEffort) {
                    ForEach(effortOptions(for: pingModel, workMode: false)) { effort in
                        Text(TrackerModelLabels.effort(effort.id, title: effort.title)).tag(effort.id)
                    }
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
                Button(appState.isPinging ? "Pinging…" : "Ping now") {
                    appState.pingChatGPT(model: pingModel, effort: pingReasoningEffort, message: pingMessage)
                }
                    .gptPrimaryButton().disabled(appState.isPinging || !settings.isConfigured)
                if let pingStatus = appState.pingStatus {
                    Text(pingStatus).font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
                }
            }
        }
    }

    private var codexSessionPingerSection: some View {
        TrackerPingSettings(enabled: $codexDraft.enabled, message: $codexDraft.message,
                            accent: GPTTheme.accent, clearGlass: preferClearGlass) {
            Picker("Model", selection: $codexDraft.model) {
                ForEach(pingModelOptions(for: codexDraft.model, workMode: true)) { option in Text(modelPickerTitle(option)).tag(option.slug) }
            }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).tint(GPTTheme.accent)
                .help("Uses this model in the saved Codex Work chat. Actual usage varies by model and effort.")
                .onChange(of: codexDraft.model) { selected in
                    codexDraft.reasoningEffort = normalizedEffort(codexDraft.reasoningEffort, for: selected, workMode: true)
                }
            modelActions(workMode: true)
        } effort: {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Reasoning effort")
                Picker("Reasoning effort", selection: $codexDraft.reasoningEffort) {
                    ForEach(effortOptions(for: codexDraft.model, workMode: true)) { effort in
                        Text(TrackerModelLabels.effort(effort.id, title: effort.title)).tag(effort.id)
                    }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).tint(GPTTheme.accent)
            }
        } schedule: {
            TrackerScheduleEditor(slots: Binding(
                get: { codexDraft.slots.map { .init(hour: $0.hour, minute: $0.minute) } },
                set: { codexDraft.slots = $0.map { .init(hour: $0.hour, minute: $0.minute) } }
            ), accent: GPTTheme.accent)
        }
    }

    private var codexSessionActivitySection: some View {
        TrackerActivitySettings(successRate: codexSessionPinger.successRateText, lastResult: codexSessionPinger.lastResultText,
            activeModel: codexSessionPinger.activeModel.map { settings.pingModelOption(for: $0)?.displayTitle ?? TrackerModelLabels.openAI($0) },
            hasChat: codexSessionPinger.conversationURL != nil, canStartFresh: codexSessionPinger.needsChatRecovery,
            busy: codexSessionPinger.isPinging || isTestingConnection,
            error: codexSessionPinger.records.last?.success == false || codexSessionPinger.needsChatRecovery ? codexSessionPinger.status : nil,
            onOpen: { if let url = codexSessionPinger.conversationURL { NSWorkspace.shared.open(url) } },
            onStartFresh: { codexSessionPinger.startFreshChat() })
    }

    private var codexSessionDisplaySection: some View {
        TrackerSettingsSection("Session display") {
            TrackerSessionDisplaySettings(nextPossible: $codexDraft.showNextPossibleCountdown, scheduled: $codexDraft.showScheduledCountdown,
                focusScheduled: Binding(get: { codexDraft.countdownFocus == .scheduled }, set: { codexDraft.countdownFocus = $0 ? .scheduled : .nextPossible }),
                autoStart: $codexDraft.autoStartAvailableSessions, accent: GPTTheme.accent, clearGlass: preferClearGlass)
        }
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
        TrackerSettingsSection("Activity") {
            detailRow("Chat", settings.pingConversationID.isEmpty ? "Created by first ping" : "Shared chat")
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
        TrackerSettingsSection("Activity") {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Last result")
                Spacer()
                Text(appState.usageError ?? (appState.usage == nil ? "No usage data yet" : "Usage refreshed"))
                    .font(.system(size: 10))
                    .foregroundColor(appState.usageError == nil ? GPTTheme.textPrimary : .red)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var trackedUsageSection: some View {
        TrackerSettingsSection("Tracked usage") {
            if scopedUsageRows.isEmpty {
                Text("No usage counters are currently reported for this section. Refresh usage after signing in to check again.")
                    .font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            } else {
                ForEach(scopedUsageRows) { row in usageToggle(row) }
            }
        }
    }

    private var usageDisplaySection: some View {
        TrackerSettingsSection("Usage display") {
            if settingsScope != .chatGPT {
                toggleRow("Show weekly trend", isOn: $showHistoryChart)
            }
            toggleRow("Automatically show newly discovered limits", isOn: $automaticallyShowNewUsageTracks, help: "Shows new account-reported counters when ChatGPT begins returning them.")
        }
    }

    private var usageAlertsSection: some View {
        TrackerSettingsSection("Usage alerts") {
            ForEach(scopedUsageRows) { row in
                TrackerUsageAlertSetting(row.title, enabled: alertBinding(for: row.id), thresholds: thresholdBinding(for: row.id),
                    supportsPercentage: row.supportsPercentageAlerts, accent: GPTTheme.accent, clearGlass: preferClearGlass)
            }
            if scopedUsageRows.isEmpty { TrackerSettingsCaption("No reported counters. Refresh after signing in.") }
        }
    }

    private var codexPingAlertsSection: some View {
        TrackerSettingsSection("Ping alerts") {
            TrackerPingAlertSettings(failures: $codexDraft.notifyOnFailure, available: $codexDraft.notifySessionAvailable,
                sent: $codexDraft.notifySessionStarted, scheduled: $codexDraft.notifyOnSuccess,
                accent: GPTTheme.accent, clearGlass: preferClearGlass)
        }
    }

    private var serviceAlertsSection: some View {
        TrackerServiceAlertSettings(provider: "OpenAI", outage: $notifyOnServiceOutage, degraded: $notifyOnServiceDegraded,
            accent: GPTTheme.accent, clearGlass: preferClearGlass, status: appState.notificationTestStatus,
            onTest: { appState.sendTestNotification(provider: settingsScope == .chatGPT ? .chatGPT : .codex) })
    }

    private var appSection: some View {
        TrackerSettingsSection("App") {
            if !combinedMode { toggleRow("Launch at login", isOn: $launchAtLogin) }
            toggleRow("Command-I opens menu", isOn: $enableCommandIShortcut)
            if combinedMode && settingsScope == .codex {
                TrackerWakeSettings(enabled: $codexDraft.enableScheduledWake, installed: codexSessionPinger.wakeHelperInstalled,
                    status: codexSessionPinger.wakeSupportStatus, result: codexSessionPinger.wakeTestResult?.message,
                    outcome: codexSessionPinger.wakeTestResult?.outcome.rawValue, accent: GPTTheme.accent, clearGlass: preferClearGlass,
                    busy: codexSessionPinger.isInstallingWakeSupport || isTestingConnection || codexSessionPinger.isPinging,
                    setupTitle: onOpenSystemSettings == nil ? "Install wake support" : "Set up in System",
                    onSetup: { if let onOpenSystemSettings { onOpenSystemSettings() } else { codexSessionPinger.installWakeSupport() } },
                    onTest: { codexSessionPinger.testWakeSupport() })
            }
            toggleRow("Use clear Liquid Glass", isOn: $preferClearGlass, help: "Changes Settings glass transparency immediately.")
            if settingsScope != .chatGPT {
                Button("Clear weekly trend history") { history.clear() }.gptGhostButton().help("Clears local samples only.")
            }
        }
    }

    private var updatesSection: some View {
        TrackerSettingsSection("Updates") {
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
            saveDisabled: combinedMode && settingsScope == .codex && CodexSessionPinger.validationMessage(for: codexDraft.slots) != nil,
            onTest: runConnectionTest,
            onCancel: { discardChanges = true; appState.closeSettingsWindow?() },
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
                let result = await codexSessionPinger.testConnection(preferences: codexDraft)
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

    private func usageToggle(_ row: UsageSettingRow) -> some View {
        TrackerSettingsToggleRow(row.title, isOn: visibilityBinding(for: row.id),
            accent: GPTTheme.accent, clearGlass: preferClearGlass, helpText: row.detail)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String? = nil) -> some View {
        TrackerSettingsToggleRow(
            title,
            isOn: isOn,
            accent: GPTTheme.accent,
            clearGlass: preferClearGlass,
            helpText: help
        )
    }

    private func fieldLabel(_ text: String) -> some View {
        TrackerSettingsFieldLabel(text)
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
                trackThresholds[id] = []
            }
        })
    }

    private func thresholdBinding(for id: String) -> Binding<Set<Int>> {
        Binding(
            get: { trackThresholds[id] ?? Set(SettingsStore.defaultWeeklyThresholds) },
            set: {
                trackThresholds[id] = $0
                if $0.isEmpty { alertTrackIDs.remove(id) }
            }
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

    private func pingModelOptions(for selectedSlug: String, workMode: Bool) -> [ChatGPTModelOption] {
        var models = settings.availablePingModels.filter { $0.isWorkMode == workMode }
        if models.isEmpty {
            models = [ChatGPTModelOption(
                slug: workMode ? ChatGPTModelCatalog.lowestUsageWorkModelSlug : ChatGPTModelCatalog.lowestUsageModelSlug,
                title: workMode ? ChatGPTModelCatalog.lowestUsageWorkModelTitle : ChatGPTModelCatalog.lowestUsageModelTitle,
                reasoningType: workMode ? "reasoning" : "none",
                thinkingEfforts: workMode ? [ChatGPTThinkingEffort(id: "min", title: "Light")] : [],
                isWorkMode: workMode
            )]
        }
        if !models.contains(where: { $0.slug == selectedSlug }) {
            models.append(ChatGPTModelOption(
                slug: selectedSlug,
                title: ChatGPTModelCatalog.fallbackTitle(for: selectedSlug),
                reasoningType: workMode || selectedSlug.contains("thinking") || selectedSlug.contains("t-mini") ? "reasoning" : "none",
                thinkingEfforts: [],
                isWorkMode: selectedSlug.hasSuffix("-wm")
            ))
        }
        return models
    }

    private func modelPickerTitle(_ option: ChatGPTModelOption) -> String {
        option.displayTitle
    }

    private func modelActions(workMode: Bool) -> some View {
        HStack {
            Button("Use lowest usage") {
                guard let model = ChatGPTModelCatalog.lowestUsageOption(in: settings.availablePingModels, workMode: workMode) else { return }
                let effort = ChatGPTModelCatalog.lowestEffort(for: model).id
                if workMode { codexDraft.model = model.slug; codexDraft.reasoningEffort = effort }
                else { pingModel = model.slug; pingReasoningEffort = effort }
            }
            .gptGhostButton()
            .disabled(ChatGPTModelCatalog.lowestUsageOption(in: settings.availablePingModels, workMode: workMode) == nil)
            .help("Prefers the smallest available model family and lowest effort. Actual usage varies.")
            Button("Refresh models") { Task { await appState.refreshUsage() } }
                .gptGhostButton().disabled(appState.isRefreshingUsage)
        }
    }

    private func effortOptions(for slug: String, workMode: Bool) -> [ChatGPTThinkingEffort] {
        pingModelOptions(for: slug, workMode: workMode).first(where: { $0.slug == slug })?.selectableEfforts
            ?? [ChatGPTThinkingEffort(id: "default", title: "Model default")]
    }

    private func normalizedEffort(_ effort: String, for slug: String, workMode: Bool) -> String {
        let options = effortOptions(for: slug, workMode: workMode)
        return options.contains(where: { $0.id == effort }) ? effort : (options.first?.id ?? "default")
    }

    private func loadCurrentValues() {
        codexDraft = codexSessionPinger.preferences
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
        if combinedMode && settingsScope == .codex {
            guard CodexSessionPinger.validationMessage(for: codexDraft.slots) == nil else {
                selectedTab.wrappedValue = .general
                return
            }
            codexSessionPinger.applyPreferences(codexDraft)
        }
        settings.showCategoryTabs = showCategoryTabs
        settings.showHistoryChart = showHistoryChart
        settings.automaticallyShowNewUsageTracks = automaticallyShowNewUsageTracks
        for row in scopedUsageRows {
            settings.setUsageTrackVisible(row.id, isVisible: !hiddenTrackIDs.contains(row.id))
            settings.setAlertEnabled(alertTrackIDs.contains(row.id), for: row.id)
        }
        for row in scopedUsageRows {
            settings.setAlertThresholds(
                Array(trackThresholds[row.id] ?? Set(SettingsStore.defaultWeeklyThresholds)),
                for: row.id
            )
        }
        settings.enableCommandIShortcut = enableCommandIShortcut
        settings.preferClearGlass = preferClearGlass
        if !combinedMode {
            settings.launchAtLogin = launchAtLogin
        }
        settings.notifyOnServiceOutage = notifyOnServiceOutage
        settings.notifyOnServiceDegraded = notifyOnServiceDegraded
        settings.autoUpdateEnabled = autoUpdate
        settings.pingModel = pingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ChatGPTModelCatalog.lowestUsageModelSlug
            : pingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.pingReasoningEffort = normalizedEffort(pingReasoningEffort, for: settings.pingModel, workMode: false)
        settings.pingMessage = pingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say 1" : pingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !combinedMode {
            LoginItemManager.setEnabled(launchAtLogin)
        }
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

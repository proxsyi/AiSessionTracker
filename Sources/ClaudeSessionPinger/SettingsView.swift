import SwiftUI
import AppKit
import TrackerDesignSystem

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var stats: StatsStore
    let topLeadingInset: CGFloat
    let saveOnDisappear: Bool
    let frameWidth: CGFloat
    let frameHeight: CGFloat
    let showsUpdateControls: Bool
    let serviceVisibility: Binding<Bool>?
    let serviceDisplayName: String?
    let isActive: Bool
    let onOpenSystemSettings: (() -> Void)?
    let sharedSelectedTab: Binding<TrackerSettingsTab>?

    @State private var sessionKeyInput = ""
    @State private var organizationID = ""
    @State private var model = ""
    @State private var message = ""
    @State private var slots: [ScheduleSlot] = []
    @State private var launchAtLogin = false
    @State private var notifyOnFailure = true
    @State private var notifyOnSuccess = false
    @State private var scheduledPingsEnabled = true
    @State private var notifyOnServiceOutage = true
    @State private var notifyOnServiceDegraded = true
    @State private var sessionThresholds: Set<Int> = []
    @State private var weeklyThresholds: Set<Int> = []
    @State private var showSessionBar = true
    @State private var showWeeklyBar = true
    @State private var showHistoryChart = false
    @State private var showNextPossibleCountdown = true
    @State private var showScheduledCountdown = true
    @State private var countdownFocus: CountdownFocus = .nextPossible
    @State private var notifySessionAvailable = true
    @State private var notifySessionStarted = true
    @State private var autoStartAvailableSessions = false
    @State private var enableCommandUShortcut = true
    @State private var enableScheduledWake = true
    @State private var preferClearGlass = true
    @State private var localSelectedTab: TrackerSettingsTab = .general
    @State private var autoUpdate = true
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showingLogin = false
    @State private var isClearingLogin = false
    @State private var discardChanges = false
    @State private var loginCaptured = false
    @State private var isFetchingOrganization = false
    @State private var showManualKeys = false

    init(
        topLeadingInset: CGFloat = 0,
        saveOnDisappear: Bool = false,
        frameWidth: CGFloat = 460,
        frameHeight: CGFloat = 600,
        showsUpdateControls: Bool = true,
        serviceVisibility: Binding<Bool>? = nil,
        serviceDisplayName: String? = nil,
        isActive: Bool = true,
        onOpenSystemSettings: (() -> Void)? = nil,
        selectedTab: Binding<TrackerSettingsTab>? = nil
    ) {
        self.topLeadingInset = topLeadingInset
        self.saveOnDisappear = saveOnDisappear
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.showsUpdateControls = showsUpdateControls
        self.serviceVisibility = serviceVisibility
        self.serviceDisplayName = serviceDisplayName
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
            accent: ClaudeTheme.accent,
            secondary: ClaudeTheme.textSecondary,
            clearGlass: preferClearGlass,
            topLeadingInset: topLeadingInset,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            content: { tabContent },
            footer: { footer }
        )
        .environment(\.claudeClearGlass, preferClearGlass)
        .onAppear {
            discardChanges = false
            loadCurrentValues()
            appState.refreshWakeTestResult()
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
            CookieLoginSheet { sessionKey, organizationIDFromCookie, cookieHeader in
                handleLoginCapture(
                    sessionKey: sessionKey,
                    organizationIDFromCookie: organizationIDFromCookie,
                    cookieHeader: cookieHeader
                )
            }
        }
    }

    private func installSaveActionIfActive() {
        guard isActive else { return }
        appState.requestSaveAndCloseSettings = {
            save(showPopoverAfterClose: true)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selectedTab.wrappedValue {
            case .general:
                settingsCard { accountSection }
                settingsCard { displaySection }
                settingsCard { pingSection }
                settingsCard { activitySection }
            case .usage:
                settingsCard { trackedUsageSection }
                settingsCard { sessionDisplaySection }
                settingsCard {
                    TrackerSettingsSection("Usage display") {
                        toggleRow("Show weekly trend", isOn: $showHistoryChart)
                    }
                }
            case .alerts:
                settingsCard { usageAlertsSection }
                settingsCard { pingAlertsSection }
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

    @ViewBuilder
    private var serviceVisibilityRow: some View {
        if let serviceVisibility, let serviceDisplayName {
            toggleRow(
                "Show \(serviceDisplayName) dashboard",
                isOn: serviceVisibility,
                help: "Also controls this provider's menu-bar meter."
            )
        }
    }

    // MARK: - Reusable rows

    /// A clean settings row: label on the left, a small switch pinned to the
    /// right edge, like System Settings. The explicit accessibility label
    /// keeps VoiceOver working despite `labelsHidden()`.
    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String? = nil) -> some View {
        TrackerSettingsToggleRow(
            title,
            isOn: isOn,
            accent: ClaudeTheme.accent,
            clearGlass: preferClearGlass,
            helpText: help
        )
    }

    private func fieldLabel(_ text: String) -> some View {
        TrackerSettingsFieldLabel(text)
    }

    private func caption(_ text: String) -> some View {
        TrackerSettingsCaption(text)
    }

    // MARK: - Sections

    private var accountStatusText: String? {
        guard !settings.sessionKey.isEmpty else { return nil }
        guard let plan = appState.usage?.planType, !plan.isEmpty else { return "Connected" }
        return "Connected · \(plan.replacingOccurrences(of: "_", with: " ").capitalized)"
    }

    private var accountSection: some View {
        TrackerAccountSettings(connected: !settings.sessionKey.isEmpty, provider: "Claude",
            status: accountStatusText,
            error: settings.credentialPersistenceError,
            busy: isClearingLogin || appState.status == .sending || isTesting, accent: ClaudeTheme.accent,
            onLogin: { showingLogin = true }, onLogout: clearLogin) {
            if isFetchingOrganization { caption("Detecting organization…") }
            else if loginCaptured && organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add your organization ID under Keys.").font(.system(size: 11)).foregroundColor(.orange)
            }
            keysDisclosure
        }
    }

    private var displaySection: some View {
        TrackerSettingsSection("Menu display") {
            serviceVisibilityRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Collapsed by default: the organization ID and session key are captured
    /// automatically at login, so these fields exist only for manual fixes.
    private var keysDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    showManualKeys.toggle()
                }
            } label: {
                Label("Keys", systemImage: showManualKeys ? "chevron.down" : "chevron.right")
            }
            .claudeGhostButton()

            if showManualKeys {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Organization ID")
                    TextField("Filled automatically on login", text: $organizationID)
                        .textFieldStyle(.plain)
                        .claudeGlassField()
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Session key")
                    SecureField(settings.sessionKey.isEmpty ? "Paste sessionKey cookie" : settings.maskedSessionKey, text: $sessionKeyInput)
                        .textFieldStyle(.plain)
                        .claudeGlassField()
                        .help("Only needed when the built-in login cannot capture this account.")
                }
                Label(
                    settings.cookieHeader.isEmpty ? "Cookies not stored" : "Cookies stored",
                    systemImage: settings.cookieHeader.isEmpty ? "xmark.circle" : "checkmark.circle.fill"
                )
                .font(.system(size: 10))
                .help("Claude login cookies are stored in this app's Keychain item.")
            }
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(ClaudeTheme.textSecondary)
    }

    private var pingSection: some View {
        TrackerPingSettings(enabled: $scheduledPingsEnabled, message: $message,
                            accent: ClaudeTheme.accent, clearGlass: preferClearGlass) {
            Picker("Model", selection: $model) {
                ForEach(modelOptions, id: \.self) { slug in Text(modelLabel(slug)).tag(slug) }
            }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).tint(ClaudeTheme.accent)
                .help("Tries your selected model first, then falls back if Claude rejects it.")
            HStack {
                Button("Use lowest usage") { model = modelOptions.first(where: { $0.contains("haiku") }) ?? model }.claudeGhostButton()
                Button("Refresh models") { Task { await appState.refreshUsage() } }.claudeGhostButton().disabled(appState.isRefreshingUsage)
            }
        } effort: {
            EmptyView()
        } schedule: {
            TrackerScheduleEditor(slots: Binding(
                get: { slots.map { .init(hour: $0.hour, minute: $0.minute) } },
                set: { slots = $0.map { .init(hour: $0.hour, minute: $0.minute) } }
            ), accent: ClaudeTheme.accent)
        }
    }

    private var modelOptions: [String] {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = selected.isEmpty ? [] : [selected]
        let pool = appState.availableModels + UsageChecker.fallbackModels
        for slug in pool.sorted(by: { modelRank($0) < modelRank($1) }) where !options.contains(slug) {
            options.append(slug)
        }
        return options
    }

    private func modelRank(_ slug: String) -> Int {
        if slug.contains("haiku") { return 0 }
        if slug.contains("sonnet") { return 1 }
        if slug.contains("opus") { return 2 }
        return 3
    }

    private func modelLabel(_ slug: String) -> String {
        TrackerModelLabels.claude(slug)
    }

    private var activitySection: some View {
        TrackerActivitySettings(successRate: successRateText, lastResult: stats.lastRecord?.summary ?? "—",
            activeModel: appState.activeModel.map { TrackerModelLabels.claude($0) },
            hasChat: !settings.conversationID.isEmpty, canStartFresh: !settings.conversationID.isEmpty,
            busy: appState.status == .sending || isTesting, error: appState.lastError,
            onOpen: {
                if let url = URL(string: "https://claude.ai/chat/\(settings.conversationID)") { NSWorkspace.shared.open(url) }
            }, onStartFresh: { settings.conversationID = "" })
    }

    private var successRateText: String {
        guard stats.totalCount > 0 else { return "No pings yet" }
        return "\(stats.successCount)/\(stats.totalCount) (\(Int(stats.successRate * 100))%)"
    }

    private var trackedUsageSection: some View {
        TrackerSettingsSection("Tracked usage") {
            toggleRow("Session (5 hour)", isOn: $showSessionBar, help: "Show Claude's rolling five-hour usage counter.")
            toggleRow("Weekly (7 day)", isOn: $showWeeklyBar, help: "Show Claude's weekly usage counter.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionDisplaySection: some View {
        TrackerSettingsSection("Session display") {
            TrackerSessionDisplaySettings(nextPossible: $showNextPossibleCountdown, scheduled: $showScheduledCountdown,
                focusScheduled: Binding(get: { countdownFocus == .scheduled }, set: { countdownFocus = $0 ? .scheduled : .nextPossible }),
                autoStart: $autoStartAvailableSessions, accent: ClaudeTheme.accent, clearGlass: preferClearGlass)
        }
    }

    private var usageAlertsSection: some View {
        TrackerSettingsSection("Usage alerts") {
            TrackerUsageAlertSetting("Session (5 hour)",
                enabled: thresholdEnabledBinding(selection: $sessionThresholds, defaults: SettingsStore.defaultSessionThresholds),
                thresholds: $sessionThresholds, accent: ClaudeTheme.accent, clearGlass: preferClearGlass)
            TrackerUsageAlertSetting("Weekly (7 day)",
                enabled: thresholdEnabledBinding(selection: $weeklyThresholds, defaults: SettingsStore.defaultWeeklyThresholds),
                thresholds: $weeklyThresholds, accent: ClaudeTheme.accent, clearGlass: preferClearGlass)
        }
    }

    private var pingAlertsSection: some View {
        TrackerSettingsSection("Ping alerts") {
            TrackerPingAlertSettings(failures: $notifyOnFailure, available: $notifySessionAvailable,
                sent: $notifySessionStarted, scheduled: $notifyOnSuccess,
                accent: ClaudeTheme.accent, clearGlass: preferClearGlass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serviceAlertsSection: some View {
        TrackerServiceAlertSettings(provider: "Claude", outage: $notifyOnServiceOutage, degraded: $notifyOnServiceDegraded,
            accent: ClaudeTheme.accent, clearGlass: preferClearGlass, status: appState.notificationTestStatus,
            onTest: { appState.sendTestNotification() })
    }


    private func thresholdEnabledBinding(selection: Binding<Set<Int>>, defaults: [Int]) -> Binding<Bool> {
        Binding(
            get: { !selection.wrappedValue.isEmpty },
            set: { enabled in
                selection.wrappedValue = enabled ? Set(defaults) : []
            }
        )
    }


    private var appSection: some View {
        TrackerSettingsSection("App") {
            if onOpenSystemSettings == nil { toggleRow("Launch at login", isOn: $launchAtLogin) }
            toggleRow("Command-U opens menu", isOn: $enableCommandUShortcut)
            TrackerWakeSettings(enabled: $enableScheduledWake, installed: appState.wakeHelperInstalled,
                status: appState.wakeSupportStatus, result: appState.wakeTestResult?.message, outcome: appState.wakeTestResult?.outcome.rawValue,
                accent: ClaudeTheme.accent, clearGlass: preferClearGlass, busy: appState.isInstallingWakeSupport || isTesting || appState.status == .sending,
                setupTitle: onOpenSystemSettings == nil ? "Install wake support" : "Set up in System",
                onSetup: { if let onOpenSystemSettings { onOpenSystemSettings() } else { appState.installWakeSupport() } },
                onTest: { appState.testWakeSupport() })
            toggleRow("Use clear Liquid Glass", isOn: $preferClearGlass, help: "Changes Settings glass transparency immediately.")
            Button("Clear weekly trend history") { appState.clearWeeklyHistory() }.claudeGhostButton().help("Clears local samples only.")
        }
    }

    private var updatesSection: some View {
        TrackerSettingsSection("Updates") {
            toggleRow("Install updates automatically", isOn: $autoUpdate)
            caption("Current version: \(currentVersion)")
            if let update = appState.availableUpdate {
                Text("Version \(update.version) is available.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ClaudeTheme.accent)
                if let installError = appState.installUpdateError {
                    Text(installError)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(appState.isInstallingUpdate ? "Installing\u{2026}" : "Install & Restart") {
                    appState.installUpdate()
                }
                .claudePrimaryButton()
                .disabled(appState.isInstallingUpdate)
            } else if let error = appState.updateCheckError {
                caption(error)
            } else {
                caption("You're on the latest version.")
            }
            Button(appState.isCheckingForUpdates ? "Checking\u{2026}" : "Check for updates") {
                Task { await appState.checkForUpdates() }
            }
            .claudeGhostButton()
            .disabled(appState.isCheckingForUpdates || appState.isInstallingUpdate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        TrackerSettingsFooter(
            accent: ClaudeTheme.accent,
            testTitle: isTesting ? "Testing\u{2026}" : "Test connection",
            testDisabled: isTesting,
            saveDisabled: scheduleValidationMessage != nil,
            onTest: runTest,
            onCancel: { discardChanges = true; appState.closeSettingsWindow?() },
            onSave: { save() }
        ) {
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundColor(testResult.hasPrefix("Success") ? ClaudeTheme.accent : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private var scheduleValidationMessage: String? {
        ScheduleRules.validationMessage(for: slots)
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    private func formattedTimeNumbers(hour: Int, minute: Int) -> String {
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", displayHour, minute)
    }

    private func timePeriod(hour: Int) -> String {
        hour < 12 ? "AM" : "PM"
    }

    /// Login finished: store the session and the full cookie header, then
    /// make sure the organization ID is captured too -- from the cookie when
    /// available, otherwise fetched straight from claude.ai -- and refresh
    /// usage right away so the popover fills in without waiting for the next
    /// timer tick.
    private func handleLoginCapture(sessionKey: String, organizationIDFromCookie: String?, cookieHeader: String) {
        settings.sessionKey = sessionKey
        settings.cookieHeader = cookieHeader
        sessionKeyInput = ""
        loginCaptured = true
        testResult = nil
        if let organizationIDFromCookie, !organizationIDFromCookie.isEmpty {
            organizationID = organizationIDFromCookie
            settings.organizationID = organizationIDFromCookie
            Task { await appState.refreshUsage() }
            return
        }
        isFetchingOrganization = true
        Task {
            let fetched = await UsageChecker.fetchOrganizationID(sessionKey: sessionKey, cookieHeader: cookieHeader)
            await MainActor.run {
                isFetchingOrganization = false
                if let fetched, !fetched.isEmpty {
                    organizationID = fetched
                    settings.organizationID = fetched
                }
            }
            await appState.refreshUsage()
        }
    }

    private func loadCurrentValues() {
        organizationID = settings.organizationID
        model = settings.model
        message = settings.message
        slots = settings.scheduleSlots
        launchAtLogin = settings.launchAtLogin
        notifyOnFailure = settings.notifyOnFailure
        notifyOnSuccess = settings.notifyOnSuccess
        scheduledPingsEnabled = settings.scheduledPingsEnabled
        notifyOnServiceOutage = settings.notifyOnServiceOutage
        notifyOnServiceDegraded = settings.notifyOnServiceDegraded
        sessionThresholds = Set(settings.sessionUsageThresholds)
        weeklyThresholds = Set(settings.weeklyUsageThresholds)
        showSessionBar = settings.showSessionBar
        showWeeklyBar = settings.showWeeklyBar
        showHistoryChart = settings.showHistoryChart
        showNextPossibleCountdown = settings.showNextPossibleCountdown
        showScheduledCountdown = settings.showScheduledCountdown
        countdownFocus = settings.countdownFocus
        notifySessionAvailable = settings.notifySessionAvailable
        notifySessionStarted = settings.notifySessionStarted
        autoStartAvailableSessions = settings.autoStartAvailableSessions
        enableCommandUShortcut = settings.enableCommandUShortcut
        enableScheduledWake = settings.enableScheduledWake
        preferClearGlass = settings.preferClearGlass
        autoUpdate = settings.autoUpdateEnabled
        sessionKeyInput = ""
        testResult = nil
    }

    private func clearLogin() {
        guard !isClearingLogin else { return }
        isClearingLogin = true
        Task {
            settings.sessionKey = ""
            settings.cookieHeader = ""
            settings.organizationID = ""
            organizationID = ""
            sessionKeyInput = ""
            loginCaptured = false
            await TrackerWebsiteData.clear(domains: TrackerWebsiteData.claudeDomains)
            appState.clearAccountData()
            isClearingLogin = false
        }
    }

    private func save(showPopoverAfterClose: Bool = false, closeWindow: Bool = true) {
        guard scheduleValidationMessage == nil else {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab.wrappedValue = .general }
            return
        }
        let trimmedSessionKeyInput = sessionKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSessionKeyInput.isEmpty {
            settings.sessionKey = trimmedSessionKeyInput
        }
        settings.organizationID = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = trimmedModel.isEmpty ? UsageChecker.fallbackModels[0] : trimmedModel
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.message = trimmedMessage.isEmpty ? "Say 1" : trimmedMessage
        settings.scheduleSlots = slots.sorted {
            ($0.hour, $0.minute) < ($1.hour, $1.minute)
        }
        if onOpenSystemSettings == nil {
            settings.launchAtLogin = launchAtLogin
        }
        settings.notifyOnFailure = notifyOnFailure
        settings.notifyOnSuccess = notifyOnSuccess
        settings.scheduledPingsEnabled = scheduledPingsEnabled
        settings.notifyOnServiceOutage = notifyOnServiceOutage
        settings.notifyOnServiceDegraded = notifyOnServiceDegraded
        settings.sessionUsageThresholds = sessionThresholds.sorted()
        settings.weeklyUsageThresholds = weeklyThresholds.sorted()
        settings.showSessionBar = showSessionBar
        settings.showWeeklyBar = showWeeklyBar
        settings.showHistoryChart = showHistoryChart
        settings.showNextPossibleCountdown = showNextPossibleCountdown
        settings.showScheduledCountdown = showScheduledCountdown
        settings.countdownFocus = countdownFocus
        settings.notifySessionAvailable = notifySessionAvailable
        settings.notifySessionStarted = notifySessionStarted
        settings.autoStartAvailableSessions = autoStartAvailableSessions
        settings.enableCommandUShortcut = enableCommandUShortcut
        settings.enableScheduledWake = enableScheduledWake
        settings.preferClearGlass = preferClearGlass
        settings.autoUpdateEnabled = autoUpdate
        if onOpenSystemSettings == nil {
            LoginItemManager.setEnabled(launchAtLogin)
        }
        appState.rescheduleTimer()
        appState.startAvailableSessionIfNeeded()
        if closeWindow { appState.closeSettingsWindow?() }
        if showPopoverAfterClose {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                appState.requestTogglePopover?()
            }
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let trimmedInput = sessionKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyToTest = trimmedInput.isEmpty ? settings.sessionKey : trimmedInput
        let orgToTest = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelToTest = selectedModel.isEmpty ? UsageChecker.fallbackModels[0] : selectedModel
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageToTest = trimmedMessage.isEmpty ? "Say 1" : trimmedMessage
        // A manually pasted key can't be paired with the stored cookies (they
        // belong to the previous session), so fall back to just that key.
        let cookieHeaderToTest = trimmedInput.isEmpty ? settings.effectiveCookieHeader : "sessionKey=\(keyToTest)"
        Task {
            testResult = await appState.testConnection(configuration: .init(
                sessionKey: keyToTest, organizationID: orgToTest, cookieHeader: cookieHeaderToTest,
                model: modelToTest, message: messageToTest
            ))
            isTesting = false
        }
    }
}

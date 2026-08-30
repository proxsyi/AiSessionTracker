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

    @State private var sessionKeyInput = ""
    @State private var organizationID = ""
    @State private var model = ""
    @State private var message = ""
    @State private var slots: [ScheduleSlot] = []
    @State private var launchAtLogin = false
    @State private var notifyOnFailure = true
    @State private var notifyOnServiceOutage = true
    @State private var notifyOnServiceDegraded = true
    @State private var sessionThresholds: Set<Int> = []
    @State private var weeklyThresholds: Set<Int> = []
    @State private var showSessionBar = true
    @State private var showWeeklyBar = true
    @State private var showNextPossibleCountdown = true
    @State private var showScheduledCountdown = true
    @State private var countdownFocus: CountdownFocus = .nextPossible
    @State private var notifySessionAvailable = true
    @State private var notifySessionStarted = true
    @State private var autoStartAvailableSessions = false
    @State private var enableCommandUShortcut = true
    @State private var enableScheduledWake = true
    @State private var preferClearGlass = true
    @State private var selectedTab: TrackerSettingsTab = .general
    @State private var autoUpdate = true
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showingLogin = false
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
        onOpenSystemSettings: (() -> Void)? = nil
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
    }

    var body: some View {
        TrackerSettingsWindow(
            selectedTab: $selectedTab,
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
            loadCurrentValues()
            appState.refreshWakeTestResult()
            installSaveActionIfActive()
        }
        .onChange(of: isActive) { active in
            if active {
                loadCurrentValues()
                installSaveActionIfActive()
            } else if saveOnDisappear {
                save(closeWindow: false)
            }
        }
        .onDisappear {
            if saveOnDisappear && isActive { save(closeWindow: false) }
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
            switch selectedTab {
            case .general:
                settingsCard { accountSection }
                settingsCard { displaySection }
                settingsCard { pingSection }
                settingsCard { activitySection }
            case .usage:
                settingsCard { trackedUsageSection }
                settingsCard { sessionDisplaySection }
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

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Account")

            Button(loginCaptured || !settings.sessionKey.isEmpty ? "Log in again" : "Log in with Claude") {
                showingLogin = true
            }
            .claudePrimaryButton()

            if loginCaptured {
                Text("Signed in -- session and cookies captured automatically.")
                    .font(.system(size: 11))
                    .foregroundColor(ClaudeTheme.accent)
            } else if !settings.sessionKey.isEmpty {
                caption("Using a previously captured session (\(settings.maskedSessionKey)).")
            }
            if let error = settings.credentialPersistenceError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isFetchingOrganization {
                caption("Detecting your organization ID\u{2026}")
            } else if loginCaptured && organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Organization ID not detected. Add lastActiveOrg under Keys.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Open claude.ai, then use Developer Tools → Application → Cookies and paste lastActiveOrg under Keys.")
            }

            keysDisclosure
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Menu display")
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
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Ping")

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Model")
                Picker("Model", selection: $model) {
                    ForEach(modelOptions, id: \.self) { slug in
                        Text(modelLabel(slug)).tag(slug)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(ClaudeTheme.accent)
                .help("Tries your selected model first, then falls back if Claude rejects it.")
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Message")
                TextField("Say 1", text: $message)
                    .textFieldStyle(.plain)
                    .claudeGlassField()
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Schedule")
                ForEach(slots.indices, id: \.self) { index in
                    HStack {
                        Stepper(value: Binding(
                            get: { slots[index].hour },
                            set: { slots[index].hour = $0 }
                        ), in: 0...23) {
                            HStack(spacing: 6) {
                                Text(formattedTimeNumbers(hour: slots[index].hour, minute: slots[index].minute))
                                    .frame(width: 40, alignment: .trailing)
                                Text(timePeriod(hour: slots[index].hour))
                                    .frame(width: 22, alignment: .leading)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(ClaudeTheme.textPrimary)
                        }
                        .controlSize(.small)
                        Spacer()
                        Button(action: { slots.remove(at: index) }) {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(ClaudeTheme.textSecondary)
                        .help("Remove time")
                    }
                }
                Button("Add time") {
                    if let hour = ScheduleRules.firstAvailableHour(addingTo: slots) {
                        slots.append(ScheduleSlot(hour: hour, minute: 0))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ClaudeTheme.accent)
                .disabled(ScheduleRules.firstAvailableHour(addingTo: slots) == nil)

                if let scheduleValidationMessage {
                    Text(scheduleValidationMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    EmptyView()
                }
            }
            .help("Scheduled pings must be at least five hours apart, including overnight.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if slug.contains("haiku") { return "Haiku (suggested) — \(slug)" }
        if slug.contains("sonnet") { return "Sonnet — \(slug)" }
        if slug.contains("opus") { return "Opus — \(slug)" }
        return slug
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Activity")

            HStack {
                fieldLabel("Success rate")
                Spacer()
                Text(successRateText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(ClaudeTheme.textPrimary)
            }

            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Last result")
                Spacer()
                Text(stats.lastRecord?.summary ?? "—")
                    .font(.system(size: 11))
                    .foregroundColor(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }

            if let error = appState.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let activeModel = appState.activeModel {
                caption("Last successful model: \(activeModel)")
            }

            caption(settings.conversationID.isEmpty
                ? "The next ping will create one dedicated Claude chat and reuse it afterward."
                : "Pings are reusing one dedicated Claude chat.")

            if !settings.conversationID.isEmpty {
                HStack {
                    Button("Open pinger chat") {
                        if let url = URL(string: "https://claude.ai/chat/\(settings.conversationID)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .claudeGhostButton()
                    Spacer()
                    Button("Start fresh chat") {
                        settings.conversationID = ""
                    }
                    .claudeGhostButton()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var successRateText: String {
        guard stats.totalCount > 0 else { return "No pings yet" }
        return "\(stats.successCount)/\(stats.totalCount) (\(Int(stats.successRate * 100))%)"
    }

    private var trackedUsageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Tracked usage")
            toggleRow("Session (5 hour)", isOn: $showSessionBar, help: "Show Claude's rolling five-hour usage counter.")
            toggleRow("Weekly (7 day)", isOn: $showWeeklyBar, help: "Show Claude's weekly usage counter.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionDisplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Session display")
            toggleRow("Next possible session", isOn: $showNextPossibleCountdown, help: "Show when Claude's active five-hour window resets.")
            toggleRow("Scheduled session", isOn: $showScheduledCountdown, help: "Show the next saved ping time.")
            if showNextPossibleCountdown && showScheduledCountdown {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Main focus")
                    Picker("Main focus", selection: $countdownFocus) {
                        ForEach(CountdownFocus.allCases) { focus in
                            Text(focus.label).tag(focus)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(ClaudeTheme.accent)
                    .help("The other enabled countdown appears underneath in gray.")
                }
            }
            toggleRow(
                "Start sessions when available",
                isOn: $autoStartAvailableSessions,
                help: "Starts an available session unless a scheduled ping is due within five hours."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usageAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Usage alerts")
            toggleRow("Session (5 hour)", isOn: thresholdEnabledBinding(selection: $sessionThresholds, defaults: SettingsStore.defaultSessionThresholds), help: "Notify when this counter crosses a selected threshold.")
            thresholdButtons(selection: $sessionThresholds)
                .disabled(sessionThresholds.isEmpty)
            toggleRow("Weekly (7 day)", isOn: thresholdEnabledBinding(selection: $weeklyThresholds, defaults: SettingsStore.defaultWeeklyThresholds), help: "Notify when this counter crosses a selected threshold.")
            thresholdButtons(selection: $weeklyThresholds)
                .disabled(weeklyThresholds.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pingAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Ping alerts")
            toggleRow("Ping failures", isOn: $notifyOnFailure)
            toggleRow("New session available", isOn: $notifySessionAvailable)
            toggleRow("Session started by app", isOn: $notifySessionStarted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serviceAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Service alerts")
            toggleRow("Claude service outages", isOn: $notifyOnServiceOutage)
            toggleRow("Claude degraded performance", isOn: $notifyOnServiceDegraded)
            Button("Send test notification") {
                appState.sendTestNotification()
            }
            .claudeGhostButton()
            if let status = appState.notificationTestStatus {
                caption(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func thresholdButtons(selection: Binding<Set<Int>>) -> some View {
        TrackerSettingsThresholdPicker(
            values: SettingsStore.availableThresholds,
            selection: selection,
            accent: ClaudeTheme.accent,
            clearGlass: preferClearGlass
        )
    }

    private func thresholdEnabledBinding(selection: Binding<Set<Int>>, defaults: [Int]) -> Binding<Bool> {
        Binding(
            get: { !selection.wrappedValue.isEmpty },
            set: { enabled in
                selection.wrappedValue = enabled ? Set(defaults) : []
            }
        )
    }

    private func wakeTestResultSymbol(_ outcome: WakeTestOutcome) -> String {
        switch outcome {
        case .pending: return "clock"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func wakeTestResultColor(_ outcome: WakeTestOutcome) -> Color {
        switch outcome {
        case .pending: return ClaudeTheme.textSecondary
        case .passed: return ClaudeTheme.accent
        case .failed: return .orange
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "App")
            if onOpenSystemSettings == nil {
                toggleRow("Launch at login", isOn: $launchAtLogin)
            }
            toggleRow("Command-U opens menu", isOn: $enableCommandUShortcut)
            toggleRow(
                "Wake Mac for scheduled pings",
                isOn: $enableScheduledWake,
                help: "Uses the shared system helper. Claude and Codex keep separate schedules. Keep the Mac connected to power."
            )
            if enableScheduledWake {
                if let result = appState.wakeTestResult {
                    Label(result.message, systemImage: wakeTestResultSymbol(result.outcome))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(wakeTestResultColor(result.outcome))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if !appState.wakeHelperInstalled {
                        if let onOpenSystemSettings {
                            Button("Set up in System") { onOpenSystemSettings() }
                                .claudeGhostButton()
                        } else {
                            Button(appState.isInstallingWakeSupport ? "Installing\u{2026}" : "Install wake support") {
                                appState.installWakeSupport()
                            }
                            .claudePrimaryButton()
                            .disabled(appState.isInstallingWakeSupport)
                        }
                    } else {
                        Button("Run 2-minute closed-lid test") {
                            appState.testWakeSupport()
                        }
                        .claudeGhostButton()
                    }
                }
                if !appState.wakeHelperInstalled {
                    caption("Setup required")
                }
            }
            toggleRow("Use clear Liquid Glass", isOn: $preferClearGlass, help: "Changes Settings glass transparency immediately.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Updates")
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
            onCancel: { appState.closeSettingsWindow?() },
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
        notifyOnServiceOutage = settings.notifyOnServiceOutage
        notifyOnServiceDegraded = settings.notifyOnServiceDegraded
        sessionThresholds = Set(settings.sessionUsageThresholds)
        weeklyThresholds = Set(settings.weeklyUsageThresholds)
        showSessionBar = settings.showSessionBar
        showWeeklyBar = settings.showWeeklyBar
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

    private func save(showPopoverAfterClose: Bool = false, closeWindow: Bool = true) {
        guard scheduleValidationMessage == nil else {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = .general }
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
        settings.notifyOnServiceOutage = notifyOnServiceOutage
        settings.notifyOnServiceDegraded = notifyOnServiceDegraded
        settings.sessionUsageThresholds = sessionThresholds.sorted()
        settings.weeklyUsageThresholds = weeklyThresholds.sorted()
        settings.showSessionBar = showSessionBar
        settings.showWeeklyBar = showWeeklyBar
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
            do {
                let outcome = try await ClaudeClient.sendPing(
                    sessionKey: keyToTest,
                    organizationID: orgToTest,
                    model: modelToTest,
                    message: messageToTest,
                    conversationID: settings.conversationID,
                    cookieHeader: cookieHeaderToTest
                )
                await MainActor.run {
                    settings.conversationID = outcome.conversationID
                    testResult = outcome.matchedExpected ? "Success: got reply" : "Connected, but Claude returned an empty reply"
                    isTesting = false
                }
            } catch {
                let description = (error as? PingError)?.localizedDescription ?? error.localizedDescription
                await MainActor.run {
                    testResult = description
                    isTesting = false
                }
            }
        }
    }
}

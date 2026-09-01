import SwiftUI

/// Provider pages supply data and actions; layout, typography and ordering live here.
public struct TrackerSettingsSection<Content: View>: View {
    let title: String
    let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrackerSectionHeader(text: title)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct TrackerAccountSettings<Details: View>: View {
    let connected: Bool
    let provider: String
    let status: String?
    let error: String?
    let busy: Bool
    let accent: Color
    let onLogin: () -> Void
    let onLogout: () -> Void
    let details: Details
    public init(connected: Bool, provider: String, status: String?, error: String?, busy: Bool,
                accent: Color, onLogin: @escaping () -> Void, onLogout: @escaping () -> Void,
                @ViewBuilder details: () -> Details) {
        self.connected = connected; self.provider = provider; self.status = status; self.error = error
        self.busy = busy; self.accent = accent; self.onLogin = onLogin; self.onLogout = onLogout
        self.details = details()
    }
    public var body: some View {
        TrackerSettingsSection("Account") {
            Button(connected ? "Log in again" : "Log in with \(provider)", action: onLogin)
                .trackerPrimaryButton(accent: accent).disabled(busy)
            if connected {
                Button("Log out", action: onLogout).trackerGhostButton().disabled(busy)
                    .help("Clears this provider's saved login and app-browser cookies.")
            }
            if let status { TrackerSettingsCaption(status) }
            if let error { Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            details
        }
    }
}

public struct TrackerPingSettings<Model: View, Effort: View, Schedule: View>: View {
    @Binding var enabled: Bool
    @Binding var message: String
    let accent: Color
    let clearGlass: Bool
    let model: Model
    let effort: Effort
    let schedule: Schedule
    public init(enabled: Binding<Bool>, message: Binding<String>, accent: Color, clearGlass: Bool,
                @ViewBuilder model: () -> Model, @ViewBuilder effort: () -> Effort,
                @ViewBuilder schedule: () -> Schedule) {
        _enabled = enabled; _message = message; self.accent = accent; self.clearGlass = clearGlass
        self.model = model(); self.effort = effort(); self.schedule = schedule()
    }
    public var body: some View {
        TrackerSettingsSection("Ping") {
            TrackerSettingsToggleRow("Schedule pings", isOn: $enabled, accent: accent, clearGlass: clearGlass,
                                     helpText: "Send scheduled pings in one dedicated chat.")
            VStack(alignment: .leading, spacing: 6) {
                TrackerSettingsFieldLabel("Model")
                model
            }
            effort
            VStack(alignment: .leading, spacing: 4) {
                TrackerSettingsFieldLabel("Message")
                TextField("Say 1", text: $message).textFieldStyle(.plain)
                    .modifier(TrackerGlassField(clearGlass: clearGlass))
            }
            schedule
        }
    }
}

public struct TrackerActivitySettings: View {
    let successRate: String
    let lastResult: String
    let activeModel: String?
    let hasChat: Bool
    let canStartFresh: Bool
    let busy: Bool
    let error: String?
    let onOpen: () -> Void
    let onStartFresh: () -> Void
    public init(successRate: String, lastResult: String, activeModel: String?, hasChat: Bool,
                canStartFresh: Bool, busy: Bool, error: String?, onOpen: @escaping () -> Void,
                onStartFresh: @escaping () -> Void) {
        self.successRate = successRate; self.lastResult = lastResult; self.activeModel = activeModel
        self.hasChat = hasChat; self.canStartFresh = canStartFresh; self.busy = busy; self.error = error
        self.onOpen = onOpen; self.onStartFresh = onStartFresh
    }
    public var body: some View {
        TrackerSettingsSection("Activity") {
            HStack {
                TrackerSettingsFieldLabel("Success rate")
                Spacer()
                Text(successRate).font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            HStack(alignment: .firstTextBaseline) {
                TrackerSettingsFieldLabel("Last result")
                Spacer()
                Text(lastResult).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.trailing)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            if let activeModel { TrackerSettingsCaption("Last successful model: \(activeModel)") }
            TrackerSettingsCaption(hasChat ? "Reusing one dedicated chat." : "Created by the first ping.")
            if hasChat || canStartFresh {
                HStack {
                    if hasChat { Button("Open pinger chat", action: onOpen).trackerGhostButton() }
                    Spacer()
                    Button("Start fresh chat", action: onStartFresh).trackerGhostButton().disabled(busy)
                }
            }
        }
    }
}

public struct TrackerUsageAlertSetting: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var thresholds: Set<Int>
    let supportsPercentage: Bool
    let accent: Color
    let clearGlass: Bool
    public init(_ title: String, enabled: Binding<Bool>, thresholds: Binding<Set<Int>>,
                supportsPercentage: Bool = true, accent: Color, clearGlass: Bool) {
        self.title = title; _enabled = enabled; _thresholds = thresholds
        self.supportsPercentage = supportsPercentage; self.accent = accent; self.clearGlass = clearGlass
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrackerSettingsToggleRow(title, isOn: $enabled, accent: accent, clearGlass: clearGlass,
                                     helpText: "Notify at selected thresholds; counters without a percentage notify when unavailable.")
            if supportsPercentage {
                TrackerSettingsThresholdPicker(values: [25, 50, 75, 90, 95, 100], selection: $thresholds,
                                               accent: accent, clearGlass: clearGlass).disabled(!enabled)
            }
        }
    }
}

public struct TrackerWakeSettings: View {
    @Binding var enabled: Bool
    let installed: Bool
    let status: String
    let result: String?
    let outcome: String?
    let accent: Color
    let clearGlass: Bool
    let busy: Bool
    let setupTitle: String
    let onSetup: () -> Void
    let onTest: () -> Void
    public init(enabled: Binding<Bool>, installed: Bool, status: String, result: String?, outcome: String?,
                accent: Color, clearGlass: Bool, busy: Bool, setupTitle: String,
                onSetup: @escaping () -> Void, onTest: @escaping () -> Void) {
        _enabled = enabled; self.installed = installed; self.status = status; self.result = result; self.outcome = outcome
        self.accent = accent; self.clearGlass = clearGlass; self.busy = busy; self.setupTitle = setupTitle
        self.onSetup = onSetup; self.onTest = onTest
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrackerSettingsToggleRow("Wake Mac for scheduled pings", isOn: $enabled, accent: accent, clearGlass: clearGlass,
                helpText: "Uses the shared system helper with separate provider schedules. Keep the Mac connected to power.")
            if enabled {
                TrackerSettingsCaption(status)
                if let result {
                    Label(result, systemImage: outcome == "passed" ? "checkmark.circle.fill" : outcome == "failed" ? "xmark.circle.fill" : "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(outcome == "failed" ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(installed ? "Run 2-minute closed-lid test" : setupTitle, action: installed ? onTest : onSetup)
                    .trackerGhostButton().disabled(busy)
            }
        }
    }
}

public struct TrackerServiceAlertSettings: View {
    let provider: String
    @Binding var outage: Bool
    @Binding var degraded: Bool
    let accent: Color
    let clearGlass: Bool
    let status: String?
    let onTest: () -> Void
    public init(provider: String, outage: Binding<Bool>, degraded: Binding<Bool>, accent: Color,
                clearGlass: Bool, status: String?, onTest: @escaping () -> Void) {
        self.provider = provider; _outage = outage; _degraded = degraded; self.accent = accent
        self.clearGlass = clearGlass; self.status = status; self.onTest = onTest
    }
    public var body: some View {
        TrackerSettingsSection("Service alerts") {
            TrackerSettingsToggleRow("\(provider) service outages", isOn: $outage, accent: accent, clearGlass: clearGlass)
            TrackerSettingsToggleRow("\(provider) degraded performance", isOn: $degraded, accent: accent, clearGlass: clearGlass)
            Button("Send test notification", action: onTest).trackerGhostButton()
            if let status { TrackerSettingsCaption(status) }
        }
    }
}

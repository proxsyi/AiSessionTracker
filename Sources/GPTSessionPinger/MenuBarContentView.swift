import SwiftUI
import AppKit
import Combine

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var now = Date()

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let update = appState.availableUpdate {
                updateBanner(update)
                    .padding(14)
                    .glassPanel()
            }
            usageSection
                .padding(14)
                .glassPanel()
            if settings.showNextPossibleCountdown || settings.showScheduledCountdown {
                countdownSection
                    .padding(14)
                    .glassPanel()
            }
            actionsSection
        }
        .gptGlassContainer(spacing: 12)
        .environment(\.gptClearGlass, settings.preferClearGlass)
        .padding(16)
        .frame(width: 320)
        .background(WindowGlassBackground(clearGlass: settings.preferClearGlass).ignoresSafeArea())
        .onReceive(clockTimer) { value in
            now = value
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("GPT Session Pinger")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(GPTTheme.textPrimary)
            Spacer()
        }
    }

    private func updateBanner(_ update: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.green)
                Text("Version \(update.version) is available")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(GPTTheme.textPrimary)
            }
            if let notes = update.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundColor(GPTTheme.textSecondary)
                    .lineLimit(2)
            }
            if let installError = appState.installUpdateError {
                Text(installError)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(appState.isInstallingUpdate ? "Installing\u{2026}" : "Install & Restart") {
                    appState.installUpdate()
                }
                .gptGhostButton()
                .disabled(appState.isInstallingUpdate)
                Button("View release") {
                    if let url = URL(string: update.releasePageURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .gptGhostButton()
                .disabled(appState.isInstallingUpdate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle:
            return .gray
        case .sending:
            return .yellow
        case .success:
            return GPTTheme.accent
        case .failure:
            return .red
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: usageHeader)

            if visibleUsageTracks.isEmpty {
                Text(appState.usage == nil ? "No usage data yet" : "This account did not report a trackable counter.")
                    .font(.system(size: 11))
                    .foregroundColor(GPTTheme.textSecondary)
            } else {
                ForEach(visibleUsageTracks) { track in
                    usageRow(track)
                }
            }
            if let error = appState.usageError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            serviceStatusRow

            HStack {
                Text(lastUpdatedText)
                    .font(.system(size: 10))
                    .foregroundColor(GPTTheme.textSecondary)
                Spacer()
                Button(appState.isRefreshingUsage ? "Refreshing\u{2026}" : "Refresh") {
                    Task { await appState.refreshUsage() }
                }
                .gptGhostButton()
                .disabled(appState.isRefreshingUsage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usageHeader: String {
        let plan = appState.usage?.planType ?? settings.accountPlanType
        guard !plan.isEmpty else { return "ChatGPT usage" }
        return "ChatGPT usage · \(plan.replacingOccurrences(of: "_", with: " ").capitalized)"
    }

    private var visibleUsageTracks: [GPTUsageTrack] {
        guard let tracks = appState.usage?.tracks else { return [] }
        return tracks.filter { track in
            if track.scope == .codex && track.windowSeconds == 18_000 { return settings.showSessionBar }
            if track.scope == .codex && track.windowSeconds == 604_800 { return settings.showWeeklyBar }
            return true
        }
    }

    private func usageRow(_ track: GPTUsageTrack) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(track.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(GPTTheme.textPrimary)
                Spacer()
                Text(track.usedPercent.map { "\($0)%" } ?? track.valueText ?? track.remaining.map { "\($0) left" } ?? "--")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(track.isBlocked ? .red : usageBarColor(percent: track.usedPercent))
            }
            if track.usedPercent != nil {
                UsageBar(percent: track.usedPercent, color: usageBarColor(percent: track.usedPercent))
            }
            if let detail = usageDetail(track) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(GPTTheme.textSecondary)
            }
        }
    }

    private func usageDetail(_ track: GPTUsageTrack) -> String? {
        var parts: [String] = []
        if let remainingText = track.remainingText { parts.append(remainingText) }
        if let reset = track.resetsAt {
            parts.append("Resets \(reset.formatted(date: reset.timeIntervalSinceNow > 86_400 ? .abbreviated : .omitted, time: .shortened))")
        }
        if track.isBlocked { parts.append("Currently blocked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func usageBarColor(percent: Int?) -> Color {
        guard let percent else { return .gray }
        if percent < 70 { return .green }
        if percent < 90 { return .yellow }
        return .red
    }

    private var serviceStatusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(serviceStatusColor)
                    .frame(width: 7, height: 7)
                Text(appState.serviceStatus?.message ?? "Checking OpenAI service status\u{2026}")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(GPTTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(serviceStatusDetail)
                .font(.system(size: 10))
                .foregroundColor(GPTTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: "https://status.openai.com") {
                NSWorkspace.shared.open(url)
            }
        }
        .help("Open OpenAI Status")
    }

    private var serviceStatusColor: Color {
        switch appState.serviceStatus?.level {
        case .operational:
            return .green
        case .degraded:
            return .orange
        case .outage:
            return .red
        case nil:
            return .gray
        }
    }

    private var serviceStatusDetail: String {
        var text = "Tracks ChatGPT and OpenAI services"
        if let checked = appState.serviceStatus?.checkedAt {
            text += " \u{00B7} checked \(relativeTimeText(since: checked))"
        }
        return text
    }

    private func relativeTimeText(since date: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60)h ago"
    }

    private var lastUpdatedText: String {
        guard let fetched = appState.usage?.fetchedAt else { return "Not updated yet" }
        return "Last updated: \(fetched.formatted(date: .omitted, time: .shortened))"
    }

    private var countdownSection: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(text: primaryCountdownTitle)
                Text(primaryCountdownText)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(GPTTheme.textPrimary)
                if let secondaryText = secondaryCountdownText {
                    Text(secondaryText)
                        .font(.system(size: 10))
                        .foregroundColor(GPTTheme.textSecondary.opacity(0.8))
                }
            }
            Spacer(minLength: 4)
            Button(appState.status == .sending ? "Sending\u{2026}" : "Ping now") {
                appState.pingNow()
            }
            .gptPrimaryButton()
            .disabled(appState.status == .sending)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionAvailability: SessionAvailability {
        SessionAvailabilityResolver.resolve(
            usage: appState.usage,
            model: settings.model,
            availableModels: appState.availableModels,
            now: now
        )
    }

    private var nextPossibleSessionDate: Date? {
        if case .waiting(let reset) = sessionAvailability { return reset }
        return nil
    }

    private var effectiveCountdownFocus: CountdownFocus {
        if settings.showNextPossibleCountdown && settings.showScheduledCountdown {
            return settings.countdownFocus
        }
        return settings.showScheduledCountdown ? .scheduled : .nextPossible
    }

    private var primaryCountdownTitle: String {
        guard settings.showNextPossibleCountdown || settings.showScheduledCountdown else {
            return "Session countdowns"
        }
        if effectiveCountdownFocus == .scheduled { return "Next scheduled session in" }
        return nextPossibleSessionDate == nil ? "Next possible session" : "Next possible session in"
    }

    private var primaryCountdownText: String {
        guard settings.showNextPossibleCountdown || settings.showScheduledCountdown else { return "Hidden" }
        if effectiveCountdownFocus == .nextPossible {
            switch sessionAvailability {
            case .availableNow: return "Available now"
            case .unavailable: return "Unavailable"
            case .waiting(let reset): return durationText(until: reset)
            }
        }
        let date = appState.nextFireDate
        guard let date else { return "Unavailable" }
        return durationText(until: date)
    }

    private var secondaryCountdownText: String? {
        if effectiveCountdownFocus == .nextPossible,
           settings.showScheduledCountdown,
           let scheduled = appState.nextFireDate {
            let time = scheduled.formatted(date: .omitted, time: .shortened)
            return "Scheduled session in \(durationText(until: scheduled)) · \(time)"
        }
        if effectiveCountdownFocus == .scheduled, settings.showNextPossibleCountdown {
            switch sessionAvailability {
            case .availableNow:
                return "Next possible session: Available now"
            case .waiting(let possible):
                let time = possible.formatted(date: .omitted, time: .shortened)
                return "Next possible session in \(durationText(until: possible)) · \(time)"
            case .unavailable:
                return nil
            }
        }
        return nil
    }

    private func durationText(until date: Date) -> String {
        let remaining = max(0, date.timeIntervalSince(now))
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm %02ds", minutes, seconds)
    }

    private var actionsSection: some View {
        HStack {
            Button("Settings") {
                appState.requestShowSettings?()
                appState.requestClosePopover?()
            }
            .gptGhostButton()
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .gptGhostButton()
        }
    }
}

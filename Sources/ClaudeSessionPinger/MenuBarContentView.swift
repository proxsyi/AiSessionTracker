import SwiftUI
import AppKit
import Combine
import TrackerDesignSystem

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var now = Date()
    let embedded: Bool

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    @ViewBuilder
    var body: some View {
        if embedded {
            TrackerMenuStack {
                if let update = appState.availableUpdate {
                    menuCard { updateBanner(update) }
                }
                menuCard { usageSection }
                menuCard { serviceStatusSection }
                if settings.showNextPossibleCountdown || settings.showScheduledCountdown {
                    menuCard { countdownSection }
                }
                weeklyTrend
            }
            .environment(\.claudeClearGlass, settings.preferClearGlass)
            .onReceive(clockTimer) { value in now = value }
        } else {
            TrackerMenuStack {
                header
                if let update = appState.availableUpdate {
                    menuCard { updateBanner(update) }
                }
                menuCard { usageSection }
                menuCard { serviceStatusSection }
                if settings.showNextPossibleCountdown || settings.showScheduledCountdown {
                    menuCard { countdownSection }
                }
                weeklyTrend
                actionsSection
            }
            .environment(\.claudeClearGlass, settings.preferClearGlass)
            .padding(16)
            .frame(width: 320)
            .background(WindowGlassBackground(clearGlass: settings.preferClearGlass).ignoresSafeArea())
            .onReceive(clockTimer) { value in now = value }
        }
    }

    @ViewBuilder
    private var weeklyTrend: some View {
        if settings.showHistoryChart && settings.showWeeklyBar {
            menuCard {
                TrackerWeeklyTrend(title: "Claude weekly trend",
                    points: appState.weeklyHistory.points(for: "claude-weekly", since: now.addingTimeInterval(-7 * 86_400)),
                    color: ClaudeTheme.accent)
            }
        }
    }

    private func menuCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        TrackerMenuCard(clearGlass: settings.preferClearGlass, content: content)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("Session Pinger")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ClaudeTheme.textPrimary)
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
                    .foregroundColor(ClaudeTheme.textPrimary)
            }
            if let notes = update.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundColor(ClaudeTheme.textSecondary)
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
                .claudeGhostButton()
                .disabled(appState.isInstallingUpdate)
                Button("View release") {
                    if let url = URL(string: update.releasePageURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .claudeGhostButton()
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
            return ClaudeTheme.accent
        case .failure:
            return .red
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "Claude usage")

            if settings.showSessionBar {
                usageRow(
                    title: "Session (5 hour)",
                    percent: appState.usage?.sessionPercent,
                    resetText: sessionResetText
                )
            }
            if settings.showWeeklyBar {
                usageRow(
                    title: "Weekly (7 day)",
                    percent: appState.usage?.weeklyPercent,
                    resetText: weeklyResetText
                )
            }

            if let error = appState.usageError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            refreshRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serviceStatusSection: some View {
        serviceStatusRow
    }

    private var refreshRow: some View {
        HStack {
            Text(lastUpdatedText)
                .font(.system(size: 10))
                .foregroundColor(ClaudeTheme.textSecondary)
            Spacer()
            Button(appState.isRefreshingUsage ? "Refreshing\u{2026}" : "Refresh") {
                Task { await appState.refreshUsage() }
            }
            .claudeGhostButton()
            .disabled(appState.isRefreshingUsage)
        }
    }

    private func usageRow(title: String, percent: Int?, resetText: String?, missingText: String = "No data yet") -> some View {
        TrackerMenuUsageRow(
            title: title,
            value: percent.map { "\($0)%" } ?? "--",
            percent: percent,
            detail: resetText,
            missingDetail: missingText,
            valueColor: usageBarColor(percent: percent),
            clearGlass: settings.preferClearGlass
        )
    }

    private func usageBarColor(percent: Int?) -> Color {
        guard let percent else { return .gray }
        if percent < 70 { return .green }
        if percent < 90 { return .yellow }
        return .red
    }

    private var serviceStatusRow: some View {
        TrackerMenuServiceStatus(
            message: appState.serviceStatus?.message ?? "Checking Claude service status\u{2026}",
            detail: serviceStatusDetail,
            statusColor: serviceStatusColor,
            help: "Open Claude Status"
        ) {
            if let url = URL(string: "https://status.claude.com") {
                NSWorkspace.shared.open(url)
            }
        }
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
        var text = "Tracks claude.ai, Claude Console, Claude API, Claude Code +1"
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

    private var sessionResetText: String? {
        guard let date = appState.usage?.sessionResetsAt else { return nil }
        return "Resets at \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var weeklyResetText: String? {
        guard let date = appState.usage?.weeklyResetsAt else { return nil }
        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        let time = date.formatted(date: .omitted, time: .shortened)
        return "Resets on \(day) at \(time)"
    }

    private var lastUpdatedText: String {
        guard let fetched = appState.usage?.fetchedAt else { return "Not updated yet" }
        return "Last updated: \(fetched.formatted(date: .omitted, time: .shortened))"
    }

    private var countdownSection: some View {
        TrackerMenuSessionCard(
            title: primaryCountdownTitle,
            countdown: primaryCountdownText,
            secondary: secondaryCountdownText
        ) {
            Button(appState.status == .sending ? "Sending\u{2026}" : "Ping now") {
                appState.pingNow()
            }
            .claudePrimaryButton()
            .disabled(appState.status == .sending)
        }
    }

    private var nextPossibleSessionDate: Date? {
        appState.nextPossibleSessionDate(now: now)
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
        return effectiveCountdownFocus == .nextPossible
            ? "Next possible session in"
            : "Next scheduled session in"
    }

    private var primaryCountdownText: String {
        guard settings.showNextPossibleCountdown || settings.showScheduledCountdown else { return "Hidden" }
        let date = effectiveCountdownFocus == .nextPossible
            ? nextPossibleSessionDate
            : appState.nextFireDate
        guard let date else { return effectiveCountdownFocus == .scheduled ? "Off" : "Now" }
        if date.timeIntervalSince(now) <= 1 { return "Now" }
        return durationText(until: date)
    }

    private var secondaryCountdownText: String? {
        if effectiveCountdownFocus == .nextPossible,
           settings.showScheduledCountdown,
           let scheduled = appState.nextFireDate {
            let time = scheduled.formatted(date: .omitted, time: .shortened)
            return "Scheduled session in \(durationText(until: scheduled)) · \(time)"
        }
        if effectiveCountdownFocus == .scheduled,
           settings.showNextPossibleCountdown,
           let possible = nextPossibleSessionDate {
            let time = possible.formatted(date: .omitted, time: .shortened)
            return "Next possible session in \(durationText(until: possible)) · \(time)"
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
            .claudeGhostButton()
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .claudeGhostButton()
        }
    }
}

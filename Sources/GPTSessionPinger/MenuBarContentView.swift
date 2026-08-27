import AppKit
import Charts
import Combine
import SwiftUI

enum UsageDisplayTab: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case chatGPT = "ChatGPT"
    var id: String { rawValue }
}

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var history: UsageHistoryStore
    @EnvironmentObject var codexSessionPinger: CodexSessionPinger
    @State private var now = Date()
    @State private var selectedUsageTab: UsageDisplayTab = .codex
    let embeddedTab: UsageDisplayTab?

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(embeddedTab: UsageDisplayTab? = nil) {
        self.embeddedTab = embeddedTab
    }

    @ViewBuilder
    var body: some View {
        if let embeddedTab {
            VStack(alignment: .leading, spacing: 12) {
                if let update = appState.availableUpdate {
                    updateBanner(update).trackerMenuCard()
                }
                tabContent(embeddedTab)
            }
            .gptGlassContainer(spacing: 12)
            .environment(\.gptClearGlass, settings.preferClearGlass)
            .onReceive(clockTimer) { now = $0 }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let update = appState.availableUpdate {
                    updateBanner(update).trackerMenuCard()
                }
                if settings.showCategoryTabs {
                    usageTabs
                }
                usageContent
                actionsSection
            }
            .gptGlassContainer(spacing: 12)
            .environment(\.gptClearGlass, settings.preferClearGlass)
            .padding(16)
            .frame(width: 340)
            .background(WindowGlassBackground(clearGlass: settings.preferClearGlass).ignoresSafeArea())
            .onReceive(clockTimer) { now = $0 }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusBarController.sparkOrbitImage(color: StatusBarController.usageColor(percent: visibleWeeklyTrack?.usedPercent)))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("GPT Usage Tracker")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(GPTTheme.textPrimary)
                if let plan = displayedPlan {
                    Text(plan)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(GPTTheme.textSecondary)
                }
            }
            Spacer()
            if let percent = visibleWeeklyTrack?.usedPercent {
                Text("\(percent)% weekly")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(usageColor(percent))
            }
        }
    }

    private var displayedPlan: String? {
        let plan = appState.usage?.planType ?? settings.accountPlanType
        guard !plan.isEmpty else { return nil }
        return plan.replacingOccurrences(of: "_", with: " ").capitalized + " account"
    }

    private var usageTabs: some View {
        Picker("Usage category", selection: $selectedUsageTab) {
            ForEach(UsageDisplayTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var usageContent: some View {
        if settings.showCategoryTabs {
            tabContent(selectedUsageTab)
        } else {
            combinedContent
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: UsageDisplayTab) -> some View {
        let tracks = visibleTracks.filter { tab == .codex ? $0.isCodexTrack : !$0.isCodexTrack }
        VStack(alignment: .leading, spacing: 12) {
            if tab == .chatGPT {
                chatGPTUsageCard(tracks: tracks).trackerMenuCard()
            } else {
                usageCard(title: "Codex usage", tracks: tracks).trackerMenuCard()
            }
            if tab == .codex {
                codexSessionPingerCard(tracks: tracks).trackerMenuCard()
            }
            serviceStatus(for: tab).trackerMenuCard()
            if let reset = primaryResetDate(for: tracks) {
                resetCountdown(reset).trackerMenuCard()
            }
            if tab == .codex, settings.showHistoryChart, let weekly = visibleWeeklyTrack {
                historyChart(for: weekly).trackerMenuCard()
            }
        }
    }

    private func codexSessionPingerCard(tracks: [GPTUsageTrack]) -> some View {
        let next = codexSessionPinger.nextPossibleSessionDate(resetDate: codexSessionResetDate(for: tracks))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(text: "Codex session pinger")
                Spacer()
                Button(codexSessionPinger.isPinging ? "Pinging…" : "Ping now") {
                    codexSessionPinger.pingNow()
                }
                .gptPrimaryButton()
                .disabled(codexSessionPinger.isPinging || !settings.isConfigured)
            }
            Text("Next possible session in")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(GPTTheme.textPrimary)
            Text(countdownText(until: next))
                .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(GPTTheme.textPrimary)
            if let scheduled = codexSessionPinger.nextFireDate {
                Text("Scheduled ping in \(countdownText(until: scheduled)) · \(scheduled.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundColor(GPTTheme.textSecondary)
            }
            if let status = codexSessionPinger.status {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(status.contains("failed") || status.contains("expired") ? .red : GPTTheme.textSecondary)
            }
        }
    }

    private var combinedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            let codex = visibleTracks.filter(\.isCodexTrack)
            usageCard(title: "Codex usage", tracks: codex).trackerMenuCard()
            let chatGPT = visibleTracks.filter { !$0.isCodexTrack }
            chatGPTUsageCard(tracks: chatGPT).trackerMenuCard()
            serviceStatus(for: .chatGPT).trackerMenuCard()
            if let reset = primaryResetDate(for: visibleTracks) {
                resetCountdown(reset).trackerMenuCard()
            }
            if settings.showHistoryChart, let weekly = visibleWeeklyTrack {
                historyChart(for: weekly).trackerMenuCard()
            }
        }
    }

    private func usageCard(title: String, tracks: [GPTUsageTrack]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: title)
            if tracks.isEmpty {
                Text(appState.usage == nil ? "No usage data yet" : "No counters reported for this account.")
                    .font(.system(size: 11))
                    .foregroundColor(GPTTheme.textSecondary)
            } else {
                ForEach(tracks) { usageRow($0) }
            }
            if let error = appState.usageError {
                Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            refreshRow
        }
    }

    private func chatGPTUsageCard(tracks: [GPTUsageTrack]) -> some View {
        let messages = tracks.filter { $0.scope == .chatGPTModel }
        let features = tracks.filter { $0.scope == .chatGPTFeature }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "ChatGPT usage")
            Text("Message usage")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(GPTTheme.textPrimary)
            if messages.isEmpty {
                Text(appState.usage == nil
                    ? "No message data yet"
                    : "Message limits are not reported for this account.")
                    .font(.system(size: 10))
                    .foregroundColor(GPTTheme.textSecondary)
            } else {
                ForEach(messages) { usageRow($0) }
            }
            if !features.isEmpty {
                Divider().opacity(0.35)
                Text("Feature usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(GPTTheme.textPrimary)
                ForEach(features) { usageRow($0) }
            }
            if let error = appState.usageError {
                Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(appState.isPinging ? "Pinging…" : "Ping shared chat") { appState.pingChatGPT() }
                    .gptPrimaryButton().disabled(appState.isPinging || !settings.isConfigured)
                if let status = appState.pingStatus {
                    Text(status).font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary).lineLimit(2)
                }
            }
            refreshRow
        }
    }

    private func usageRow(_ track: GPTUsageTrack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(track.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(GPTTheme.textPrimary)
                Spacer()
                Text(trackValue(track))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(track.isBlocked ? .red : usageColor(track.usedPercent))
            }
            if track.usedPercent != nil {
                UsageBar(percent: track.usedPercent, color: usageColor(track.usedPercent))
            }
            if let detail = usageDetail(track) {
                Text(detail).font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
        }
    }

    private func trackValue(_ track: GPTUsageTrack) -> String {
        track.usedPercent.map { "\($0)%" }
            ?? track.valueText
            ?? track.remaining.map { "\($0) left" }
            ?? "—"
    }

    private func usageDetail(_ track: GPTUsageTrack) -> String? {
        var parts: [String] = []
        if track.usedPercent != nil, let valueText = track.valueText { parts.append(valueText) }
        if let remaining = track.remainingText { parts.append(remaining) }
        if let reset = track.resetsAt { parts.append("Resets \(reset.formatted(date: reset.timeIntervalSinceNow > 86_400 ? .abbreviated : .omitted, time: .shortened))") }
        if track.isBlocked { parts.append("Currently unavailable") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resetCountdown(_ reset: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(text: "Limits reset in")
            Text(countdownText(until: reset))
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(GPTTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(reset.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10))
                .foregroundColor(GPTTheme.textSecondary.opacity(0.8))
        }
    }

    private func historyChart(for track: GPTUsageTrack) -> some View {
        let points = history.points(for: track.preferenceID, since: now.addingTimeInterval(-7 * 86_400))
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(text: "Codex weekly trend")
            if points.count < 2 {
                Text("The chart will appear after another refresh.")
                    .font(.system(size: 10))
                    .foregroundColor(GPTTheme.textSecondary)
            } else {
                Chart(points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Usage", point.percent),
                        series: .value("Weekly window", point.series)
                    )
                        .foregroundStyle(usageColor(track.usedPercent).opacity(0.18))
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Usage", point.percent),
                        series: .value("Weekly window", point.series)
                    )
                        .foregroundStyle(usageColor(track.usedPercent))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 54)
            }
            Text("Server-reported weekly percentage · sampled locally while running")
                .font(.system(size: 9))
                .foregroundColor(GPTTheme.textSecondary)
        }
    }

    private func serviceStatus(for tab: UsageDisplayTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(serviceStatusColor).frame(width: 7, height: 7)
                Text(appState.serviceStatus?.message ?? "Checking OpenAI status…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(GPTTheme.textPrimary)
                Spacer()
            }
            Text(serviceStatusDetail(for: tab))
                .font(.system(size: 10))
                .foregroundColor(GPTTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: "https://status.openai.com") { NSWorkspace.shared.open(url) }
        }
    }

    private var refreshRow: some View {
        HStack {
            Text(lastUpdatedText).font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            Spacer()
            Button(appState.isRefreshingUsage ? "Refreshing…" : "Refresh") {
                Task { await appState.refreshUsage() }
            }
            .gptGhostButton()
            .disabled(appState.isRefreshingUsage)
        }
    }

    private func serviceStatusDetail(for tab: UsageDisplayTab) -> String {
        let services = switch tab {
        case .codex: "Tracks Codex, code review, OpenAI API, and platform services"
        case .chatGPT: "Tracks ChatGPT, file uploads, images, voice, and OpenAI services"
        }
        guard let checked = appState.serviceStatus?.checkedAt else { return services }
        return "\(services) · checked \(relativeTimeText(since: checked))"
    }

    private func relativeTimeText(since date: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60)h ago"
    }

    private var visibleTracks: [GPTUsageTrack] {
        (appState.usage?.tracks ?? []).filter { settings.isUsageTrackVisible($0.preferenceID) }
    }

    private var visibleWeeklyTrack: GPTUsageTrack? {
        guard let weekly = appState.usage?.weeklyTrack,
              settings.isUsageTrackVisible(weekly.preferenceID) else { return nil }
        return weekly
    }

    private func primaryTrack(for tracks: [GPTUsageTrack]) -> GPTUsageTrack? {
        tracks.first(where: { $0.preferenceID == "codex-weekly" })
            ?? tracks.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    private func primaryResetDate(for tracks: [GPTUsageTrack]) -> Date? {
        if let weekly = tracks.first(where: { $0.preferenceID == "codex-weekly" }),
           let reset = weekly.resetsAt,
           reset > now { return reset }
        return tracks.compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    /// The pinger's five-hour protection follows the live Codex rolling
    /// window. Weekly is deliberately not substituted here: it is a separate
    /// allowance and would make a currently available session look blocked.
    private func codexSessionResetDate(for tracks: [GPTUsageTrack]) -> Date? {
        tracks.first(where: {
            $0.isCodexTrack
                && $0.title.localizedCaseInsensitiveContains("5 hour")
                && ($0.resetsAt ?? .distantPast) > now
        })?.resetsAt
    }

    private func countdownText(until date: Date) -> String {
        let seconds = Int(max(0, date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return String(format: "%dd %02dh %02dm %02ds", days, hours, minutes, remainder)
    }

    private func usageColor(_ percent: Int?) -> Color {
        Color(nsColor: StatusBarController.usageColor(percent: percent))
    }

    private var serviceStatusColor: Color {
        switch appState.serviceStatus?.level {
        case .operational: return .green
        case .degraded: return .orange
        case .outage: return .red
        case nil: return .gray
        }
    }

    private var lastUpdatedText: String {
        guard let fetched = appState.usage?.fetchedAt else { return "Not updated yet" }
        return "Last updated: \(fetched.formatted(date: .omitted, time: .shortened))"
    }

    private func updateBanner(_ update: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Version \(update.version) is available", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(GPTTheme.textPrimary)
            HStack {
                Button(appState.isInstallingUpdate ? "Installing…" : "Install & Restart") { appState.installUpdate() }
                    .gptGhostButton().disabled(appState.isInstallingUpdate)
                Button("View release") {
                    if let url = URL(string: update.releasePageURL) { NSWorkspace.shared.open(url) }
                }
                .gptGhostButton()
            }
        }
    }

    private var actionsSection: some View {
        HStack {
            Button("Settings") {
                appState.requestShowSettings?()
                appState.requestClosePopover?()
            }
            .gptGhostButton()
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.gptGhostButton()
        }
    }
}

private extension View {
    func trackerMenuCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
    }
}

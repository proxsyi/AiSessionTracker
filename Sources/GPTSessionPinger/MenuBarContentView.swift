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
    @State private var now = Date()
    @State private var selectedUsageTab: UsageDisplayTab = .codex

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let update = appState.availableUpdate {
                updateBanner(update).padding(14).glassPanel()
            }
            if settings.showCategoryTabs {
                usageTabs
            }
            usageContent
            serviceAndRefresh
                .padding(14)
                .glassPanel()
            actionsSection
        }
        .gptGlassContainer(spacing: 12)
        .environment(\.gptClearGlass, settings.preferClearGlass)
        .padding(16)
        .frame(width: 340)
        .background(WindowGlassBackground(clearGlass: settings.preferClearGlass).ignoresSafeArea())
        .onReceive(clockTimer) { now = $0 }
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
            if tab == .codex, let weekly = visibleWeeklyTrack {
                heroTrack(weekly).padding(14).glassPanel()
                let other = tracks.filter { $0.id != weekly.id }
                if !other.isEmpty { compactTracks(title: "Other Codex limits", tracks: other).padding(14).glassPanel() }
            } else {
                compactTracks(title: tab == .codex ? "Codex usage" : "ChatGPT usage", tracks: tracks)
                    .padding(14)
                    .glassPanel()
            }
            if let reset = primaryResetDate(for: tracks) {
                resetCountdown(reset).padding(14).glassPanel()
            }
            if settings.showHistoryChart, let primary = primaryTrack(for: tracks) {
                historyChart(for: primary).padding(14).glassPanel()
            }
        }
    }

    private var combinedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let weekly = visibleWeeklyTrack {
                heroTrack(weekly).padding(14).glassPanel()
            }
            let otherCodex = visibleTracks.filter { $0.isCodexTrack && $0.preferenceID != "codex-weekly" }
            if !otherCodex.isEmpty {
                compactTracks(title: "Other Codex limits", tracks: otherCodex).padding(14).glassPanel()
            }
            let chatGPT = visibleTracks.filter { !$0.isCodexTrack }
            if !chatGPT.isEmpty {
                compactTracks(title: "ChatGPT limits", tracks: chatGPT).padding(14).glassPanel()
            }
            if let reset = primaryResetDate(for: visibleTracks) {
                resetCountdown(reset).padding(14).glassPanel()
            }
            if settings.showHistoryChart, let primary = primaryTrack(for: visibleTracks) {
                historyChart(for: primary).padding(14).glassPanel()
            }
        }
    }

    private func heroTrack(_ track: GPTUsageTrack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Codex weekly usage")
            HStack(alignment: .firstTextBaseline) {
                Text(track.usedPercent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(usageColor(track.usedPercent))
                Spacer()
                if track.isBlocked {
                    Text("LIMIT REACHED").font(.system(size: 9, weight: .bold)).foregroundColor(.red)
                }
            }
            UsageBar(percent: track.usedPercent, color: usageColor(track.usedPercent))
            if let detail = usageDetail(track) {
                Text(detail).font(.system(size: 10)).foregroundColor(GPTTheme.textSecondary)
            }
        }
    }

    private func compactTracks(title: String, tracks: [GPTUsageTrack]) -> some View {
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
        }
    }

    private func usageRow(_ track: GPTUsageTrack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(track.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(GPTTheme.textPrimary)
                Spacer()
                Text(trackValue(track))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(track.isBlocked ? .red : usageColor(track.usedPercent))
            }
            if track.usedPercent != nil {
                UsageBar(percent: track.usedPercent, color: usageColor(track.usedPercent))
            }
            if let detail = usageDetail(track) {
                Text(detail).font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
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
                .foregroundColor(GPTTheme.textSecondary)
        }
    }

    private func historyChart(for track: GPTUsageTrack) -> some View {
        let points = history.points(for: track.preferenceID, since: now.addingTimeInterval(-7 * 86_400))
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(text: "7-day sampled trend")
            if points.count < 2 {
                Text("The chart will appear after another refresh.")
                    .font(.system(size: 10))
                    .foregroundColor(GPTTheme.textSecondary)
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Usage", point.percent))
                        .foregroundStyle(usageColor(track.usedPercent).opacity(0.18))
                    LineMark(x: .value("Time", point.date), y: .value("Usage", point.percent))
                        .foregroundStyle(usageColor(track.usedPercent))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 54)
            }
            Text(track.title).font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
        }
    }

    private var serviceAndRefresh: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(serviceStatusColor).frame(width: 7, height: 7)
                Text(appState.serviceStatus?.message ?? "Checking OpenAI status…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(GPTTheme.textPrimary)
                Spacer()
            }
            HStack {
                Text(lastUpdatedText).font(.system(size: 9)).foregroundColor(GPTTheme.textSecondary)
                Spacer()
                Button(appState.isRefreshingUsage ? "Refreshing…" : "Refresh") {
                    Task { await appState.refreshUsage() }
                }
                .gptGhostButton()
                .disabled(appState.isRefreshingUsage)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: "https://status.openai.com") { NSWorkspace.shared.open(url) }
        }
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
        if let weekly = tracks.first(where: { $0.preferenceID == "codex-weekly" }), let reset = weekly.resetsAt { return reset }
        return tracks.compactMap(\.resetsAt).filter { $0 > now }.min()
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
        return "Updated \(fetched.formatted(date: .omitted, time: .shortened))"
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

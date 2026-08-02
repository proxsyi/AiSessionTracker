import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private let settings: SettingsStore
    private var popoverOpenedAt = Date.distantPast

    init(settings: SettingsStore, history: UsageHistoryStore, appState: AppState) {
        self.appState = appState
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 620)
        super.init()

        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(appState)
        )

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        updateButton()

        appState.requestClosePopover = { [weak self] in self?.closePopover() }
        appState.requestTogglePopover = { [weak self] in self?.togglePopover(nil) }

        appState.$usage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateButton() }
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            guard Date().timeIntervalSince(popoverOpenedAt) >= 0.35 else { return }
            popover.performClose(sender)
        } else {
            Task { await appState.refreshUsageIfStale() }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popoverOpenedAt = Date()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let weekly = appState.usage?.weeklyTrack
        let showWeekly = weekly.map { settings.isUsageTrackVisible($0.preferenceID) }
            ?? settings.isUsageTrackVisible("codex-weekly")
        let percent = showWeekly ? weekly?.usedPercent : nil
        let color = Self.usageColor(percent: percent)
        button.image = Self.sparkOrbitImage(color: color)
        button.title = showWeekly ? (percent.map { " \($0)%" } ?? " —%") : ""
        button.toolTip = percent.map { "GPT Usage Tracker · Codex weekly usage \($0)%" }
            ?? "GPT Usage Tracker · weekly usage unavailable"
    }

    static func usageColor(percent: Int?) -> NSColor {
        guard let percent else { return .systemGray }
        if percent < 50 { return .systemGreen }
        if percent < 75 { return .systemYellow }
        if percent < 90 { return .systemOrange }
        return .systemRed
    }

    /// Direction D refined for the real menu bar: an open orbital usage ring
    /// around a four-point intelligence spark. It reads clearly at 16px and
    /// evokes GPT without reproducing OpenAI's knot.
    static func sparkOrbitImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        color.setStroke()
        color.setFill()

        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.2, startAngle: 38, endAngle: 326, clockwise: false)
        ring.lineWidth = 1.9
        ring.lineCapStyle = .round
        ring.stroke()

        let spark = NSBezierPath()
        spark.move(to: NSPoint(x: 9, y: 5.4))
        spark.curve(to: NSPoint(x: 12.6, y: 9), controlPoint1: NSPoint(x: 9.5, y: 7.8), controlPoint2: NSPoint(x: 10.2, y: 8.5))
        spark.curve(to: NSPoint(x: 9, y: 12.6), controlPoint1: NSPoint(x: 10.2, y: 9.5), controlPoint2: NSPoint(x: 9.5, y: 10.2))
        spark.curve(to: NSPoint(x: 5.4, y: 9), controlPoint1: NSPoint(x: 8.5, y: 10.2), controlPoint2: NSPoint(x: 7.8, y: 9.5))
        spark.curve(to: NSPoint(x: 9, y: 5.4), controlPoint1: NSPoint(x: 7.8, y: 8.5), controlPoint2: NSPoint(x: 8.5, y: 7.8))
        spark.close()
        spark.fill()

        image.isTemplate = false
        return image
    }
}

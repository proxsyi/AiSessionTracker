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
    private let codexSessionPinger: CodexSessionPinger
    private var popoverOpenedAt = Date.distantPast
    private var activationObserver: NSObjectProtocol?
    private var shortcutKeyIsDown = false
    private var restoreTransientWorkItem: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    init(settings: SettingsStore, history: UsageHistoryStore, appState: AppState, codexSessionPinger: CodexSessionPinger) {
        self.appState = appState
        self.settings = settings
        self.codexSessionPinger = codexSessionPinger
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
                .environmentObject(codexSessionPinger)
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
        appState.requestTogglePopoverFromShortcut = { [weak self] in self?.togglePopoverFromShortcut() }
        appState.completePopoverShortcutPress = { [weak self] in self?.shortcutDidRelease() }

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
            guard Date().timeIntervalSince(popoverOpenedAt) >= 0.35 else {
                return
            }
            popover.performClose(sender)
        } else {
            Task { await appState.refreshUsageIfStale() }
            showPopoverAfterActivation(relativeTo: button)
        }
    }

    private func togglePopoverFromShortcut() {
        shortcutKeyIsDown = true
        restoreTransientWorkItem?.cancel()
        restoreTransientWorkItem = nil
        if !popover.isShown {
            // The key-up that completes a global shortcut counts as outside
            // interaction to a transient NSPopover. Protect the popover until
            // that physical event has completely left AppKit's event loop.
            popover.behavior = .applicationDefined
            installKeyboardDismissalMonitors()
        }
        togglePopover(nil)
    }

    private func shortcutDidRelease() {
        shortcutKeyIsDown = false
        scheduleTransientRestore()
    }

    private func scheduleTransientRestore() {
        restoreTransientWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.shortcutKeyIsDown else { return }
            self.popover.behavior = .transient
            self.restoreTransientWorkItem = nil
        }
        restoreTransientWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func installKeyboardDismissalMonitors() {
        removeKeyboardDismissalMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.popover.isShown == true else { return event }
            self?.closePopover()
            return nil
        }
    }

    private func removeKeyboardDismissalMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    /// A transient popover shown before an accessory app finishes activating
    /// is immediately dismissed by the key-up event still owned by the prior
    /// app. Wait for AppKit's activation notification, then present it.
    private func showPopoverAfterActivation(relativeTo button: NSStatusBarButton) {
        if NSApp.isActive {
            showPopover(relativeTo: button)
            return
        }

        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self, weak button] _ in
            Task { @MainActor in
                guard let self, let button else { return }
                if let activationObserver = self.activationObserver {
                    NotificationCenter.default.removeObserver(activationObserver)
                    self.activationObserver = nil
                }
                self.showPopover(relativeTo: button)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverOpenedAt = Date()
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        restoreTransientWorkItem?.cancel()
        restoreTransientWorkItem = nil
        shortcutKeyIsDown = false
        popover.behavior = .transient
        removeKeyboardDismissalMonitors()
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

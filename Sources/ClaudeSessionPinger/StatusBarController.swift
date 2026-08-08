import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private var countdownTimer: Timer?
    private var popoverOpenedAt = Date.distantPast
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var shortcutKeyIsDown = false
    private var restoreTransientWorkItem: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    init(settings: SettingsStore, stats: StatsStore, appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 560)
        self.popover = popover
        super.init()

        popover.delegate = self
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      Self.shouldCloseOnDeactivate(
                        shortcutKeyIsDown: self.shortcutKeyIsDown,
                        popoverBehavior: self.popover.behavior
                      ) else { return }
                self.closePopover()
            }
        }
        let contentView = MenuBarContentView()
            .environmentObject(settings)
            .environmentObject(stats)
            .environmentObject(appState)
        popover.contentViewController = NSHostingController(rootView: contentView)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        updateButton(usage: appState.usage)

        appState.requestClosePopover = { [weak self] in
            self?.closePopover()
        }
        appState.requestTogglePopover = { [weak self] in
            self?.togglePopover(nil)
        }
        appState.requestTogglePopoverFromShortcut = { [weak self] in
            self?.togglePopoverFromShortcut()
        }
        appState.completePopoverShortcutPress = { [weak self] in
            self?.shortcutDidRelease()
        }

        appState.$usage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.updateButton(usage: usage)
            }
            .store(in: &cancellables)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateButton(usage: self?.appState.usage)
            }
        }
    }

    deinit {
        countdownTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            guard Date().timeIntervalSince(popoverOpenedAt) >= 0.35 else { return }
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
            // A global shortcut's key-up counts as outside interaction to a
            // transient NSPopover. Protect it until the physical event has
            // completely left AppKit's event loop.
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

    /// Wait for the accessory app to finish activating before presenting a
    /// keyboard-opened popover; otherwise the prior app's event dismisses it.
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

    static func shouldCloseOnDeactivate(
        shortcutKeyIsDown: Bool,
        popoverBehavior: NSPopover.Behavior
    ) -> Bool {
        !shortcutKeyIsDown && popoverBehavior == .transient
    }

    /// Menu bar shows a color-coded sparkle plus the current session usage.
    /// At 100%, crimson and a live reset countdown replace the percentage.
    private func updateButton(usage: ClaudeUsage?) {
        guard let button = statusItem.button else { return }
        let percent = usage?.sessionPercent
        let isMaxed = (percent ?? 0) >= 100
        button.image = Self.starImage(color: isMaxed ? Self.crimson : Self.usageColor(percent: percent))
        if isMaxed, let resetsAt = usage?.sessionResetsAt {
            button.title = " \(Self.countdownText(until: resetsAt))"
        } else {
            button.title = percent.map { " \($0)%" } ?? ""
        }
    }

    static let crimson = NSColor(calibratedRed: 0.863, green: 0.078, blue: 0.235, alpha: 1)

    static func usageColor(percent: Int?) -> NSColor {
        guard let percent else { return .systemGray }
        if percent < 70 { return .systemGreen }
        if percent < 90 { return .systemYellow }
        return .systemRed
    }

    static func countdownText(until date: Date) -> String {
        let remaining = max(0, date.timeIntervalSinceNow)
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm", minutes)
    }

    /// Menu bar icon: a clean SF Symbols sparkle tinted with the usage
    /// color. Not a template image: the color carries the usage signal.
    static func starImage(color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let base = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Session Pinger")
        let image = base?.withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = false
        return image
    }
}

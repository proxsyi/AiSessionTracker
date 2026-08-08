import AppKit
import SwiftUI
import Combine
import GPTTrackerFeature

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private let gptFeature: GPTFeatureState
    private let selection: CombinedSelectionStore
    private var countdownTimer: Timer?
    private var popoverOpenedAt = Date.distantPast
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var shortcutKeyIsDown = false
    private var restoreTransientWorkItem: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    init(
        settings: SettingsStore,
        stats: StatsStore,
        appState: AppState,
        gptFeature: GPTFeatureState,
        selection: CombinedSelectionStore
    ) {
        self.appState = appState
        self.gptFeature = gptFeature
        self.selection = selection
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 540)
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
        let contentView = CombinedMenuBarContentView(gptFeature: gptFeature)
            .environmentObject(settings)
            .environmentObject(stats)
            .environmentObject(appState)
            .environmentObject(selection)
        popover.contentViewController = NSHostingController(rootView: contentView)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        updateButton()

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
            .sink { [weak self] _ in
                self?.updateButton()
            }
            .store(in: &cancellables)

        gptFeature.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateButton() }
            }
            .store(in: &cancellables)

        selection.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateButton() }
            }
            .store(in: &cancellables)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateButton()
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
            Task {
                async let claudeRefresh: Void = appState.refreshUsageIfStale()
                async let gptRefresh: Void = gptFeature.refreshIfStale()
                _ = await (claudeRefresh, gptRefresh)
            }
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

    /// Menu bar presentation follows the user's selected real Claude/GPT
    /// counters. Text retains each service's brand color while the icon keeps
    /// threshold colors as the at-a-glance usage warning.
    private func updateButton() {
        guard let button = statusItem.button else { return }
        let claudePercent = selection.claudeVisible
            ? selection.claudePercent(from: appState.usage)
            : nil
        let gptPercent = selection.gptSourceIsVisible()
            ? gptFeature.menuBarPercent(for: selection.gptMeterSourceID)
            : nil
        button.image = selection.menuBarIconVisible
            ? Self.dualUsageImage(claudePercent: claudePercent, gptPercent: gptPercent)
            : nil
        button.attributedTitle = usageMeterTitle(
            claudePercent: selection.claudePercentVisible ? claudePercent : nil,
            gptPercent: selection.gptPercentVisible ? gptPercent : nil,
            iconVisible: selection.menuBarIconVisible
        )
        let claudeText = selection.claudeVisible ? (claudePercent.map { "Claude \($0)%" } ?? "Claude unavailable") : "Claude hidden"
        let gptText = selection.gptSourceIsVisible() ? (gptPercent.map { "GPT \($0)%" } ?? "GPT unavailable") : "GPT source hidden"
        button.toolTip = "Session Tracker · \(claudeText) · \(gptText)"
    }

    private func usageMeterTitle(claudePercent: Int?, gptPercent: Int?, iconVisible: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: iconVisible ? " " : "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        var needsSeparator = false

        if let claudePercent {
            result.append(NSAttributedString(
                string: "\(claudePercent)%",
                attributes: [.font: font, .foregroundColor: NSColor(calibratedRed: 0.80, green: 0.40, blue: 0.27, alpha: 1)]
            ))
            needsSeparator = true
        }
        if let gptPercent {
            if needsSeparator {
                result.append(NSAttributedString(string: " / ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            result.append(NSAttributedString(
                string: "\(gptPercent)%",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor(calibratedRed: 0.06, green: 0.58, blue: 0.40, alpha: 1)
                ]
            ))
            needsSeparator = true
        }
        if !iconVisible && !needsSeparator && gptPercent == nil {
            result.append(NSAttributedString(
                string: "—",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return result
    }

    static func gptUsageColor(percent: Int?) -> NSColor {
        guard let percent else { return .systemGray }
        if percent < 50 { return .systemGreen }
        if percent < 75 { return .systemYellow }
        if percent < 90 { return .systemOrange }
        return .systemRed
    }

    /// Inner star represents Claude session usage; outer orbital ring
    /// represents Codex weekly usage.
    static func dualUsageImage(claudePercent: Int?, gptPercent: Int?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        if let gptPercent {
            gptUsageColor(percent: gptPercent).setStroke()
            let ring = NSBezierPath()
            ring.appendArc(
                withCenter: NSPoint(x: 9, y: 9),
                radius: 6.4,
                startAngle: 38,
                endAngle: 326,
                clockwise: false
            )
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            ring.stroke()
        }

        if let claudePercent {
            usageColor(percent: claudePercent).setFill()
            let star = NSBezierPath()
            let points: [NSPoint] = [
                NSPoint(x: 9, y: 4.9), NSPoint(x: 10.1, y: 7.9),
                NSPoint(x: 13.1, y: 9), NSPoint(x: 10.1, y: 10.1),
                NSPoint(x: 9, y: 13.1), NSPoint(x: 7.9, y: 10.1),
                NSPoint(x: 4.9, y: 9), NSPoint(x: 7.9, y: 7.9)
            ]
            star.move(to: points[0])
            for point in points.dropFirst() { star.line(to: point) }
            star.close()
            star.fill()
        }

        if claudePercent == nil && gptPercent == nil {
            NSColor.systemGray.setFill()
            NSBezierPath(ovalIn: NSRect(x: 7.1, y: 7.1, width: 3.8, height: 3.8)).fill()
        }

        image.isTemplate = false
        return image
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

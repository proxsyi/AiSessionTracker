import SwiftUI
import KeyboardShortcuts

private extension KeyboardShortcuts.Name {
    static let toggleGPTTracker = Self(
        "toggleGPTTracker",
        default: .init(.i, modifiers: [.command])
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let history = UsageHistoryStore()
    lazy var appState = AppState(settings: settings, history: history)
    lazy var codexSessionPinger = CodexSessionPinger(settings: settings)
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var settingsShortcutMonitor: Any?
    private var menuShortcutSettingObserver: NSObjectProtocol?
    private var menuShortcutTask: Task<Void, Never>?
    private var menuShortcutPressCycle = ShortcutPressCycle()
    private var menuTestWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settingsWindowController = SettingsWindowController(settings: settings, history: history, appState: appState, codexSessionPinger: codexSessionPinger)
        statusBarController = StatusBarController(settings: settings, history: history, appState: appState, codexSessionPinger: codexSessionPinger)
        installSettingsShortcut()
        observeMenuShortcutSetting()
        updateMenuShortcutListener()
        closeStraySwiftUIWindows()
        let showMenuForTesting = UserDefaults.standard.bool(forKey: "showMenuPopoverForTesting")
            || ProcessInfo.processInfo.arguments.contains("--show-menu-popover-for-testing")
        if showMenuForTesting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showMenuTestWindow()
            }
        }
    }

    /// The SwiftUI `Settings { EmptyView() }` scene below only exists to
    /// satisfy the `App` protocol -- we drive our real Settings window from
    /// `SettingsWindowController`. Because it's the app's only SwiftUI scene,
    /// macOS can open (or restore) it as a blank "<App Name> Settings" window
    /// on launch. Close only that specific window -- its title ends in
    /// " Settings" -- so we never touch the status item's own window or the
    /// popover (both have empty titles) or our real Settings window (titled
    /// exactly "Settings"). Closing those by mistake made the menu bar item
    /// stop opening.
    private func closeStraySwiftUIWindows() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title.hasSuffix(" Settings") {
                window.close()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsShortcutMonitor {
            NSEvent.removeMonitor(settingsShortcutMonitor)
        }
        if let menuShortcutSettingObserver {
            NotificationCenter.default.removeObserver(menuShortcutSettingObserver)
        }
        menuShortcutTask?.cancel()
        menuShortcutTask = nil
    }

    /// Reopening the accessory app from Finder, Spotlight, or `open` presents
    /// its actual menu-bar popover. This matches a menu-bar app's normal
    /// behavior and keeps current usage reachable without hunting for the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState.requestTogglePopover?()
        }
        return true
    }

    /// Cmd+, (the standard macOS Settings shortcut) opens Settings when it's
    /// closed and closes it when it's already open. Command-I intentionally
    /// stays on the single global path below: observing it here as well would
    /// toggle once on key-down and again on key-up.
    private func installSettingsShortcut() {
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard flags == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case ",":
                self.appState.toggleSettingsWindow?()
                return nil
            default:
                return event
            }
        }
    }

    private func observeMenuShortcutSetting() {
        menuShortcutSettingObserver = NotificationCenter.default.addObserver(
            forName: .commandIShortcutSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateMenuShortcutListener() }
        }
    }

    /// KeyboardShortcuts owns the low-level Carbon registration. We toggle on
    /// the first key-down and use key-up only to reset the physical press.
    /// This remains one toggle even when macOS repeats an event while the
    /// menu-bar popover is taking focus.
    private func updateMenuShortcutListener() {
        menuShortcutTask?.cancel()
        menuShortcutTask = nil
        menuShortcutPressCycle.reset()
        guard settings.enableCommandIShortcut else { return }

        menuShortcutTask = Task { [weak self] in
            for await eventType in KeyboardShortcuts.events(for: .toggleGPTTracker) {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                let event: ShortcutPressCycle.Event = eventType == .keyDown ? .keyDown : .keyUp
                if self.menuShortcutPressCycle.handle(event) {
                    self.handleMenuShortcut()
                }
                if eventType == .keyUp {
                    self.appState.completePopoverShortcutPress?()
                }
            }
        }
    }

    private func handleMenuShortcut() {
        if settingsWindowController?.isShowing == true {
            appState.toggleSettingsWindow?()
        } else {
            appState.requestTogglePopoverFromShortcut?()
        }
    }

    /// Computer Use cannot attach to a transient NSPopover. This launch-flag
    /// harness hosts the exact production menu view in a normal window so
    /// every button can be exercised end to end. It is unreachable unless a
    /// developer explicitly sets the testing preference or launch argument.
    private func showMenuTestWindow() {
        if let menuTestWindow {
            menuTestWindow.makeKeyAndOrderFront(nil)
            return
        }
        let rootView = MenuBarContentView()
            .environmentObject(settings)
            .environmentObject(history)
            .environmentObject(appState)
            .environmentObject(codexSessionPinger)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "GPT Tracker Menu Test"
        window.styleMask = [.titled, .closable]
        window.contentMinSize = NSSize(width: 320, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        menuTestWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct GPTUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

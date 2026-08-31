import SwiftUI
import KeyboardShortcuts
import GPTTrackerFeature
import TrackerDesignSystem

private extension KeyboardShortcuts.Name {
    static let toggleClaudePinger = Self(
        "toggleClaudePinger",
        default: .init(.u, modifiers: [.command])
    )
    static let toggleCombinedGPTTracker = Self(
        "toggleCombinedGPTTracker",
        default: .init(.i, modifiers: [.command])
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let stats = StatsStore()
    let selection = CombinedSelectionStore()
    let gptFeature = GPTFeatureState()
    lazy var appState = AppState(settings: settings, stats: stats, updatesEnabled: true)
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var settingsShortcutMonitor: Any?
    private var menuShortcutSettingObserver: NSObjectProtocol?
    private var gptShortcutSettingObserver: NSObjectProtocol?
    private var menuShortcutTask: Task<Void, Never>?
    private var gptShortcutTask: Task<Void, Never>?
    private var menuShortcutPressCycle = ShortcutPressCycle()
    private var gptShortcutPressCycle = ShortcutPressCycle()
    private var menuTestWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        TrackerNotifications.shared.configure()
        if ProcessInfo.processInfo.arguments.contains("--verify-notifications") {
            Task {
                print(await TrackerNotifications.shared.verifyDelivery())
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-codex-chat-reuse") {
            Task {
                print(await gptFeature.verifyCodexChatReuse())
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-provider-pings") {
            Task {
                let claude = await appState.testConnection(configuration: .init(
                    sessionKey: settings.sessionKey, organizationID: settings.organizationID,
                    cookieHeader: settings.effectiveCookieHeader, model: settings.model, message: settings.message
                ))
                let codex = await gptFeature.verifyCodexChatReuse()
                let report: [String: Any] = ["claudePassed": appState.status == .success,
                    "claudeResult": claude, "claudeConversationID": settings.conversationID,
                    "codex": (try? JSONSerialization.jsonObject(with: Data(codex.utf8))) ?? codex]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                NSApp.terminate(nil)
            }
            return
        }
        settingsWindowController = SettingsWindowController(
            settings: settings,
            stats: stats,
            appState: appState,
            gptFeature: gptFeature,
            selection: selection
        )
        statusBarController = StatusBarController(
            settings: settings,
            stats: stats,
            appState: appState,
            gptFeature: gptFeature,
            selection: selection
        )
        installSettingsShortcut()
        observeMenuShortcutSetting()
        updateMenuShortcutListener()
        updateGPTShortcutListener()
        closeStraySwiftUIWindows()
        if ProcessInfo.processInfo.arguments.contains("--show-menu-window-for-testing") {
            showMenuTestWindow()
        }
        if ProcessInfo.processInfo.arguments.contains("--show-settings-window-for-testing") {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.settingsWindowController?.show()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-popover-for-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.appState.requestTogglePopoverFromShortcut?()
                self?.appState.completePopoverShortcutPress?()
            }
        }
    }

    /// Presents the exact menu content in a normal window so automated and
    /// accessibility testing can exercise every tab and button. Production
    /// launches never enter this path.
    private func showMenuTestWindow() {
        // A regular activation policy makes the opt-in preview discoverable
        // to macOS accessibility tools. Production launches remain accessory
        // menu-bar apps because this method only runs with the test argument.
        NSApp.setActivationPolicy(.regular)
        let root = CombinedMenuBarContentView(gptFeature: gptFeature)
            .environmentObject(settings)
            .environmentObject(stats)
            .environmentObject(appState)
            .environmentObject(selection)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Session Tracker Menu Preview"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 360, height: 540))
        window.center()
        menuTestWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        if let gptShortcutSettingObserver {
            NotificationCenter.default.removeObserver(gptShortcutSettingObserver)
        }
        menuShortcutTask?.cancel()
        menuShortcutTask = nil
        gptShortcutTask?.cancel()
        gptShortcutTask = nil
    }

    /// A menu-bar app has no ordinary document window to restore. Reopening it
    /// from Finder, Spotlight, or `open` must therefore present the same
    /// popover as clicking its status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState.requestTogglePopover?()
        }
        return true
    }

    /// Cmd+, (the standard macOS Settings shortcut) opens Settings when it's
    /// closed and closes it when it's already open, whenever this app --
    /// the menu bar popover or the Settings window itself -- is active.
    /// Only fires for that exact key combo so normal typing (e.g. a comma
    /// in the message field) is never intercepted.
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
            forName: .commandUShortcutSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateMenuShortcutListener() }
        }
        gptShortcutSettingObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("commandIShortcutSettingChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateGPTShortcutListener() }
        }
    }

    /// Toggle once on the first key-down of each physical Command-U press.
    /// Key-up only arms the next press, so duplicate callbacks cannot open
    /// and immediately close the menu.
    private func updateMenuShortcutListener() {
        menuShortcutTask?.cancel()
        menuShortcutTask = nil
        menuShortcutPressCycle.reset()
        guard settings.enableCommandUShortcut else { return }

        menuShortcutTask = Task { [weak self] in
            for await eventType in KeyboardShortcuts.events(for: .toggleClaudePinger) {
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
        selection.selectedTab = .claude
        if settingsWindowController?.isShowing == true {
            appState.toggleSettingsWindow?()
        } else {
            appState.requestTogglePopoverFromShortcut?()
        }
    }

    /// Command-I opens the GPT half of the combined tracker. It uses the
    /// same one-activation-per-physical-press guard as Command-U.
    private func updateGPTShortcutListener() {
        gptShortcutTask?.cancel()
        gptShortcutTask = nil
        gptShortcutPressCycle.reset()
        guard gptFeature.commandIEnabled else { return }

        gptShortcutTask = Task { [weak self] in
            for await eventType in KeyboardShortcuts.events(for: .toggleCombinedGPTTracker) {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                let event: ShortcutPressCycle.Event = eventType == .keyDown ? .keyDown : .keyUp
                if self.gptShortcutPressCycle.handle(event) {
                    self.handleGPTShortcut()
                }
                if eventType == .keyUp {
                    self.appState.completePopoverShortcutPress?()
                }
            }
        }
    }

    private func handleGPTShortcut() {
        if selection.selectedTab == .claude {
            selection.selectedTab = .codex
        }
        if settingsWindowController?.isShowing == true {
            appState.toggleSettingsWindow?()
        } else {
            appState.requestTogglePopoverFromShortcut?()
        }
    }
}

@main
struct CombinedSessionTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

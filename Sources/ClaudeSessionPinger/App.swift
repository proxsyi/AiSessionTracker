import SwiftUI
import KeyboardShortcuts

private extension KeyboardShortcuts.Name {
    static let toggleClaudePinger = Self(
        "toggleClaudePinger",
        default: .init(.u, modifiers: [.command])
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let stats = StatsStore()
    lazy var appState = AppState(settings: settings, stats: stats)
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var settingsShortcutMonitor: Any?
    private var menuShortcutSettingObserver: NSObjectProtocol?
    private var menuShortcutTask: Task<Void, Never>?
    private var menuShortcutPressCycle = ShortcutPressCycle()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settingsWindowController = SettingsWindowController(settings: settings, stats: stats, appState: appState)
        statusBarController = StatusBarController(settings: settings, stats: stats, appState: appState)
        installSettingsShortcut()
        observeMenuShortcutSetting()
        updateMenuShortcutListener()
        closeStraySwiftUIWindows()
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
        if settingsWindowController?.isShowing == true {
            appState.toggleSettingsWindow?()
        } else {
            appState.requestTogglePopoverFromShortcut?()
        }
    }
}

@main
struct ClaudeSessionPingerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

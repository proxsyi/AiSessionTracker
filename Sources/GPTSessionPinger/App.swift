import SwiftUI
import Carbon.HIToolbox

private let menuHotKeySignature: OSType = 0x53504E47 // "SPNG"
private let menuHotKeyIdentifier: UInt32 = 1

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let stats = StatsStore()
    lazy var appState = AppState(settings: settings, stats: stats)
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var settingsShortcutMonitor: Any?
    private var menuHotKeyRef: EventHotKeyRef?
    private var menuHotKeyHandlerRef: EventHandlerRef?
    private var menuShortcutSettingObserver: NSObjectProtocol?
    private var menuHotKeyIsDown = false
    private var menuTestWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settingsWindowController = SettingsWindowController(settings: settings, stats: stats, appState: appState)
        statusBarController = StatusBarController(settings: settings, stats: stats, appState: appState)
        installSettingsShortcut()
        observeMenuShortcutSetting()
        updateMenuHotKeyRegistration()
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
        unregisterMenuHotKey()
    }

    /// Reopening the accessory app from Finder, Spotlight, or `open` presents
    /// its actual menu-bar popover. This matches a menu-bar app's normal
    /// behavior and keeps Ping now reachable without hunting for the icon.
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
            forName: .commandIShortcutSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateMenuHotKeyRegistration() }
        }
    }

    /// Carbon's registered hot-key API works globally without Accessibility
    /// or Input Monitoring permission, unlike NSEvent's global key monitor.
    private func updateMenuHotKeyRegistration() {
        if settings.enableCommandIShortcut {
            registerMenuHotKey()
        } else {
            unregisterMenuHotKey()
        }
    }

    private func registerMenuHotKey() {
        guard menuHotKeyRef == nil else { return }

        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr,
                  hotKeyID.signature == menuHotKeySignature,
                  hotKeyID.id == menuHotKeyIdentifier else { return noErr }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let eventKind = GetEventKind(event)
            Task { @MainActor in
                appDelegate.handleMenuHotKeyEvent(kind: eventKind)
            }
            return noErr
        }

        let installStatus = eventTypes.withUnsafeBufferPointer { events in
            InstallEventHandler(
                GetApplicationEventTarget(),
                handler,
                events.count,
                events.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &menuHotKeyHandlerRef
            )
        }
        guard installStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: menuHotKeySignature, id: menuHotKeyIdentifier)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_I),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &menuHotKeyRef
        )
        if registerStatus != noErr {
            unregisterMenuHotKey()
        }
    }

    private func unregisterMenuHotKey() {
        if let menuHotKeyRef {
            UnregisterEventHotKey(menuHotKeyRef)
            self.menuHotKeyRef = nil
        }
        if let menuHotKeyHandlerRef {
            RemoveEventHandler(menuHotKeyHandlerRef)
            self.menuHotKeyHandlerRef = nil
        }
        menuHotKeyIsDown = false
    }

    /// Toggle on the physical press edge only. Carbon's matching release is
    /// the sole authority that clears the state, so a timer cannot mistake a
    /// still-held shortcut for a second press and immediately close the menu.
    private func handleMenuHotKeyEvent(kind: UInt32) {
        if kind == UInt32(kEventHotKeyReleased) {
            menuHotKeyIsDown = false
            return
        }
        guard kind == UInt32(kEventHotKeyPressed), !menuHotKeyIsDown else { return }
        menuHotKeyIsDown = true
        if settingsWindowController?.isShowing == true {
            appState.toggleSettingsWindow?()
        } else {
            appState.requestTogglePopover?()
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
            .environmentObject(stats)
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "GPT Menu Test"
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
struct GPTSessionPingerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: SettingsStore
    private let history: UsageHistoryStore
    private let appState: AppState
    private let codexSessionPinger: CodexSessionPinger
    private var deactivationObserver: NSObjectProtocol?

    init(settings: SettingsStore, history: UsageHistoryStore, appState: AppState, codexSessionPinger: CodexSessionPinger) {
        self.settings = settings
        self.history = history
        self.appState = appState
        self.codexSessionPinger = codexSessionPinger
        super.init()
        appState.requestShowSettings = { [weak self] in
            self?.show()
        }
        appState.closeSettingsWindow = { [weak self] in
            self?.window?.close()
        }
        appState.toggleSettingsWindow = { [weak self] in
            self?.toggle()
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restoreFocusAfterMenuBarHover()
            }
        }
    }

    deinit {
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
    }

    var isShowing: Bool {
        window != nil
    }

    /// Opens Settings if it's closed, or closes it if it's already open.
    /// Used by the Cmd+, keyboard shortcut.
    func toggle() {
        if window != nil {
            if let saveAndClose = appState.requestSaveAndCloseSettings {
                saveAndClose()
            } else {
                window?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.appState.requestTogglePopover?()
                }
            }
        } else {
            appState.requestClosePopover?()
            show()
        }
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = SettingsView()
            .environmentObject(settings)
            .environmentObject(history)
            .environmentObject(appState)
            .environmentObject(codexSessionPinger)
        let hosting = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Settings"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // The view draws its own "Settings" header, so hide the system
        // title text; fullSizeContentView lets the glass background extend
        // under the title bar instead of leaving a raw transparent strip
        // with a duplicated title.
        newWindow.titleVisibility = .hidden
        // Let the system's behind-window glass show through: the SwiftUI
        // root view draws its own NSVisualEffectView background, so the
        // window chrome itself must be transparent.
        newWindow.titlebarAppearsTransparent = true
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.minSize = NSSize(width: 380, height: 420)
        newWindow.isReleasedWhenClosed = false
        Self.configureWindowPresence(newWindow)
        newWindow.delegate = self
        newWindow.center()
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// A menu-bar-only app does not own the system menu bar. Keep Settings at
    /// utility-window level so revealing that menu bar cannot place the
    /// previously active app's normal windows above it.
    static func configureWindowPresence(_ window: NSWindow) {
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.formUnion([
            .auxiliary,
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .fullScreenDisallowsTiling
        ])
    }

    static func shouldRestoreFocusForMenuBarHover(
        mouseLocation: NSPoint,
        pressedMouseButtons: Int,
        screenFrames: [NSRect]
    ) -> Bool {
        guard pressedMouseButtons == 0 else { return false }
        return screenFrames.contains { frame in
            mouseLocation.x >= frame.minX
                && mouseLocation.x <= frame.maxX
                && mouseLocation.y >= frame.maxY - 48
                && mouseLocation.y <= frame.maxY
        }
    }

    private func restoreFocusAfterMenuBarHover() {
        guard let window, window.isVisible,
              Self.shouldRestoreFocusForMenuBarHover(
                mouseLocation: NSEvent.mouseLocation,
                pressedMouseButtons: NSEvent.pressedMouseButtons,
                screenFrames: NSScreen.screens.map(\.frame)
              ) else { return }

        // The prior full-screen app finishes revealing its menu bar after the
        // resign-active notification. Wait one run-loop turn, then restore
        // only if the pointer is still hovering at the menu-bar edge.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible,
                  Self.shouldRestoreFocusForMenuBarHover(
                    mouseLocation: NSEvent.mouseLocation,
                    pressedMouseButtons: NSEvent.pressedMouseButtons,
                    screenFrames: NSScreen.screens.map(\.frame)
                  ) else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

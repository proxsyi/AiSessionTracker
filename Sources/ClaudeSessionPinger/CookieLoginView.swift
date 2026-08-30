import SwiftUI
import TrackerDesignSystem
import WebKit

private let desktopSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"


enum CookieLoginState: Equatable {
    case loading
    case ready
    case failed(String)
}

struct CookieLoginRepresentable: NSViewRepresentable {
    let onCookiesCaptured: (_ sessionKey: String, _ organizationID: String?, _ cookieHeader: String) -> Void
    let onStateChange: (CookieLoginState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesCaptured: onCookiesCaptured, onStateChange: onStateChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = desktopSafariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        #if DEBUG
        // Only enable the Web Inspector in debug builds -- it adds real
        // overhead to page load and isn't needed once this ships.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        context.coordinator.attach(to: webView)
        let request = URLRequest(url: URL(string: "https://claude.ai/login")!, cachePolicy: .returnCacheDataElseLoad)
        webView.load(request)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        coordinator.closeAllPopups()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
        private let onCookiesCaptured: (String, String?, String) -> Void
        private let onStateChange: (CookieLoginState) -> Void
        private weak var webView: WKWebView?
        private let pollTimer = TrackerInvalidatingTimer()
        private var didCapture = false
        private var popupWindows: [NSWindow] = []
        private var sessionKeyFoundAt: Date?
        // claude.ai sets `sessionKey` immediately on login, but `lastActiveOrg`
        // is often set a moment later once the app finishes redirecting into
        // the workspace. Without this grace period we'd sometimes capture the
        // session with no organization ID at all.
        private let orgCookieGracePeriod: TimeInterval = 8

        init(onCookiesCaptured: @escaping (String, String?, String) -> Void, onStateChange: @escaping (CookieLoginState) -> Void) {
            self.onCookiesCaptured = onCookiesCaptured
            self.onStateChange = onStateChange
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkCookies()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer.timer = timer
        }

        func stopPolling() {
            pollTimer.timer?.invalidate()
            pollTimer.timer = nil
        }

        // MARK: WKNavigationDelegate

        // Note: the same coordinator is also used as the delegate for OAuth
        // popup webviews (see `createWebViewWith` below), so every method
        // here guards on `webView === self.webView` to make sure a popup's
        // own navigation lifecycle (e.g. a transient redirect hiccup) can't
        // spuriously flip the main login sheet's loading/failed banner.
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard webView === self.webView else { return }
            onStateChange(.loading)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView === self.webView {
                onStateChange(.ready)
            }
            checkCookies()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard webView === self.webView else { return }
            onStateChange(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard webView === self.webView else { return }
            onStateChange(.failed(error.localizedDescription))
        }

        // MARK: WKUIDelegate -- needed so SSO/OAuth popups (e.g. "Continue with Google") can open

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let popupWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
            popupWebView.customUserAgent = desktopSafariUserAgent
            popupWebView.navigationDelegate = self
            popupWebView.uiDelegate = self

            let window = NSWindow(
                contentRect: popupWebView.frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = popupWebView
            window.title = "Sign in"
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            popupWindows.append(window)
            window.makeKeyAndOrderFront(nil)

            return popupWebView
        }

        func webViewDidClose(_ webView: WKWebView) {
            // Just ask the window to close; `windowWillClose` below is the
            // single source of truth for untracking it, so this also covers
            // the case where the user closes the popup with the native
            // close button instead of the page calling `window.close()`.
            if let window = popupWindows.first(where: { $0.contentView === webView }) {
                window.close()
            }
            checkCookies()
        }

        func windowWillClose(_ notification: Notification) {
            guard let closedWindow = notification.object as? NSWindow else { return }
            popupWindows.removeAll { $0 === closedWindow }
        }

        /// Closes any still-open OAuth popups. Called when the main login
        /// sheet itself is dismissed so a popup can't get orphaned on screen.
        func closeAllPopups() {
            let windows = popupWindows
            popupWindows.removeAll()
            windows.forEach { $0.close() }
        }

        // MARK: Cookie polling

        private func checkCookies() {
            guard !didCapture, let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.didCapture else { return }
                let claudeCookies = cookies.filter { $0.domain.contains("claude.ai") }
                guard let sessionCookie = claudeCookies.first(where: { $0.name == "sessionKey" }), !sessionCookie.value.isEmpty else {
                    return
                }
                let orgCookie = claudeCookies.first(where: { $0.name == "lastActiveOrg" })
                let hasOrg = !(orgCookie?.value.isEmpty ?? true)

                if !hasOrg {
                    let foundAt = self.sessionKeyFoundAt ?? Date()
                    self.sessionKeyFoundAt = foundAt
                    if Date().timeIntervalSince(foundAt) < self.orgCookieGracePeriod {
                        // Session is in, but give the org cookie a little longer to
                        // show up before finishing without it.
                        return
                    }
                }

                self.didCapture = true
                self.stopPolling()
                let sessionValue = sessionCookie.value
                let orgValue = hasOrg ? orgCookie?.value : nil
                // Capture every claude.ai cookie as a ready-to-send Cookie
                // header so the app's requests carry exactly what the
                // browser session had, not just the session key.
                let header = claudeCookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                DispatchQueue.main.async {
                    self.onCookiesCaptured(sessionValue, orgValue, header)
                }
            }
        }

    }
}

struct CookieLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferClearGlass") private var preferClearGlass = true
    let onComplete: (_ sessionKey: String, _ organizationID: String?, _ cookieHeader: String) -> Void

    @State private var didFinish = false
    @State private var loginState: CookieLoginState = .loading
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log in to Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ClaudeTheme.textPrimary)
                Spacer()
                if case .loading = loginState {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .glassPanel(cornerRadius: 12)
                }
                Button("Cancel") { dismiss() }
                    .claudeGhostButton()
            }
            .padding(12)
            Divider()

            if case .failed(let message) = loginState {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load the login page")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(ClaudeTheme.textSecondary)
                    HStack {
                        Button("Try again") {
                            loginState = .loading
                            reloadToken = UUID()
                        }
                        .claudePrimaryButton()
                        Button("Use manual paste instead") { dismiss() }
                            .claudeGhostButton()
                    }
                }
                .padding(16)
            } else {
                Text("Log in below. Once you're signed in, this closes automatically and your session is captured -- nothing to copy or paste. If your account uses \"Continue with Google\" or similar, that opens in its own sign-in window.")
                    .font(.system(size: 11))
                    .foregroundColor(ClaudeTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
                CookieLoginRepresentable(
                    onCookiesCaptured: { sessionKey, organizationID, cookieHeader in
                        guard !didFinish else { return }
                        didFinish = true
                        onComplete(sessionKey, organizationID, cookieHeader)
                        dismiss()
                    },
                    onStateChange: { state in
                        loginState = state
                    }
                )
                .id(reloadToken)
                .padding(12)
            }
        }
        .environment(\.claudeClearGlass, preferClearGlass)
        .frame(width: 480, height: 620)
        .background(WindowGlassBackground(clearGlass: preferClearGlass).ignoresSafeArea())
    }
}

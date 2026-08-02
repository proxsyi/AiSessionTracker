import SwiftUI
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
        let request = URLRequest(url: URL(string: "https://chatgpt.com/auth/login")!, cachePolicy: .returnCacheDataElseLoad)
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
        private var pollTimer: Timer?
        private var didCapture = false
        private var isValidatingCookies = false
        private var popupWindows: [NSWindow] = []

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
            pollTimer = timer
        }

        func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
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
            guard !didCapture, !isValidatingCookies,
                  let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.didCapture, !self.isValidatingCookies else { return }
                let chatGPTCookies = cookies.filter { $0.domain.contains("chatgpt.com") || $0.domain.contains("openai.com") }
                guard !chatGPTCookies.isEmpty,
                      let sessionCookie = chatGPTCookies.first(where: { !$0.value.isEmpty && ($0.name.contains("session") || $0.name.contains("auth") || $0.name == "_account") }) else {
                    return
                }

                let sessionValue = sessionCookie.value
                let header = chatGPTCookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                self.isValidatingCookies = true
                Task { [weak self] in
                    let authenticated = await Self.isAuthenticated(cookieHeader: header)
                    guard let self else { return }
                    self.isValidatingCookies = false
                    guard authenticated, !self.didCapture else { return }
                    // Do not save transient OAuth, account-picker, or CSRF
                    // cookies. ChatGPT itself must first confirm the session.
                    self.didCapture = true
                    self.stopPolling()
                    self.onCookiesCaptured(sessionValue, nil, header)
                }
            }
        }

        private static func isAuthenticated(cookieHeader: String) async -> Bool {
            guard let url = URL(string: "https://chatgpt.com/api/auth/session") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["user"] != nil || object["email"] != nil
        }

        deinit {
            pollTimer?.invalidate()
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
                Text("Log in to ChatGPT")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(GPTTheme.textPrimary)
                Spacer()
                if case .loading = loginState {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .glassPanel(cornerRadius: 12)
                }
                Button("Cancel") { dismiss() }
                    .gptGhostButton()
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
                        .foregroundColor(GPTTheme.textSecondary)
                    HStack {
                        Button("Try again") {
                            loginState = .loading
                            reloadToken = UUID()
                        }
                        .gptPrimaryButton()
                        Button("Use manual paste instead") { dismiss() }
                            .gptGhostButton()
                    }
                }
                .padding(16)
            } else {
                Text("Log in below. Once you're signed in, this closes automatically and your session is captured -- nothing to copy or paste. If your account uses \"Continue with Google\" or similar, that opens in its own sign-in window.")
                    .font(.system(size: 11))
                    .foregroundColor(GPTTheme.textSecondary)
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
        .environment(\.gptClearGlass, preferClearGlass)
        .frame(width: 480, height: 620)
        .background(WindowGlassBackground(clearGlass: preferClearGlass).ignoresSafeArea())
    }
}

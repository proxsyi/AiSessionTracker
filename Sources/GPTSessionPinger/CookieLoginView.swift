import SwiftUI
import TrackerDesignSystem
import WebKit

enum CookieLoginState: Equatable {
    case loading
    case ready
    case failed(String)
}

struct ChatGPTLoginCapture: Equatable {
    let sessionKey: String
    let organizationID: String?
    let cookieHeader: String
    let planType: String?
}

@MainActor
enum ChatGPTWebsiteData {
    /// Sign out only OpenAI domains, including when Claude shares this app's
    /// embedded-browser container.
    static func clear() async {
        await TrackerWebsiteData.clear(domains: TrackerWebsiteData.openAIDomains)
    }
}

struct CookieLoginRepresentable: NSViewRepresentable {
    let onCookiesCaptured: (ChatGPTLoginCapture) -> Void
    let onStateChange: (CookieLoginState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesCaptured: onCookiesCaptured, onStateChange: onStateChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = ChatGPTWebSession.userAgent
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
        let request = URLRequest(url: URL(string: "https://chatgpt.com/")!, cachePolicy: .reloadIgnoringLocalCacheData)
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
        private let onCookiesCaptured: (ChatGPTLoginCapture) -> Void
        private let onStateChange: (CookieLoginState) -> Void
        private weak var webView: WKWebView?
        private let pollTimer = TrackerInvalidatingTimer()
        private var didCapture = false
        private var isValidatingCookies = false
        private var popupWindows: [NSWindow] = []

        init(onCookiesCaptured: @escaping (ChatGPTLoginCapture) -> Void, onStateChange: @escaping (CookieLoginState) -> Void) {
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
            guard !isExpectedNavigationInterruption(error) else { return }
            onStateChange(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard webView === self.webView else { return }
            guard !isExpectedNavigationInterruption(error) else { return }
            onStateChange(.failed(error.localizedDescription))
        }

        private func isExpectedNavigationInterruption(_ error: Error) -> Bool {
            if (error as? URLError)?.code == .cancelled { return true }
            let nsError = error as NSError
            return nsError.domain == WKError.errorDomain
                && nsError.code == 102 // WebKitErrorFrameLoadInterruptedByPolicyChange
        }

        // MARK: WKUIDelegate -- needed so SSO/OAuth popups (e.g. "Continue with Google") can open

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let popupWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
            popupWebView.customUserAgent = ChatGPTWebSession.userAgent
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
                guard !chatGPTCookies.isEmpty else { return }

                let header = chatGPTCookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                self.isValidatingCookies = true
                Task { [weak self] in
                    let authSession = await ChatGPTWebSession.fetchAuthSession(cookieHeader: header)
                    guard let self else { return }
                    self.isValidatingCookies = false
                    guard let authSession, !self.didCapture else { return }
                    // Do not save transient OAuth, account-picker, or CSRF
                    // cookies. ChatGPT itself must first confirm the session.
                    self.didCapture = true
                    self.stopPolling()
                    self.onCookiesCaptured(ChatGPTLoginCapture(
                        sessionKey: authSession.accessToken,
                        organizationID: authSession.accountID,
                        cookieHeader: header,
                        planType: authSession.planType
                    ))
                }
            }
        }

    }
}

struct CookieLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferClearGlass") private var preferClearGlass = true
    let onComplete: (ChatGPTLoginCapture) -> Void

    @State private var didFinish = false
    @State private var loginState: CookieLoginState = .loading
    @State private var reloadToken = UUID()
    @State private var pendingCapture: ChatGPTLoginCapture?
    @State private var isClearing = false

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
                Text("Log in below. The app will show the detected plan before saving anything. If this is the wrong account, choose Switch account to clear this app's browser cookies and sign in again.")
                    .font(.system(size: 11))
                    .foregroundColor(GPTTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
                CookieLoginRepresentable(
                    onCookiesCaptured: { capture in
                        guard !didFinish else { return }
                        pendingCapture = capture
                    },
                    onStateChange: { state in
                        loginState = state
                    }
                )
                .id(reloadToken)
                .padding(12)

                if let pendingCapture {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Signed-in account detected")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Plan: \(planLabel(pendingCapture.planType))")
                            .font(.system(size: 11))
                            .foregroundColor(GPTTheme.textSecondary)
                        HStack {
                            Button("Use this account") {
                                guard !didFinish else { return }
                                didFinish = true
                                onComplete(pendingCapture)
                                dismiss()
                            }
                            .gptPrimaryButton()
                            Button(isClearing ? "Clearing…" : "Switch account") {
                                switchAccount()
                            }
                            .gptGhostButton()
                            .disabled(isClearing)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .environment(\.gptClearGlass, preferClearGlass)
        .frame(width: 480, height: 620)
        .background(WindowGlassBackground(clearGlass: preferClearGlass).ignoresSafeArea())
    }

    private func planLabel(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "Not reported" }
        return plan.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func switchAccount() {
        guard !isClearing else { return }
        isClearing = true
        Task { @MainActor in
            await ChatGPTWebsiteData.clear()
            pendingCapture = nil
            didFinish = false
            loginState = .loading
            reloadToken = UUID()
            isClearing = false
        }
    }
}

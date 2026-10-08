import AppKit
import Foundation
import OSLog
import WebKit

enum ChatGPTComposerMode: String, Sendable {
    case chat = "Chat"
    case work = "Work"
}

struct ChatGPTBrowserResponse: Sendable {
    let statusCode: Int
    let body: Data
    let contentType: String
    let browserCheckHeader: String
    let conversationID: String?
    let replyText: String?
}

/// Sends through ChatGPT's real web composer so the site performs its own
/// browser verification and proof-of-work. Reloading the stored conversation
/// URL keeps every ping in one cloud chat.
@MainActor
final class ChatGPTBrowserTransport: NSObject, WKNavigationDelegate {
    static let shared = ChatGPTBrowserTransport()
    private static let logger = Logger(subsystem: "com.proxsyi.sessiontracker", category: "ChatGPTBrowser")

    private var webView: WKWebView?
    private var browserPanel: NSPanel?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private let operationGate = ChatGPTBrowserOperationGate()

    /// chatgpt.com is a heavy SPA: its renderer settles around 600-750 MB of
    /// WebKit malloc once a conversation has been loaded. Pings are hours
    /// apart, so holding that renderer between them dominated the app's
    /// footprint. The renderer is torn down once it has been idle this long,
    /// which keeps an auth-refresh-then-send pair (and the retry backoffs
    /// above it) on one renderer without paying for it until the next ping.
    private static let idleTeardownDelay: TimeInterval = 15
    private var idleTeardownTask: Task<Void, Never>?
    private var activeOperations = 0

    /// Cloudflare clearance cookies persist in the on-disk default data store,
    /// so they are cleared once per app launch rather than once per renderer.
    /// Tearing the renderer down must not force a fresh browser check.
    private var hasClearedStaleBrowserChecks = false

    func resolveAuth(cookieHeader: String) async throws -> ChatGPTAuthSession {
        try await operationGate.acquire()
        beginBrowserOperation()
        defer { finishBrowserOperation() }
        let webView = try await preparedWebView(cookieHeader: cookieHeader)
        let script = """
        const response = await fetch('/api/auth/session', {
          credentials: 'include',
          headers: { 'Accept': 'application/json' }
        });
        if (!response.ok) {
          return { statusCode: response.status };
        }
        const session = await response.json();
        const account = session.account || {};
        return {
          statusCode: response.status,
          accessToken: session.accessToken || session.access_token || '',
          accountID: session.accountId || session.account_id ||
            session.chatgpt_account_id || account.id || '',
          planType: session.planType || session.plan_type ||
            session.chatgpt_plan_type || account.plan_type || ''
        };
        """
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let object = result as? [String: Any],
              let status = object["statusCode"] as? Int,
              (200...299).contains(status),
              let accessToken = object["accessToken"] as? String,
              accessToken.count > 40 else {
            throw ChatGPTPingError.sessionExpired
        }
        Self.logger.info("Browser auth refresh succeeded")
        return ChatGPTAuthSession(
            accessToken: accessToken,
            accountID: (object["accountID"] as? String)?.nilIfEmpty,
            planType: (object["planType"] as? String)?.nilIfEmpty
                ?? ChatGPTWebSession.planType(from: accessToken)
        )
    }

    func send(
        message: String,
        conversationID: String?,
        model: String,
        modelTitle: String,
        mode: ChatGPTComposerMode,
        reasoningEffort: String,
        cookieHeader: String,
        onConversationIdentified: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        timeout: TimeInterval
    ) async throws -> ChatGPTBrowserResponse {
        try await operationGate.acquire()
        beginBrowserOperation()
        defer { finishBrowserOperation() }
        let webView = try await preparedWebView(cookieHeader: cookieHeader)
        try await loadChatGPT(
            in: webView,
            conversationID: conversationID,
            model: model,
            reasoningEffort: reasoningEffort,
            mode: mode
        )
        if mode == .chat, reasoningEffort == "none" {
            try await verifySelectedModel(modelTitle, in: webView)
        }
        return try await sendThroughComposer(
            message,
            existingConversationID: conversationID,
            onConversationIdentified: onConversationIdentified,
            in: webView,
            timeout: timeout
        )
    }

    private func preparedWebView(cookieHeader: String) async throws -> WKWebView {
        idleTeardownTask?.cancel()
        idleTeardownTask = nil
        let webView: WKWebView
        if let existing = self.webView {
            webView = existing
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            if #available(macOS 14.0, *) { configuration.preferences.inactiveSchedulingPolicy = .none }
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView

            // WebKit throttles work that is never attached to a window. Keep
            // a normal-sized renderer offscreen so ChatGPT's browser check
            // can complete without flashing a window in front of the user.
            let panel = NSPanel(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.contentView = webView
            panel.isReleasedWhenClosed = false
            panel.orderFrontRegardless()
            browserPanel = panel
        }

        if #available(macOS 14.0, *) { webView.configuration.preferences.inactiveSchedulingPolicy = .none }
        let clearStaleBrowserChecks = !hasClearedStaleBrowserChecks
        hasClearedStaleBrowserChecks = true
        await installCookies(
            cookieHeader,
            into: webView.configuration.websiteDataStore.httpCookieStore,
            clearStaleBrowserChecks: clearStaleBrowserChecks
        )
        if webView.url?.host == "chatgpt.com", !webView.isLoading { return webView }

        try await loadChatGPT(in: webView)
        return webView
    }

    private func beginBrowserOperation() {
        activeOperations += 1
        idleTeardownTask?.cancel()
        idleTeardownTask = nil
    }

    private func finishBrowserOperation() {
        // Work uses an asynchronous stream handoff. Keep the renderer running
        // during the operation, then suspend idle page work to save battery.
        if #available(macOS 14.0, *) { webView?.configuration.preferences.inactiveSchedulingPolicy = .suspend }
        activeOperations = max(0, activeOperations - 1)
        scheduleIdleTeardown()
        operationGate.release()
    }

    private func scheduleIdleTeardown() {
        guard activeOperations == 0, webView != nil else { return }
        idleTeardownTask?.cancel()
        let delay = Self.idleTeardownDelay
        idleTeardownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.teardownRenderer()
        }
    }

    /// Releases the renderer and its offscreen host window. Cookies and the
    /// conversation ID live outside the renderer, so the next ping rebuilds an
    /// equivalent one and still lands in the same cloud chat.
    private func teardownRenderer() {
        guard activeOperations == 0, let webView else { return }
        idleTeardownTask = nil
        navigationContinuation?.resume(throwing: CancellationError())
        navigationContinuation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        if let panel = browserPanel {
            panel.contentView = nil
            panel.orderOut(nil)
            panel.close()
        }
        browserPanel = nil
        self.webView = nil
        Self.logger.info("Released idle ChatGPT renderer")
    }

    private func loadChatGPT(in webView: WKWebView) async throws {
        guard let url = URL(string: "https://chatgpt.com/") else {
            throw ChatGPTPingError.serverError(0, "Invalid ChatGPT URL")
        }
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation?.resume(throwing: CancellationError())
            navigationContinuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        // `didFinish` fires before browser verification scripts necessarily
        // finish updating their clearance cookie.
        try? await Task.sleep(nanoseconds: 4_000_000_000)
    }

    private func loadChatGPT(
        in webView: WKWebView,
        conversationID: String?,
        model: String,
        reasoningEffort: String,
        mode: ChatGPTComposerMode
    ) async throws {
        guard let url = Self.conversationURL(
            conversationID: conversationID,
            model: model,
            reasoningEffort: reasoningEffort
        ) else {
            throw ChatGPTPingError.serverError(0, "Invalid ChatGPT conversation URL")
        }
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation?.resume(throwing: CancellationError())
            navigationContinuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if conversationID?.isEmpty != false {
            try await selectComposerMode(mode, in: webView)
        }
    }

    private func selectComposerMode(_ mode: ChatGPTComposerMode, in webView: WKWebView) async throws {
        let timeout: TimeInterval = 12
        let deadline = Date().addingTimeInterval(timeout)
        var clicked = false
        while Date() < deadline {
            let result = try await webView.callAsyncJavaScript(
                """
                const target = Array.from(document.querySelectorAll('button[role="radio"]'))
                  .find(button => (button.innerText || button.textContent || '').trim() === title);
                if (!target) return { found: false, selected: false };
                const selected = target.getAttribute('aria-checked') === 'true' ||
                  target.getAttribute('data-state') === 'checked' ||
                  target.getAttribute('aria-selected') === 'true';
                if (!selected && shouldClick) target.click();
                return { found: true, selected };
                """,
                arguments: ["title": mode.rawValue, "shouldClick": !clicked],
                in: nil,
                contentWorld: .page
            )
            if let object = result as? [String: Any] {
                if object["selected"] as? Bool == true { return }
                if object["found"] as? Bool == true { clicked = true }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw await composerUnavailableError(
            phase: "work-mode-selection",
            in: webView,
            timeout: timeout
        )
    }

    nonisolated static func conversationURL(
        conversationID: String?,
        model: String,
        reasoningEffort: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chatgpt.com"
        if let conversationID, !conversationID.isEmpty {
            components.path = "/c/\(conversationID)"
        } else {
            components.path = "/"
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        if reasoningEffort != "none", reasoningEffort != "default" {
            components.queryItems?.append(URLQueryItem(name: "reasoning_effort", value: reasoningEffort))
            components.queryItems?.append(URLQueryItem(name: "thinking_effort", value: reasoningEffort))
        }
        return components.url
    }

    private func verifySelectedModel(_ expectedTitle: String, in webView: WKWebView) async throws {
        let expected = ChatGPTModelCatalog.normalizedSelection(expectedTitle)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let values = try? await webView.callAsyncJavaScript(
                "return Array.from(document.querySelectorAll('button')).map(button => (button.innerText || button.textContent || '').trim());",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? [String], values.contains(where: {
                ChatGPTModelCatalog.normalizedSelection($0) == expected
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ChatGPTPingError.modelSelectionFailed(expectedTitle)
    }

    private func installCookies(
        _ header: String,
        into store: WKHTTPCookieStore,
        clearStaleBrowserChecks: Bool
    ) async {
        if clearStaleBrowserChecks {
            let existing = await withCheckedContinuation { continuation in
                store.getAllCookies { continuation.resume(returning: $0) }
            }
            for cookie in existing where Self.isBrowserCheckCookie(cookie.name) {
                await withCheckedContinuation { continuation in
                    store.delete(cookie) { continuation.resume() }
                }
            }
        }
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Self.isBrowserCheckCookie(name) else { continue }
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: ".chatgpt.com",
                .path: "/",
                .name: name,
                .value: pair[1],
                .secure: true,
                .expires: Date().addingTimeInterval(30 * 24 * 60 * 60)
            ]
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func sendThroughComposer(
        _ message: String,
        existingConversationID: String?,
        onConversationIdentified: @escaping @MainActor @Sendable (String) -> Void,
        in webView: WKWebView,
        timeout: TimeInterval
    ) async throws -> ChatGPTBrowserResponse {
        let deadline = Date().addingTimeInterval(timeout)
        var composerReady = false
        while Date() < deadline {
            if let ready = try? await webView.callAsyncJavaScript(
                "return Boolean(document.querySelector('#prompt-textarea'));",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? Bool, ready {
                composerReady = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard composerReady else {
            throw await composerUnavailableError(
                phase: "composer-readiness",
                in: webView,
                timeout: timeout
            )
        }

        try ChatGPTConversationIdentity.validatePage(expected: existingConversationID, url: webView.url)
        let baselineResult = try await webView.callAsyncJavaScript(
            ChatGPTConversationIdentity.pageGuardScript + "\n" + """
            const composer = document.querySelector('#prompt-textarea');
            const assistants = document.querySelectorAll('[data-message-author-role="assistant"]');
            if (!composer) return { ready: false, assistantCount: assistants.length };
            composer.focus();
            document.execCommand('selectAll', false, null);
            document.execCommand('delete', false, null);
            const inserted = document.execCommand('insertText', false, message);
            composer.dispatchEvent(new InputEvent('input', {
              bubbles: true,
              inputType: 'insertText',
              data: message
            }));
            return { ready: true, inserted, assistantCount: assistants.length };
            """,
            arguments: ["message": message, "expectedConversationID": existingConversationID ?? ""],
            in: nil,
            contentWorld: .page
        )
        if (baselineResult as? [String: Any])?["wrongConversation"] as? Bool == true {
            throw ChatGPTPingError.conversationChanged
        }
        guard let baseline = baselineResult as? [String: Any],
              baseline["ready"] as? Bool == true else {
            throw await composerUnavailableError(
                phase: "composer-insertion",
                in: webView,
                timeout: nil
            )
        }
        let assistantCount = baseline["assistantCount"] as? Int ?? 0

        var submitted = false
        while Date() < deadline {
            let result: Any?
            do {
                result = try await webView.callAsyncJavaScript(
                    ChatGPTConversationIdentity.pageGuardScript + "\n" + """
                    const button = document.querySelector('[data-testid="send-button"]');
                    if (!button || button.disabled) return false;
                    button.click();
                    return true;
                    """,
                    arguments: ["expectedConversationID": existingConversationID ?? ""],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                // A bridge failure can occur after the click reached the page.
                throw ChatGPTPingError.deliveryUncertain
            }
            if (result as? [String: Any])?["wrongConversation"] as? Bool == true {
                throw ChatGPTPingError.conversationChanged
            }
            if result as? Bool == true {
                submitted = true
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard submitted else {
            return failureResponse(status: 422, message: "ChatGPT did not accept the composer text.")
        }

        var boundConversationID = existingConversationID.flatMap { $0.isEmpty ? nil : $0 }
        var reportedConversationID: String?
        while Date() < deadline {
            if let state = try? await composerState(in: webView) {
                if let observed = state.conversationID {
                    let verified = try ChatGPTConversationIdentity.validate(expected: boundConversationID, observed: observed)
                    boundConversationID = verified
                    if reportedConversationID != verified {
                        onConversationIdentified(verified)
                        reportedConversationID = verified
                    }
                } else if boundConversationID != nil {
                    throw ChatGPTPingError.conversationChanged
                }
                guard state.assistantCount > assistantCount, !state.isGenerating else {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                let resolvedConversationID = try ChatGPTConversationIdentity.validate(
                    expected: boundConversationID, observed: state.conversationID
                )
                let replyText = state.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatGPTBrowserResponse(
                    statusCode: 200,
                    body: Data(replyText.utf8),
                    contentType: "text/plain",
                    browserCheckHeader: "",
                    conversationID: resolvedConversationID,
                    replyText: replyText.isEmpty ? nil : replyText
                )
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw ChatGPTPingError.deliveryUncertain
    }

    private func composerState(in webView: WKWebView) async throws -> (
        assistantCount: Int,
        isGenerating: Bool,
        conversationID: String?,
        replyText: String
    ) {
        let result = try await webView.callAsyncJavaScript(
            """
            const assistants = Array.from(document.querySelectorAll('[data-message-author-role="assistant"]'));
            const pathMatch = location.pathname.match(/^\\/c\\/([^/?#]+)/);
            return {
              assistantCount: assistants.length,
              isGenerating: Boolean(document.querySelector('[data-testid="stop-button"]')),
              conversationID: pathMatch ? pathMatch[1] : '',
              replyText: assistants.length
                ? (assistants[assistants.length - 1].innerText || assistants[assistants.length - 1].textContent || '').trim()
                : ''
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let object = result as? [String: Any] else {
            throw ChatGPTPingError.serverError(0, "ChatGPT returned invalid composer state")
        }
        return (
            object["assistantCount"] as? Int ?? 0,
            object["isGenerating"] as? Bool ?? false,
            (object["conversationID"] as? String)?.nilIfEmpty,
            object["replyText"] as? String ?? ""
        )
    }

    private func failureResponse(status: Int, message: String) -> ChatGPTBrowserResponse {
        ChatGPTBrowserResponse(
            statusCode: status,
            body: Data(message.utf8),
            contentType: "text/plain",
            browserCheckHeader: "",
            conversationID: nil,
            replyText: nil
        )
    }

    private func composerUnavailableError(
        phase: String,
        in webView: WKWebView,
        timeout: TimeInterval?
    ) async -> ChatGPTPingError {
        let diagnosticsScript = """
        const host = location.hostname.toLowerCase();
        const path = location.pathname;
        const page = host !== 'chatgpt.com' && !host.endsWith('.chatgpt.com')
          ? 'external'
          : path.startsWith('/c/') ? 'conversation' : path === '/' ? 'home' : 'other';
        const visible = element => {
          const style = getComputedStyle(element);
          return style.display !== 'none' && style.visibility !== 'hidden' && element.getClientRects().length > 0;
        };
        const signInVisible = Array.from(document.querySelectorAll('a, button')).some(element => {
          const href = element instanceof HTMLAnchorElement ? (element.getAttribute('href') || '') : '';
          const label = (element.innerText || element.textContent || '').trim();
          const lowerHref = href.toLowerCase();
          const lowerLabel = label.toLowerCase();
          return visible(element) && (lowerHref.includes('/auth/login') || lowerLabel === 'log in' || lowerLabel === 'sign in');
        });
        const browserChallengeVisible = Boolean(document.querySelector(
          '#challenge-form, iframe[src*="challenges.cloudflare.com"], [data-testid*="challenge"]'
        ));
        return {
          page,
          documentReadyState: document.readyState,
          signInVisible,
          browserChallengeVisible
        };
        """
        let result = try? await webView.callAsyncJavaScript(
            diagnosticsScript,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let values = result as? [String: Any]
        let allowedPages = ["conversation", "home", "other", "external"]
        let pageValue = values?["page"] as? String ?? "unknown"
        let page = allowedPages.contains(pageValue) ? pageValue : "unknown"
        let readyValue = values?["documentReadyState"] as? String ?? "unknown"
        let documentReadyState = ["loading", "interactive", "complete"].contains(readyValue) ? readyValue : "unknown"
        let signInVisible = values?["signInVisible"] as? Bool ?? false
        let browserChallengeVisible = values?["browserChallengeVisible"] as? Bool ?? false
        let timeoutSeconds = timeout.map { max(0, Int($0.rounded(.up))) }

        Self.logger.error(
            "Work composer unavailable; phase=\(phase, privacy: .public), page=\(page, privacy: .public), document=\(documentReadyState, privacy: .public), signIn=\(signInVisible, privacy: .public), browserChallenge=\(browserChallengeVisible, privacy: .public)"
        )
        return .composerUnavailable(
            phase: phase,
            page: page,
            documentReadyState: documentReadyState,
            signInVisible: signInVisible,
            browserChallengeVisible: browserChallengeVisible,
            timeoutSeconds: timeoutSeconds
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigationIfNeeded()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        finishNavigationIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    private func finishNavigationIfNeeded() {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    private static func isBrowserCheckCookie(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased == "cf_clearance" || lowercased.hasPrefix("__cf")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

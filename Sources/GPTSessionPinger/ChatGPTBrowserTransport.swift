import AppKit
import Foundation
import OSLog
import WebKit

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

    func resolveAuth(cookieHeader: String) async throws -> ChatGPTAuthSession {
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
        reasoningEffort: String,
        cookieHeader: String,
        timeout: TimeInterval
    ) async throws -> ChatGPTBrowserResponse {
        let webView = try await preparedWebView(cookieHeader: cookieHeader)
        try await loadChatGPT(
            in: webView,
            conversationID: conversationID,
            model: model,
            reasoningEffort: reasoningEffort
        )
        return try await sendThroughComposer(
            message,
            existingConversationID: conversationID,
            in: webView,
            timeout: timeout
        )
    }

    private func preparedWebView(cookieHeader: String) async throws -> WKWebView {
        let webView: WKWebView
        let isNewWebView: Bool
        if let existing = self.webView {
            webView = existing
            isNewWebView = false
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            isNewWebView = true

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

        await installCookies(
            cookieHeader,
            into: webView.configuration.websiteDataStore.httpCookieStore,
            clearStaleBrowserChecks: isNewWebView
        )
        if webView.url?.host == "chatgpt.com", !webView.isLoading { return webView }

        try await loadChatGPT(in: webView)
        return webView
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
        reasoningEffort: String
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
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "reasoning_effort", value: reasoningEffort)
        ]
        return components.url
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
            return failureResponse(status: 503, message: "ChatGPT composer did not become ready.")
        }

        let baselineResult = try await webView.callAsyncJavaScript(
            """
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
            arguments: ["message": message],
            in: nil,
            contentWorld: .page
        )
        guard let baseline = baselineResult as? [String: Any],
              baseline["ready"] as? Bool == true else {
            return failureResponse(status: 503, message: "ChatGPT composer was unavailable.")
        }
        let assistantCount = baseline["assistantCount"] as? Int ?? 0

        var submitted = false
        while Date() < deadline {
            if let didSubmit = try? await webView.callAsyncJavaScript(
                """
                const button = document.querySelector('[data-testid="send-button"]');
                if (!button || button.disabled) return false;
                button.click();
                return true;
                """,
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? Bool, didSubmit {
                submitted = true
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard submitted else {
            return failureResponse(status: 422, message: "ChatGPT did not accept the composer text.")
        }

        while Date() < deadline {
            if let state = try? await composerState(in: webView),
               state.assistantCount > assistantCount,
               !state.isGenerating,
               !state.replyText.isEmpty {
                let resolvedConversationID = state.conversationID ?? existingConversationID
                guard let resolvedConversationID, !resolvedConversationID.isEmpty else {
                    return failureResponse(status: 502, message: "ChatGPT sent the ping but did not expose its conversation ID.")
                }
                return ChatGPTBrowserResponse(
                    statusCode: 200,
                    body: Data(state.replyText.utf8),
                    contentType: "text/plain",
                    browserCheckHeader: "",
                    conversationID: resolvedConversationID,
                    replyText: state.replyText
                )
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return failureResponse(status: 504, message: "ChatGPT did not finish the ping before the timeout.")
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
              replyText: assistants.length ? (assistants[assistants.length - 1].innerText || '').trim() : ''
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

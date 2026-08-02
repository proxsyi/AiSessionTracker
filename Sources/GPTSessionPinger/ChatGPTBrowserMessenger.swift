import AppKit
import Foundation
import WebKit

/// Sends a turn through ChatGPT's real web page when the backend requires a
/// browser verification token. The temporary off-screen window uses the same
/// persistent WKWebView data store as the in-app login, then closes as soon as
/// ChatGPT finishes the reply.
@MainActor
final class ChatGPTBrowserMessenger {
    static let shared = ChatGPTBrowserMessenger()

    private init() {}

    func send(
        message: String,
        model: String,
        conversationID: String?,
        previousNodeID: String?,
        auth: ChatGPTAuthSession,
        cookieHeader: String,
        timeoutSeconds: TimeInterval
    ) async throws -> PingOutcome {
        let previouslyFrontmostApp = NSWorkspace.shared.frontmostApplication
        let previouslyKeyWindow = NSApp.keyWindow
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780), configuration: configuration)
        webView.customUserAgent = ChatGPTWebSession.userAgent

        let showForTesting = UserDefaults.standard.bool(forKey: "showPingBrowserForTesting")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: showForTesting ? [.titled, .closable, .resizable] : [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.title = showForTesting ? "ChatGPT Ping Browser Test" : ""
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.alphaValue = showForTesting ? 1 : 0.02
        window.ignoresMouseEvents = !showForTesting
        window.isReleasedWhenClosed = false
        window.center()
        if showForTesting {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // WebKit suspends ChatGPT's verification/generation pipeline in
            // a non-key occluded window. Keep this temporary window active,
            // nearly transparent, and mouse-transparent until the reply is
            // complete; it is closed in the defer block above.
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        defer {
            webView.stopLoading()
            window.orderOut(nil)
            window.close()
            if previouslyFrontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
                previouslyKeyWindow?.makeKeyAndOrderFront(nil)
            } else {
                previouslyFrontmostApp?.activate(options: [.activateIgnoringOtherApps])
            }
        }

        await seedCookies(cookieHeader, into: configuration.websiteDataStore.httpCookieStore)
        let trimmedConversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try load(
            webView,
            conversationID: trimmedConversationID.nilIfEmpty,
            model: model
        )

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var composerReady = false
        while Date() < deadline {
            if try await isComposerReady(webView) {
                composerReady = true
                break
            }
            if !trimmedConversationID.isEmpty, try await pageSaysConversationMissing(webView) {
                try load(webView, conversationID: nil, model: model)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard composerReady else {
            if let url = webView.url, url.path.contains("auth") || url.path.contains("login") {
                throw PingError.sessionExpired
            }
            throw PingError.unexpectedResponse("The signed-in ChatGPT page did not make its message box available.")
        }

        let baseline = try await assistantSnapshot(webView)
        let sent = try await fillAndSend(message, in: webView)
        guard sent else {
            throw PingError.unexpectedResponse("ChatGPT's message box loaded, but its Send button did not become available.")
        }

        var lastSnapshot = baseline
        var stableReplyPolls = 0
        var lastBackendError = "none"
        while Date() < deadline {
            let currentConversationID = conversationIDFromURL(webView.url) ?? trimmedConversationID
            if !currentConversationID.isEmpty {
                do {
                    if let turn = try await backendAssistantTurn(
                        conversationID: currentConversationID,
                        previousNodeID: previousNodeID,
                        auth: auth,
                        cookies: cookieHeader
                    ), turn.isComplete {
                        return PingOutcome(
                            conversationID: currentConversationID,
                            replyText: turn.text,
                            matchedExpected: true
                        )
                    }
                } catch let error as PingError {
                    switch error {
                    case .sessionExpired, .rateLimited:
                        throw error
                    default:
                        lastBackendError = error.localizedDescription
                    }
                }
            }

            let snapshot = try await assistantSnapshot(webView)
            if snapshot.count > baseline.count, !snapshot.text.isEmpty {
                if snapshot.text == lastSnapshot.text {
                    stableReplyPolls += 1
                } else {
                    stableReplyPolls = 0
                }
            }
            if snapshot.count > baseline.count,
               !snapshot.text.isEmpty,
               (!snapshot.isStreaming || stableReplyPolls >= 4) {
                let finalConversationID = conversationIDFromURL(webView.url) ?? trimmedConversationID
                guard !finalConversationID.isEmpty else {
                    throw PingError.unexpectedResponse("ChatGPT replied but did not expose the conversation URL.")
                }
                return PingOutcome(
                    conversationID: finalConversationID,
                    replyText: snapshot.text,
                    matchedExpected: true
                )
            }
            lastSnapshot = snapshot
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let path = webView.url?.path ?? "unknown"
        let alert = lastSnapshot.alertText.isEmpty ? "none" : lastSnapshot.alertText
        throw PingError.unexpectedResponse(
            "ChatGPT browser timed out (page \(path), assistant turns \(baseline.count)→\(lastSnapshot.count), user turns \(baseline.userCount)→\(lastSnapshot.userCount), reply characters \(lastSnapshot.text.count), page alert: \(alert), conversation check: \(lastBackendError))."
        )
    }

    private func backendAssistantTurn(
        conversationID: String,
        previousNodeID: String?,
        auth: ChatGPTAuthSession,
        cookies: String
    ) async throws -> ChatGPTAssistantTurn? {
        guard let request = ChatGPTWebSession.makeBackendRequest(
            path: "/conversation/\(conversationID)",
            auth: auth,
            cookieHeader: cookies
        ) else { throw PingError.invalidURL }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw PingError.network(error)
        } catch {
            throw PingError.unknown(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PingError.unexpectedResponse("No HTTP response while checking the ChatGPT reply.")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw PingError.sessionExpired
        case 429:
            throw PingError.rateLimited
        default:
            throw PingError.serverError(http.statusCode, "ChatGPT could not read the pinger conversation.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PingError.unexpectedResponse("ChatGPT returned an unreadable conversation while checking the reply.")
        }
        return ChatGPTConversationParser.newestAssistantTurn(
            in: object,
            stoppingAt: previousNodeID
        )
    }

    private func load(_ webView: WKWebView, conversationID: String?, model: String) throws {
        var components = URLComponents(string: "https://chatgpt.com/")!
        if let conversationID {
            components.path = "/c/\(conversationID)"
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { throw PingError.invalidURL }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    private func seedCookies(_ header: String, into store: WKHTTPCookieStore) async {
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !pair[1].isEmpty,
                  let cookie = HTTPCookie(properties: [
                    .domain: ".chatgpt.com",
                    .path: "/",
                    .name: name,
                    .value: pair[1],
                    .secure: "TRUE"
                  ]) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func isComposerReady(_ webView: WKWebView) async throws -> Bool {
        let script = """
        (() => {
          const prompt = document.querySelector('#prompt-textarea') ||
            document.querySelector('textarea[placeholder]') ||
            document.querySelector('[contenteditable="true"][role="textbox"]');
          return Boolean(prompt && !prompt.closest('[aria-hidden="true"]'));
        })()
        """
        return (try await evaluate(script, in: webView) as? Bool) == true
    }

    private func pageSaysConversationMissing(_ webView: WKWebView) async throws -> Bool {
        let script = """
        (() => {
          const text = (document.body?.innerText || '').toLowerCase();
          return text.includes('unable to load conversation') ||
            text.includes('conversation not found') ||
            text.includes('chat not found');
        })()
        """
        return (try await evaluate(script, in: webView) as? Bool) == true
    }

    private struct AssistantSnapshot {
        let count: Int
        let userCount: Int
        let text: String
        let isStreaming: Bool
        let alertText: String
    }

    private func assistantSnapshot(_ webView: WKWebView) async throws -> AssistantSnapshot {
        let script = """
        (() => {
          let messages = Array.from(document.querySelectorAll('[data-message-author-role="assistant"]'));
          if (!messages.length) {
            messages = Array.from(document.querySelectorAll('article[data-testid^="conversation-turn-"]'))
              .filter(turn => turn.querySelector('[data-message-author-role="assistant"]'));
          }
          const users = Array.from(document.querySelectorAll('[data-message-author-role="user"]'));
          const last = messages[messages.length - 1];
          const streaming = Boolean(
            document.querySelector('button[data-testid="stop-button"]') ||
            document.querySelector('button[aria-label*="Stop"]')
          );
          const alertText = Array.from(document.querySelectorAll('[role="alert"]'))
            .map(node => (node.innerText || '').trim()).filter(Boolean).join(' · ').slice(0, 160);
          return { count: messages.length, userCount: users.length, text: (last?.innerText || last?.textContent || '').trim(), streaming, alertText };
        })()
        """
        guard let result = try await evaluate(script, in: webView) as? [String: Any] else {
            return AssistantSnapshot(count: 0, userCount: 0, text: "", isStreaming: false, alertText: "")
        }
        return AssistantSnapshot(
            count: (result["count"] as? NSNumber)?.intValue ?? 0,
            userCount: (result["userCount"] as? NSNumber)?.intValue ?? 0,
            text: result["text"] as? String ?? "",
            isStreaming: result["streaming"] as? Bool ?? false,
            alertText: result["alertText"] as? String ?? ""
        )
    }

    private func fillAndSend(_ message: String, in webView: WKWebView) async throws -> Bool {
        let encodedMessage = try JSONSerialization.data(withJSONObject: [message])
        guard var messageArray = String(data: encodedMessage, encoding: .utf8) else { return false }
        messageArray.removeFirst()
        messageArray.removeLast()
        let script = """
        (() => {
          const prompt = document.querySelector('#prompt-textarea') ||
            document.querySelector('textarea[placeholder]') ||
            document.querySelector('[contenteditable="true"][role="textbox"]');
          if (!prompt) return false;
          const message = \(messageArray);
          prompt.focus();
          if (prompt instanceof HTMLTextAreaElement || prompt instanceof HTMLInputElement) {
            const setter = Object.getOwnPropertyDescriptor(prompt.constructor.prototype, 'value')?.set;
            setter?.call(prompt, message);
          } else {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, message);
          }
          prompt.dispatchEvent(new InputEvent('input', {
            bubbles: true,
            composed: true,
            inputType: 'insertText',
            data: message
          }));
          prompt.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })()
        """
        guard (try await evaluate(script, in: webView) as? Bool) == true else { return false }

        for _ in 0..<20 {
            let clickScript = """
            (() => {
              const button = document.querySelector('button[data-testid="send-button"]') ||
                document.querySelector('button[aria-label*="Send"]');
              if (!button || button.disabled) return false;
              button.click();
              return true;
            })()
            """
            if (try await evaluate(clickScript, in: webView) as? Bool) == true { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: PingError.unexpectedResponse(error.localizedDescription))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func conversationIDFromURL(_ url: URL?) -> String? {
        guard let url else { return nil }
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "c"), components.indices.contains(index + 1) else { return nil }
        let value = components[index + 1]
        return value.isEmpty ? nil : value
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

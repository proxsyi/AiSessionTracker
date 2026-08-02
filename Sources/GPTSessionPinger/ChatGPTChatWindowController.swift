import AppKit
import WebKit

@MainActor
final class ChatGPTChatWindowController: NSObject, NSWindowDelegate {
    static let shared = ChatGPTChatWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?

    func openConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let url = URL(string: "https://chatgpt.com/c/\(trimmedID)") else { return }

        let webView = self.webView ?? makeWebView()
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))

        let window = self.window ?? makeWindow(containing: webView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = ChatGPTWebSession.userAgent
        self.webView = webView
        return webView
    }

    private func makeWindow(containing webView: WKWebView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GPT Pinger Chat"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        window = nil
        webView = nil
    }
}

import WebKit
import XCTest
@testable import GPTSessionPinger

@MainActor
final class WebsiteDataTests: XCTestCase {
    func testClearRemovesEmbeddedBrowserCookies() async throws {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".chatgpt.com",
            .path: "/",
            .name: "session-pinger-clear-test",
            .value: "dummy",
            .secure: "TRUE"
        ]))
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }

        await ChatGPTWebsiteData.clear()

        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(cookies.contains(where: { $0.name == "session-pinger-clear-test" }))
    }
}

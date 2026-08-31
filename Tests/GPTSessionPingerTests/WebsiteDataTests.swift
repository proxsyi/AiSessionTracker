import WebKit
import XCTest
import TrackerDesignSystem
@testable import GPTTrackerFeature

@MainActor
final class WebsiteDataTests: XCTestCase {
    func testClearRemovesEmbeddedBrowserCookies() async throws {
        let websiteStore = WKWebsiteDataStore.nonPersistent()
        let store = websiteStore.httpCookieStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".chatgpt.com",
            .path: "/",
            .name: "usage-tracker-clear-test",
            .value: "dummy",
            .secure: "TRUE"
        ]))
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }

        await TrackerWebsiteData.clear(domains: TrackerWebsiteData.openAIDomains, store: websiteStore)

        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(cookies.contains(where: { $0.name == "usage-tracker-clear-test" }))
    }

    func testLoggingOutOfEitherProviderPreservesTheOtherProvidersCookies() async throws {
        for domains in [TrackerWebsiteData.claudeDomains, TrackerWebsiteData.openAIDomains] {
            let store = WKWebsiteDataStore.nonPersistent()
            for domain in [".claude.ai", ".chatgpt.com", ".auth.openai.com", ".unrelated.example"] {
                let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "isolation-test", .value: "dummy", .secure: "TRUE"]))
                await withCheckedContinuation { continuation in
                    store.httpCookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
            await TrackerWebsiteData.clear(domains: domains, store: store)
            let remaining = await withCheckedContinuation { continuation in
                store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            XCTAssertFalse(remaining.contains { TrackerWebsiteData.matches($0.domain, domains: domains) })
            let expected = domains == TrackerWebsiteData.claudeDomains ? 3 : 2
            XCTAssertEqual(remaining.count, expected)
        }
    }

    func testCookieOwnershipRequiresADomainBoundary() {
        XCTAssertTrue(TrackerWebsiteData.matches(".auth.openai.com", domains: TrackerWebsiteData.openAIDomains))
        XCTAssertFalse(TrackerWebsiteData.matches("notopenai.com", domains: TrackerWebsiteData.openAIDomains))
        XCTAssertFalse(TrackerWebsiteData.matches("openai.com.example", domains: TrackerWebsiteData.openAIDomains))
    }
}

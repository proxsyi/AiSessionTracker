import Foundation
import XCTest
@testable import GPTTrackerFeature

final class ChatGPTClientTests: XCTestCase {
    func testComposerURLKeepsTheConversationAndLowUsageModel() throws {
        let url = try XCTUnwrap(ChatGPTBrowserTransport.conversationURL(
            conversationID: "shared-conversation",
            model: "gpt-5.4-mini",
            reasoningEffort: "low"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(components.path, "/c/shared-conversation")
        XCTAssertEqual(query["model"]!, "gpt-5.4-mini")
        XCTAssertEqual(query["reasoning_effort"]!, "low")
    }
}

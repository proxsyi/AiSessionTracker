import Foundation
import XCTest
@testable import GPTTrackerFeature

final class ChatGPTClientTests: XCTestCase {
    func testPingPayloadKeepsTheConversationAsACloudChat() throws {
        let body = try ChatGPTClient.makeRequestBody(
            model: "gpt-5.4-mini",
            reasoningEffort: "low",
            message: "Say 1",
            conversationID: "shared-conversation",
            parentMessageID: "latest-parent"
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(payload["conversation_id"] as? String, "shared-conversation")
        XCTAssertEqual(payload["parent_message_id"] as? String, "latest-parent")
        XCTAssertEqual(payload["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(payload["reasoning_effort"] as? String, "low")
        XCTAssertEqual(payload["temporary"] as? Bool, false)
        XCTAssertEqual(payload["history_and_training_disabled"] as? Bool, false)
    }
}

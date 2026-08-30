import XCTest
@testable import CombinedSessionTracker

final class ClaudeClientTests: XCTestCase {
    func testEndedConversationIsReplacedOnce() {
        XCTAssertTrue(ClaudeClient.shouldReplaceConversation(after: .serverError(
            400,
            "This conversation has been ended by Claude. Please start a new conversation to continue chatting."
        )))
        XCTAssertTrue(ClaudeClient.shouldReplaceConversation(after: .serverError(404, "Not found")))
    }

    func testUnrelatedClientErrorDoesNotDiscardTheDedicatedConversation() {
        XCTAssertFalse(ClaudeClient.shouldReplaceConversation(after: .serverError(400, "Invalid model")))
        XCTAssertFalse(ClaudeClient.shouldReplaceConversation(after: .serverError(500, "Temporary failure")))
    }
}

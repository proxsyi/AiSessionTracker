import XCTest
@testable import GPTSessionPinger

final class ConversationParserTests: XCTestCase {
    func testParserWalksCurrentBranchAndStopsBeforePreviousNode() throws {
        let object: [String: Any] = [
            "current_node": "assistant-new",
            "mapping": [
                "assistant-old": [
                    "parent": "root",
                    "message": [
                        "author": ["role": "assistant"],
                        "content": ["parts": ["old reply"]],
                        "status": "finished_successfully"
                    ]
                ],
                "user-new": ["parent": "assistant-old", "message": ["author": ["role": "user"]]],
                "assistant-new": [
                    "parent": "user-new",
                    "message": [
                        "author": ["role": "assistant"],
                        "content": ["parts": [["text": "new reply"]]],
                        "status": "finished_successfully"
                    ]
                ]
            ]
        ]

        let turn = try XCTUnwrap(ChatGPTConversationParser.newestAssistantTurn(
            in: object,
            stoppingAt: "assistant-old"
        ))

        XCTAssertEqual(turn.nodeID, "assistant-new")
        XCTAssertEqual(turn.text, "new reply")
        XCTAssertTrue(turn.isComplete)
    }
}

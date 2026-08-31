import Foundation
import JavaScriptCore
import XCTest
@testable import GPTTrackerFeature

final class ConversationIdentityTests: XCTestCase {
    func testSavedChatMustMatchExactly() throws {
        XCTAssertEqual(try ChatGPTConversationIdentity.validate(expected: "work-a", observed: "work-a"), "work-a")
        for observed in [nil, "", "work-b", "chat-a"] as [String?] {
            XCTAssertThrowsError(try ChatGPTConversationIdentity.validate(expected: "work-a", observed: observed))
        }
    }

    func testFirstChatCanBindOnlyToAnObservedID() throws {
        XCTAssertEqual(try ChatGPTConversationIdentity.validate(expected: nil, observed: "work-a"), "work-a")
        XCTAssertThrowsError(try ChatGPTConversationIdentity.validate(expected: nil, observed: nil))
    }

    func testRedirectsAndMissingChatsAreRejectedBeforeSending() throws {
        XCTAssertNoThrow(try ChatGPTConversationIdentity.validatePage(expected: "work-a", url: URL(string: "https://chatgpt.com/c/work-a?model=test")))
        for value in ["https://chatgpt.com/", "https://chatgpt.com/c/work-b", "https://example.com/c/work-a", "http://chatgpt.com/c/work-a"] {
            XCTAssertThrowsError(try ChatGPTConversationIdentity.validatePage(expected: "work-a", url: URL(string: value)))
        }
    }

    func testNewChatRequiresARealNewChatPage() throws {
        XCTAssertNoThrow(try ChatGPTConversationIdentity.validatePage(expected: nil, url: URL(string: "https://chatgpt.com/")))
        XCTAssertThrowsError(try ChatGPTConversationIdentity.validatePage(expected: nil, url: URL(string: "https://chatgpt.com/c/unrelated")))
    }

    func testActualComposerGuardPreventsClickAfterRedirect() throws {
        for path in ["/c/work-a", "/c/work-b", "/"] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("var location = {origin: 'https://chatgpt.com', pathname: '\(path)'}; var expectedConversationID = 'work-a'; var clicks = 0;")
            context.evaluateScript("(function () {\n" + ChatGPTConversationIdentity.pageGuardScript + "\nclicks++; return true; })();")
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.objectForKeyedSubscript("clicks")?.toInt32(), path == "/c/work-a" ? 1 : 0)
        }
    }

    func testOldPingHistoryStillDecodesWithoutConversationID() throws {
        let data = Data("{\"id\":\"63a94a72-16dc-418a-9d19-abbe7b45c8ed\",\"date\":0,\"success\":true,\"summary\":\"Got reply\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(CodexSessionPinger.PingRecord.self, from: data).conversationID)
    }

    func testEarlierReplyCannotConfirmANewPing() {
        let payload: [String: Any] = ["mapping": ["previous": ["message": [
            "author": ["role": "assistant"], "create_time": 20,
            "metadata": ["model_slug": "work-model"]
        ]]]]
        XCTAssertNil(ChatGPTClient.parseConversationSnapshot(payload, createdAfter: Date(timeIntervalSince1970: 21)))
        XCTAssertNotNil(ChatGPTClient.parseConversationSnapshot(payload, createdAfter: Date(timeIntervalSince1970: 19)))
    }
}

@MainActor
final class BrowserOperationGateTests: XCTestCase {
    func testBrowserOperationsRemainSerializedAcrossSuspensions() async throws {
        let gate = ChatGPTBrowserOperationGate()
        try await gate.acquire()
        var order: [String] = []
        let codex = Task { @MainActor in
            try await gate.acquire()
            defer { gate.release() }
            order.append("codex-start")
            await Task.yield()
            order.append("codex-end")
        }
        while gate.waitingCount != 1 { await Task.yield() }
        let chat = Task { @MainActor in
            try await gate.acquire()
            defer { gate.release() }
            order.append("chat-start")
            await Task.yield()
            order.append("chat-end")
        }
        while gate.waitingCount != 2 { await Task.yield() }
        XCTAssertTrue(order.isEmpty)
        gate.release()
        try await codex.value
        try await chat.value
        XCTAssertEqual(order, ["codex-start", "codex-end", "chat-start", "chat-end"])
    }

    func testCancelledWaiterDoesNotStealOrLeakTheBrowserPermit() async throws {
        let gate = ChatGPTBrowserOperationGate()
        try await gate.acquire()
        let cancelled = Task { @MainActor in
            try await gate.acquire()
            gate.release()
            XCTFail("Cancelled operation must not navigate the browser")
        }
        while gate.waitingCount != 1 { await Task.yield() }
        cancelled.cancel()
        gate.release()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await gate.acquire()
        gate.release()
    }
}

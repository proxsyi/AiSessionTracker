import Foundation
import XCTest
@testable import GPTTrackerFeature

final class ChatGPTClientTests: XCTestCase {
    func testComposerURLKeepsTheConversationAndLowestUsageModel() throws {
        let url = try XCTUnwrap(ChatGPTBrowserTransport.conversationURL(
            conversationID: "shared-conversation",
            model: "gpt-5-3-mini",
            reasoningEffort: "none"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(components.path, "/c/shared-conversation")
        XCTAssertEqual(query["model"]!, "gpt-5-3-mini")
        XCTAssertFalse(query.keys.contains("reasoning_effort"))
        XCTAssertFalse(query.keys.contains("thinking_effort"))
    }

    func testComposerURLUsesBothLiveThinkingEffortQueryNames() throws {
        let url = try XCTUnwrap(ChatGPTBrowserTransport.conversationURL(
            conversationID: nil,
            model: "gpt-5-6-thinking",
            reasoningEffort: "standard"
        ))
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["reasoning_effort"]!, "standard")
        XCTAssertEqual(query["thinking_effort"]!, "standard")
    }

    func testResponseMetadataUsesTheLatestAssistantMessage() throws {
        let payload: [String: Any] = [
            "mapping": [
                "old": ["message": [
                    "author": ["role": "assistant"],
                    "create_time": 10,
                    "metadata": ["model_slug": "older-model", "reasoning_effort": "medium"]
                ]],
                "latest": ["message": [
                    "author": ["role": "assistant"],
                    "create_time": 20,
                    "metadata": ["model_slug": "gpt-5-3-mini", "reasoning_effort": "none"]
                ]]
            ]
        ]

        XCTAssertEqual(
            ChatGPTClient.parseResponseMetadata(payload),
            ChatGPTResponseMetadata(model: "gpt-5-3-mini", reasoningEffort: "none")
        )
    }

    func testConversationSnapshotReadsReplyFromTheCloudConversationRecord() throws {
        let payload: [String: Any] = [
            "mapping": [
                "reply": ["message": [
                    "author": ["role": "assistant"],
                    "create_time": 20,
                    "content": ["content_type": "text", "parts": ["1"]],
                    "metadata": ["model_slug": "gpt-5-3-mini", "reasoning_effort": "none"]
                ]]
            ]
        ]

        XCTAssertEqual(
            ChatGPTClient.parseConversationSnapshot(payload),
            ChatGPTConversationSnapshot(
                replyText: "1",
                metadata: ChatGPTResponseMetadata(model: "gpt-5-3-mini", reasoningEffort: "none")
            )
        )
    }

    func testMissingMetadataNeverPretendsTheRequestedModelWasConfirmed() {
        XCTAssertNil(ChatGPTClient.parseResponseMetadata([
            "mapping": ["reply": ["message": ["author": ["role": "assistant"], "metadata": [:]]]]
        ]))
        XCTAssertTrue(CodexSessionPinger.modelConfirmationText(
            requestedModel: "gpt-5-3-mini",
            requestedEffort: "none",
            confirmedModel: nil,
            confirmedEffort: nil
        ).contains("did not expose confirmation"))
    }

    func testModelCatalogParsesRealChatModelsAndEfforts() throws {
        let payload: [String: Any] = ["models": [
            ["slug": "gpt-5-3-mini", "title": "GPT-5.3 Mini", "reasoning_type": "none", "thinking_efforts": []],
            ["slug": "gpt-5-6-thinking", "title": "GPT-5.6 Sol", "reasoning_type": "reasoning", "thinking_efforts": [
                ["thinking_effort": "standard", "short_label": "Standard"],
                ["thinking_effort": "extended", "short_label": "Extended"]
            ]],
            ["slug": "gpt-5.6-terra-wm", "title": "GPT-5.6 Terra", "reasoning_type": "reasoning", "is_work_mode_model": true],
            ["slug": "research", "title": "Deep Research"]
        ]]
        let models = ChatGPTModelCatalog.parse(payload)
        XCTAssertEqual(models.map(\.slug), ["gpt-5-3-mini", "gpt-5-6-thinking", "gpt-5.6-terra-wm"])
        XCTAssertEqual(models[0].selectableEfforts, [ChatGPTThinkingEffort(id: "none", title: "None")])
        XCTAssertEqual(models[1].selectableEfforts.map(\.id), ["standard", "extended"])
        XCTAssertTrue(models[2].isWorkMode)
        XCTAssertEqual(models[2].selectableEfforts.map(\.id), ["min"])
    }
}

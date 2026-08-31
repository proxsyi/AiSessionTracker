import XCTest
import TrackerDesignSystem
@testable import GPTTrackerFeature

final class ModelPresentationTests: XCTestCase {
    func testCleanProviderModelNames() {
        XCTAssertEqual(TrackerModelLabels.openAI("gpt-5.6-sol-wm", title: "GPT-5.6 Sol"), "5.6 Sol")
        XCTAssertEqual(TrackerModelLabels.openAI("gpt-5-3-mini"), "5.3 Mini")
        XCTAssertEqual(ChatGPTModelCatalog.fallbackTitle(for: "gpt-5.6-sol-wm"), "5.6 Sol")
        XCTAssertEqual(TrackerModelLabels.claude("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(TrackerModelLabels.claude("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(TrackerModelLabels.claude("claude-opus-4-6"), "Opus 4.6")
    }

    func testEffortUsesProviderLabelWithoutWireValues() {
        XCTAssertEqual(TrackerModelLabels.effort("high"), "High")
        XCTAssertEqual(TrackerModelLabels.effort("min"), "Light")
        XCTAssertEqual(TrackerModelLabels.effort("extended", title: "Extended"), "Extended")
        XCTAssertEqual(TrackerModelLabels.effort("extended", title: "High"), "High")
    }

    func testSameNamedChatVariantsRemainDistinguishable() {
        let models = ChatGPTModelCatalog.parse(["models": [
            ["slug": "gpt-5-6", "title": "GPT-5.6 Sol"],
            ["slug": "gpt-5-6-instant", "title": "GPT-5.6 Sol"],
            ["slug": "gpt-5-6-thinking", "title": "GPT-5.6 Sol"]
        ]])
        XCTAssertEqual(models.map(\.displayTitle), ["5.6 Sol", "5.6 Sol Instant", "5.6 Sol Thinking"])
    }

    func testLowestChoiceUsesLiveCatalogAndKeepsWorkSeparateFromChat() {
        let models = ChatGPTModelCatalog.parse(["models": [
            ["slug": "gpt-5.6-sol-wm", "title": "GPT-5.6 Sol", "reasoning_type": "reasoning", "is_work_mode_model": true],
            ["slug": "gpt-5.6-luna-wm", "title": "GPT-5.6 Luna", "reasoning_type": "reasoning", "is_work_mode_model": true],
            ["slug": "gpt-5-3-mini", "title": "GPT-5.3 Mini", "reasoning_type": "none"],
            ["slug": "gpt-5-4-t-mini", "title": "GPT-5.4 Thinking Mini", "reasoning_type": "reasoning"]
        ]])
        let work = ChatGPTModelCatalog.lowestUsageOption(in: models, workMode: true)!
        let chat = ChatGPTModelCatalog.lowestUsageOption(in: models, workMode: false)!
        XCTAssertEqual(work.slug, "gpt-5.6-luna-wm")
        XCTAssertEqual(chat.slug, "gpt-5-3-mini")
        XCTAssertEqual(ChatGPTModelCatalog.lowestEffort(for: work).id, "min")
        XCTAssertEqual(ChatGPTModelCatalog.lowestEffort(for: chat).id, "none")
        XCTAssertNil(ChatGPTModelCatalog.lowestUsageOption(in: [], workMode: true))
        XCTAssertEqual(ChatGPTModelCatalog.lowestUsageOption(in: Array(models.reversed()), workMode: false)?.slug,
            "gpt-5-3-mini", "Prefer non-reasoning Mini regardless of catalog order")
    }

    func testAvailableEffortLabelsAndLowestOrderAreNotReplacedByAPIConventions() {
        let models = ChatGPTModelCatalog.parse(["models": [[
            "slug": "gpt-5-6-thinking", "title": "GPT-5.6 Sol", "reasoning_type": "reasoning",
            "thinking_efforts": [
                ["thinking_effort": "extended", "short_label": "Extended"],
                ["thinking_effort": "standard", "short_label": "Standard"]
            ]
        ]]])
        XCTAssertEqual(models[0].selectableEfforts.map(\.title), ["Extended", "Standard"])
        XCTAssertEqual(ChatGPTModelCatalog.lowestEffort(for: models[0]).id, "standard")
    }
}

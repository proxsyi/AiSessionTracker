import Foundation
import XCTest
@testable import GPTUsageTracker

final class UsageCheckerTests: XCTestCase {
    func testAgenticWindowsAreMatchedAndLabeledByDuration() {
        let object: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 25,
                    "limit_window_seconds": 18_000,
                    "reset_at": 2_000_000_000
                ],
                "secondary_window": [
                    "used_percent": 50,
                    "limit_window_seconds": 604_800,
                    "reset_at": 2_000_100_000
                ]
            ]
        ]

        let tracks = UsageChecker.parseAgenticTracks(object)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].title, "Codex / agentic (5 hour)")
        XCTAssertEqual(tracks[0].usedPercent, 25)
        XCTAssertEqual(tracks[1].title, "Codex / agentic (7 day)")
        XCTAssertEqual(tracks[1].usedPercent, 50)
    }

    func testThirtyDayWindowIsNeverPresentedAsFiveHourSession() throws {
        let object: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0,
                    "limit_window_seconds": 2_592_000,
                    "reset_at": 2_000_000_000
                ]
            ]
        ]

        let track = try XCTUnwrap(UsageChecker.parseAgenticTracks(object).first)

        XCTAssertEqual(track.scope, .codex)
        XCTAssertEqual(track.title, "Codex / agentic (30 day)")
        XCTAssertNotEqual(track.windowSeconds, 18_000)
    }

    func testFeatureRemainingDoesNotFabricatePercentWithoutTotal() throws {
        let object: [String: Any] = [
            "limits_progress": [[
                "feature_name": "deep_research",
                "remaining": 17,
                "reset_after": "2026-08-30T12:34:56.123456+00:00"
            ]]
        ]

        let track = try XCTUnwrap(UsageChecker.parseChatGPTTracks(object).first)

        XCTAssertEqual(track.title, "Deep research")
        XCTAssertEqual(track.remaining, 17)
        XCTAssertNil(track.usedPercent)
        XCTAssertNotNil(track.resetsAt)
    }

    func testFeaturePercentIsDerivedOnlyWhenServerProvidesTotal() throws {
        let object: [String: Any] = [
            "limits_progress": [[
                "feature_name": "image_gen",
                "remaining": 20,
                "limit": 80
            ]]
        ]

        let track = try XCTUnwrap(UsageChecker.parseChatGPTTracks(object).first)

        XCTAssertEqual(track.usedPercent, 75)
        XCTAssertEqual(track.remainingText, "20 of 80 remaining")
    }

    func testAgenticCreditsAndCodeReviewArePreserved() {
        let object: [String: Any] = [
            "code_review_rate_limit": [
                "primary_window": [
                    "used_percent": 10,
                    "limit_window_seconds": 604_800,
                    "reset_after_seconds": 3_600
                ]
            ],
            "credits": ["unlimited": false, "balance": "45.25"],
            "spend_control": ["reached": false]
        ]

        let tracks = UsageChecker.parseAgenticTracks(object)

        XCTAssertEqual(tracks.first?.title, "Code review (7 day)")
        XCTAssertNotNil(tracks.first?.resetsAt)
        XCTAssertEqual(tracks.first(where: { $0.id == "codex-credits" })?.valueText, "$1.81 remaining")
        XCTAssertFalse(tracks.first(where: { $0.id == "codex-credits" })?.isBlocked ?? true)
        XCTAssertEqual(tracks.first(where: { $0.id == "workspace-spend-control" })?.valueText, "Available")
    }

    func testZeroPurchasedCreditsDoesNotMarkIncludedUsageUnavailable() throws {
        let tracks = UsageChecker.parseAgenticTracks([
            "credits": ["unlimited": false, "balance": 0]
        ])

        let credits = try XCTUnwrap(tracks.first)
        XCTAssertEqual(credits.valueText, "$0.00 remaining")
        XCTAssertFalse(credits.isBlocked)
    }

    func testCreditBalanceUsesReportedGrantAsRealDollarDenominator() throws {
        let track = try XCTUnwrap(UsageChecker.parseCreditBalanceTrack([
            "balance": "1875",
            "expiring_balance_details": [[
                "amount_granted": "2500",
                "amount_remaining": "1875",
                "expiry_date": "2027-08-08T02:00:54.336697Z"
            ]]
        ]))

        XCTAssertEqual(track.preferenceID, "codex-credits")
        XCTAssertEqual(track.usedPercent, 25)
        XCTAssertEqual(track.valueText, "$75.00 / $100.00 left")
        XCTAssertNotNil(track.resetsAt)
    }

    func testModelAndFeatureTrackIDsRemainStableAcrossPayloadOrdering() throws {
        let object: [String: Any] = [
            "model_limits": [[
                "model_slug": "gpt-5-4-t-mini",
                "remaining": 3
            ]],
            "limits_progress": [[
                "feature_name": "file_upload",
                "remaining": 2
            ]]
        ]
        let tracks = UsageChecker.parseChatGPTTracks(object)

        XCTAssertEqual(tracks.first(where: { $0.scope == .chatGPTModel })?.preferenceID, "model-gpt-5-4-t-mini")
        XCTAssertEqual(tracks.first(where: { $0.scope == .chatGPTFeature })?.preferenceID, "feature-file-uploads")
    }

    func testCodexRollingWindowsHaveIndependentPreferenceIDs() {
        let object: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 20, "limit_window_seconds": 18_000],
                "secondary_window": ["used_percent": 40, "limit_window_seconds": 604_800]
            ]
        ]
        let tracks = UsageChecker.parseAgenticTracks(object)

        XCTAssertEqual(tracks.map(\.preferenceID), ["codex-rolling-5h", "codex-weekly"])
    }

    func testAdditionalAgenticRollingWindowsAreNotDropped() {
        let object: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 10, "limit_window_seconds": 18_000],
                "tertiary_window": ["used_percent": 30, "limit_window_seconds": 2_592_000]
            ]
        ]

        let tracks = UsageChecker.parseAgenticTracks(object)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[1].preferenceID, "codex-window-2592000")
        XCTAssertEqual(tracks[1].title, "Codex / agentic (30 day)")
    }

    func testKeyedModelAndFeatureLimitsAreParsed() {
        let object: [String: Any] = [
            "model_limits": [
                "gpt-5-5-thinking": ["remaining_messages": 12, "message_limit": 20]
            ],
            "limits_progress": [
                "deep_research": ["remaining_count": 3, "total": 5]
            ]
        ]

        let tracks = UsageChecker.parseChatGPTTracks(object)

        XCTAssertEqual(tracks.first(where: { $0.scope == .chatGPTModel })?.preferenceID, "model-gpt-5-5-thinking")
        XCTAssertEqual(tracks.first(where: { $0.scope == .chatGPTModel })?.usedPercent, 40)
        XCTAssertEqual(tracks.first(where: { $0.scope == .chatGPTFeature })?.preferenceID, "feature-deep-research")
        XCTAssertEqual(tracks.first(where: { $0.scope == .chatGPTFeature })?.usedPercent, 40)
    }

    func testGlobalChatGPTMessageUsageUsesServerValues() throws {
        let object: [String: Any] = [
            "message_usage": [
                "remaining_messages": 30,
                "message_limit": 120,
                "reset_at": 2_000_000_000
            ]
        ]

        let track = try XCTUnwrap(
            UsageChecker.parseChatGPTTracks(object)
                .first(where: { $0.id == "chatgpt-message-usage" })
        )

        XCTAssertEqual(track.title, "All ChatGPT messages")
        XCTAssertEqual(track.usedPercent, 75)
        XCTAssertEqual(track.remaining, 30)
        XCTAssertEqual(track.limit, 120)
        XCTAssertEqual(track.resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testGlobalMessageBarIsNotInventedWithoutServerCounter() {
        let tracks = UsageChecker.parseChatGPTTracks([
            "conversation_id": "abc",
            "model": "gpt-5"
        ])

        XCTAssertFalse(tracks.contains(where: { $0.id == "chatgpt-message-usage" }))
    }

    func testGlobalMessageLimitAloneDoesNotPretendToBeUsage() {
        let tracks = UsageChecker.parseChatGPTTracks([
            "message_limit": 120
        ])

        XCTAssertFalse(tracks.contains(where: { $0.id == "chatgpt-message-usage" }))
    }

}

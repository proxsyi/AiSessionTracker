import XCTest
@testable import ClaudeSessionPinger

final class ClaudeUsageCheckerTests: XCTestCase {
    func testAccountPlanFindsNestedSubscriptionTier() {
        let object: [String: Any] = [
            "organization": [
                "subscription": ["subscription_tier": "claude_max"]
            ]
        ]

        XCTAssertEqual(UsageChecker.accountPlan(in: object), "claude_max")
    }

    func testFreeTierIsStillAnAccountLevel() {
        XCTAssertEqual(UsageChecker.accountPlan(in: ["plan_type": "free_tier"]), "free_tier")
    }

    func testInternalRateLimitTierIsNotPresentedAsAccountPlan() {
        XCTAssertNil(UsageChecker.accountPlan(in: ["rate_limit_tier": "default_ai"]))
    }
}

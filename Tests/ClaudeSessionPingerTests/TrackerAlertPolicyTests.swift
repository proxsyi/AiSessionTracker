import XCTest
import UserNotifications
@testable import TrackerDesignSystem

final class TrackerAlertPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let levels = [25, 50, 75, 90, 95, 100]

    func testEachCounterBaselinesAndCrossesEachSelectedThresholdOnlyOnce() {
        for _ in ["Claude session", "Claude weekly", "Codex rolling", "Codex weekly"] {
            var state = TrackerUsageAlertState()
            XCTAssertTrue(state.observe(percent: 40, reset: now, enabled: true, thresholds: levels).isEmpty)
            XCTAssertEqual(state.observe(percent: 76, reset: now, enabled: true, thresholds: levels), [.threshold(50), .threshold(75)])
            XCTAssertTrue(state.observe(percent: 76, reset: now, enabled: true, thresholds: levels).isEmpty)
        }
    }

    func testMissingDataAndFirstLateCounterNeverProduceAUsageWarning() {
        var state = TrackerUsageAlertState()
        XCTAssertTrue(state.observe(percent: nil, reset: nil, enabled: true, thresholds: levels).isEmpty)
        XCTAssertTrue(state.observe(percent: 95, reset: nil, enabled: true, thresholds: levels).isEmpty)
        XCTAssertTrue(state.observe(percent: nil, reset: nil, enabled: true, thresholds: levels).isEmpty)
        XCTAssertEqual(state.observe(percent: 100, reset: nil, enabled: true, thresholds: levels), [.threshold(100)])
    }

    func testPercentageFirstAppearingAfterRemainingCountBaselinesSilently() {
        var state = TrackerUsageAlertState()
        _ = state.observe(percent: nil, reset: nil, remaining: 1, enabled: true, thresholds: levels)
        XCTAssertTrue(state.observe(percent: 95, reset: nil, enabled: true, thresholds: levels).isEmpty)
    }

    func testDisabledThenReenabledAlertsDoNotReplayEarlierThresholds() {
        var state = TrackerUsageAlertState()
        _ = state.observe(percent: 20, reset: nil, enabled: true, thresholds: levels)
        XCTAssertTrue(state.observe(percent: 90, reset: nil, enabled: false, thresholds: levels).isEmpty)
        XCTAssertTrue(state.observe(percent: 90, reset: nil, enabled: true, thresholds: levels).isEmpty)
        XCTAssertEqual(state.observe(percent: 95, reset: nil, enabled: true, thresholds: levels), [.threshold(95)])
    }

    func testNewlySelectedPastThresholdDoesNotReplay() {
        var state = TrackerUsageAlertState()
        _ = state.observe(percent: 80, reset: nil, enabled: true, thresholds: [90])
        XCTAssertTrue(state.observe(percent: 80, reset: nil, enabled: true, thresholds: [25, 90]).isEmpty)
        XCTAssertEqual(state.observe(percent: 95, reset: nil, enabled: true, thresholds: [25, 90]), [.threshold(90)])
    }

    func testResetJitterAndWithinWindowDropsDoNotDuplicateAlerts() {
        var state = TrackerUsageAlertState()
        let reset = now.addingTimeInterval(1_000)
        _ = state.observe(percent: 60, reset: reset, enabled: true, thresholds: [75], now: now)
        XCTAssertEqual(state.observe(percent: 80, reset: reset, enabled: true, thresholds: [75], now: now), [.threshold(75)])
        _ = state.observe(percent: 20, reset: reset.addingTimeInterval(30), enabled: true, thresholds: [75], now: now)
        XCTAssertTrue(state.observe(percent: 80, reset: reset.addingTimeInterval(500), enabled: true, thresholds: [75], now: now).isEmpty)
    }

    func testNewWindowRearmsThresholds() {
        var state = TrackerUsageAlertState()
        _ = state.observe(percent: 80, reset: now, enabled: true, thresholds: [75], now: now.addingTimeInterval(-60))
        _ = state.observe(percent: 0, reset: now.addingTimeInterval(18_000), enabled: true, thresholds: [75], now: now.addingTimeInterval(1))
        XCTAssertEqual(state.observe(percent: 80, reset: now.addingTimeInterval(18_000), enabled: true, thresholds: [75], now: now.addingTimeInterval(60)), [.threshold(75)])
    }

    func testRemainingOnlyCounterReportsExhaustionOnceAndRecovers() {
        var state = TrackerUsageAlertState()
        _ = state.observe(percent: nil, reset: nil, remaining: 1, enabled: true, thresholds: levels)
        XCTAssertEqual(state.observe(percent: nil, reset: nil, remaining: 0, enabled: true, thresholds: levels), [.exhausted])
        XCTAssertTrue(state.observe(percent: nil, reset: nil, remaining: 0, enabled: true, thresholds: levels).isEmpty)
        _ = state.observe(percent: nil, reset: nil, remaining: 1, enabled: true, thresholds: levels)
        XCTAssertEqual(state.observe(percent: nil, reset: nil, blocked: true, enabled: true, thresholds: levels), [.exhausted])
    }

    func testRemainingOnlyCounterCanBeDisabledWithoutFakePercentages() {
        var state = TrackerUsageAlertState()
        _ = state.observe(percent: nil, reset: nil, remaining: 1, enabled: false, thresholds: levels)
        XCTAssertTrue(state.observe(percent: nil, reset: nil, remaining: 0, enabled: false, thresholds: levels).isEmpty)
        XCTAssertTrue(state.observe(percent: nil, reset: nil, remaining: 0, enabled: true, thresholds: levels).isEmpty)
    }

    func testSessionAvailabilityHandlesResetWithoutHittingOneHundredPercent() {
        var state = TrackerSessionAvailabilityState()
        XCTAssertFalse(state.observe(percent: 80, reset: now, now: now.addingTimeInterval(-1)))
        XCTAssertFalse(state.observe(percent: nil, reset: nil, now: now))
        XCTAssertTrue(state.observe(percent: 0, reset: nil, now: now.addingTimeInterval(1)))
        XCTAssertFalse(state.observe(percent: 0, reset: nil, now: now.addingTimeInterval(2)))
    }

    func testSessionAvailabilityAndRolloverAreIdenticalForBothPingers() {
        for _ in ["Claude", "Codex"] {
            var state = TrackerSessionAvailabilityState()
            XCTAssertFalse(state.observe(percent: 100, reset: now))
            XCTAssertTrue(state.observe(percent: 5, reset: now.addingTimeInterval(18_000)))
            XCTAssertFalse(state.observe(percent: 5, reset: now.addingTimeInterval(18_010)))
        }
    }

    func testServiceTransitionsRespectBothTogglesAndDontAnnounceUnseenRecovery() {
        var state = TrackerServiceAlertState()
        XCTAssertFalse(state.observe(.outage, outages: true, degraded: true))
        XCTAssertFalse(state.observe(.operational, outages: true, degraded: true))
        XCTAssertFalse(state.observe(.degraded, outages: true, degraded: false))
        XCTAssertTrue(state.observe(.outage, outages: true, degraded: false))
        XCTAssertFalse(state.observe(.outage, outages: true, degraded: false))
        XCTAssertTrue(state.observe(.operational, outages: true, degraded: false))
        XCTAssertFalse(state.observe(.outage, outages: false, degraded: false))
        XCTAssertFalse(state.observe(.operational, outages: false, degraded: false))
    }

    func testSuccessTogglesProduceOneTruthfulNotificationPerPing() {
        for ping in [false, true] {
            for scheduled in [false, true] {
                XCTAssertEqual(TrackerPingAlertPolicy.success(manual: true, pingSent: ping, scheduledPingSent: scheduled), ping ? .pingSent : nil)
                XCTAssertEqual(TrackerPingAlertPolicy.success(manual: false, pingSent: ping, scheduledPingSent: scheduled), scheduled ? .scheduledPingSent : (ping ? .pingSent : nil))
            }
        }
    }

    @MainActor
    func testProviderNotificationsCannotReplaceEachOtherAndAllRequestSound() {
        let requests = TrackerNotificationProvider.allCases.map {
            TrackerNotifications.request(provider: $0, event: "service-outage", title: "Test", body: "Test")
        }
        XCTAssertEqual(Set(requests.map(\.identifier)).count, 4)
        XCTAssertEqual(Set(requests.map { $0.content.threadIdentifier }).count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.content.sound != nil })
        XCTAssertTrue(TrackerNotifications.presentationOptions.contains(.banner))
        XCTAssertTrue(TrackerNotifications.presentationOptions.contains(.sound))
    }
}

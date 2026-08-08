import Foundation
import XCTest
@testable import ClaudeSessionPinger

final class ClaudeKeychainStoreTests: XCTestCase {
    func testWebSessionRecordRoundTripsBothCredentialParts() throws {
        let session = KeychainStore.WebSession(
            sessionKey: "claude-session",
            cookieHeader: "sessionKey=claude-session; other=value"
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(KeychainStore.WebSession.self, from: encoded)

        XCTAssertEqual(decoded, session)
    }
}

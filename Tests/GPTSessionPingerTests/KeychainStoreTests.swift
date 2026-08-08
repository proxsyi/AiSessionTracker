import Foundation
import XCTest
@testable import GPTUsageTracker

final class GPTKeychainStoreTests: XCTestCase {
    func testWebSessionRecordRoundTripsBothCredentialParts() throws {
        let session = KeychainStore.WebSession(
            sessionKey: "chatgpt-token",
            cookieHeader: "oai-did=device; session=chatgpt"
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(KeychainStore.WebSession.self, from: encoded)

        XCTAssertEqual(decoded, session)
    }
}

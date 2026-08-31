import Foundation

enum ChatGPTConversationIdentity {
    static func validate(expected: String?, observed: String?) throws -> String {
        guard let observed, !observed.isEmpty else {
            throw ChatGPTPingError.conversationChanged
        }
        if let expected, !expected.isEmpty, observed != expected {
            throw ChatGPTPingError.conversationChanged
        }
        return observed
    }

    static func validatePage(expected: String?, url: URL?) throws {
        guard let url, url.scheme == "https", url.host == "chatgpt.com" else {
            throw ChatGPTPingError.conversationChanged
        }
        let path = expected.flatMap { $0.isEmpty ? nil : "/c/\($0)" } ?? "/"
        guard url.path == path else { throw ChatGPTPingError.conversationChanged }
    }

    // Run in the same JavaScript turn as composer insertion or the send click,
    // so a redirect cannot pass a Swift-side check and then change the target.
    static let pageGuardScript = """
    const expectedPath = expectedConversationID ? '/c/' + expectedConversationID : '/';
    if (location.origin !== 'https://chatgpt.com' || location.pathname !== expectedPath) {
      return { wrongConversation: true };
    }
    """
}

/// Main-actor async methods are reentrant. One permit covers the entire browser
/// operation, including every suspension, so auth refreshes and both pingers
/// cannot navigate the shared renderer out from under another operation.
@MainActor
final class ChatGPTBrowserOperationGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiters.count }

    func acquire() async throws {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

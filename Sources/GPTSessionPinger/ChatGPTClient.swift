import Foundation

struct ChatGPTPingOutcome: Sendable {
    let conversationID: String
    let parentMessageID: String
    let replyText: String
}

enum ChatGPTPingError: Error, LocalizedError {
    case missingCredentials, sessionExpired, rateLimited, serverError(Int, String), emptyReply

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Sign in with ChatGPT before sending a ping."
        case .sessionExpired: return "Your ChatGPT session expired. Sign in again from Settings."
        case .rateLimited: return "ChatGPT rate-limited the ping. Try again later."
        case .serverError(let code, _): return "ChatGPT returned an error (HTTP \(code))."
        case .emptyReply: return "ChatGPT accepted the ping but returned no reply."
        }
    }
}

/// Sends a lightweight message through the signed-in ChatGPT web session and
/// persists the conversation/parent pair so every ping stays in one chat.
enum ChatGPTClient {
    static func sendPing(
        auth: ChatGPTAuthSession,
        cookieHeader: String,
        model: String,
        reasoningEffort: String,
        message: String,
        conversationID: String?,
        parentMessageID: String?,
        timeout: TimeInterval = 60
    ) async throws -> ChatGPTPingOutcome {
        guard !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatGPTPingError.missingCredentials }
        let conversation = conversationID?.nilIfEmpty
        _ = auth
        _ = parentMessageID
        let browserResponse = try await ChatGPTBrowserTransport.shared.send(
            message: message,
            conversationID: conversation,
            model: model,
            reasoningEffort: reasoningEffort,
            cookieHeader: cookieHeader,
            timeout: timeout
        )
        let statusCode = browserResponse.statusCode
        let data = browserResponse.body
        guard (200...299).contains(statusCode) else {
            if [401, 403].contains(statusCode) {
                let bodyPrefix = String(data: data.prefix(240), encoding: .utf8) ?? ""
                throw ChatGPTPingError.serverError(
                    statusCode,
                    "browserType=\(browserResponse.contentType) bodyPrefix=\(bodyPrefix)"
                )
            }
            if statusCode == 429 { throw ChatGPTPingError.rateLimited }
            if statusCode == 504 { throw ChatGPTPingError.emptyReply }
            throw ChatGPTPingError.serverError(statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let browserConversationID = browserResponse.conversationID,
              let browserReply = browserResponse.replyText,
              !browserReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTPingError.emptyReply
        }
        return ChatGPTPingOutcome(
            conversationID: browserConversationID,
            parentMessageID: UUID().uuidString.lowercased(),
            replyText: browserReply
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

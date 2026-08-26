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
        let parent = parentMessageID?.nilIfEmpty ?? UUID().uuidString.lowercased()
        let body: [String: Any] = [
            "action": "next",
            "messages": [[
                "id": UUID().uuidString.lowercased(),
                "author": ["role": "user"],
                "content": ["content_type": "text", "parts": [message]],
                "metadata": [:]
            ]],
            "model": model,
            "parent_message_id": parent,
            "conversation_id": conversation ?? NSNull(),
            "history_and_training_disabled": true,
            "timezone_offset_min": TimeZone.current.secondsFromGMT() / -60,
            "suggestions": [],
            "temporary": true,
            "reasoning_effort": reasoningEffort
        ]
        guard let requestBase = ChatGPTWebSession.makeBackendRequest(
            path: "/conversation", method: "POST", auth: auth,
            cookieHeader: cookieHeader, accept: "text/event-stream", body: try JSONSerialization.data(withJSONObject: body)
        ) else { throw ChatGPTPingError.serverError(0, "Invalid ChatGPT URL") }
        var request = requestBase
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTPingError.serverError(0, "No HTTP response") }
        guard (200...299).contains(http.statusCode) else {
            if [401, 403].contains(http.statusCode) { throw ChatGPTPingError.sessionExpired }
            if http.statusCode == 429 { throw ChatGPTPingError.rateLimited }
            throw ChatGPTPingError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let parsed = parseStream(data)
        guard !parsed.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatGPTPingError.emptyReply }
        return ChatGPTPingOutcome(conversationID: parsed.conversationID ?? conversation ?? UUID().uuidString.lowercased(), parentMessageID: parsed.messageID ?? parent, replyText: parsed.reply)
    }

    private static func parseStream(_ data: Data) -> (reply: String, conversationID: String?, messageID: String?) {
        guard let text = String(data: data, encoding: .utf8) else { return ("", nil, nil) }
        var reply = "", conversationID: String?, messageID: String?
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let json = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            conversationID = (object["conversation_id"] as? String) ?? conversationID
            if let message = object["message"] as? [String: Any] {
                messageID = (message["id"] as? String) ?? messageID
                if let content = message["content"] as? [String: Any], let parts = content["parts"] as? [String], let last = parts.last { reply = last }
            }
        }
        return (reply, conversationID, messageID)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

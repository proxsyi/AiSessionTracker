import Foundation

/// Consumer-web client for the dedicated ChatGPT conversation. The web
/// contract is undocumented, so this layer is deliberately self-contained
/// and accepts the complete cookie header captured by the embedded browser.
enum GPTClient {
    static func sendPing(
        sessionKey: String,
        organizationID: String,
        model: String,
        message: String,
        conversationID: String? = nil,
        cookieHeader: String? = nil,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> PingOutcome {
        _ = sessionKey
        _ = organizationID
        let cookies = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookies.isEmpty, !selectedModel.isEmpty else { throw PingError.missingCredentials }
        guard let url = URL(string: "https://chatgpt.com/backend-api/conversation") else { throw PingError.invalidURL }

        let messageID = UUID().uuidString.lowercased()
        let parentMessageID = UUID().uuidString.lowercased()
        let trimmedConversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var payload: [String: Any] = [
            "action": "next",
            "messages": [[
                "id": messageID,
                "author": ["role": "user"],
                "content": ["content_type": "text", "parts": [message]],
                "metadata": [:]
            ]],
            "parent_message_id": parentMessageID,
            "model": selectedModel,
            "timezone_offset_min": TimeZone.current.secondsFromGMT() / 60,
            "history_and_training_disabled": false
        ]
        if !trimmedConversationID.isEmpty { payload["conversation_id"] = trimmedConversationID }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw PingError.network(error) }
        catch { throw PingError.unknown(error) }
        try validate(response: response, data: data)

        let parsed = parseCompletionStream(data)
        let resultingConversationID = parsed.conversationID.isEmpty ? trimmedConversationID : parsed.conversationID
        return PingOutcome(conversationID: resultingConversationID, replyText: parsed.reply, matchedExpected: !parsed.reply.isEmpty)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw PingError.unexpectedResponse("No HTTP response received") }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw PingError.sessionExpired
        case 429: throw PingError.rateLimited
        default: throw PingError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func parseCompletionStream(_ data: Data) -> (conversationID: String, reply: String) {
        guard let text = String(data: data, encoding: .utf8) else { return ("", "") }
        var conversationID = ""
        var reply = ""
        for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard json != "[DONE]", let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let id = object["conversation_id"] as? String { conversationID = id }
            guard let message = object["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any], author["role"] as? String == "assistant",
                  let content = message["content"] as? [String: Any], let parts = content["parts"] as? [Any] else { continue }
            let textParts = parts.compactMap { $0 as? String }
            if !textParts.isEmpty { reply = textParts.joined(separator: "\n") }
        }
        return (conversationID, reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

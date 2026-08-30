import Foundation

enum ClaudeClient {
    static func sendPing(
        sessionKey: String,
        organizationID: String,
        model: String,
        message: String,
        conversationID: String? = nil,
        cookieHeader: String? = nil,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> PingOutcome {
        let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrg = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedOrg.isEmpty, !trimmedModel.isEmpty else {
            throw PingError.missingCredentials
        }
        guard let baseURL = URL(string: "https://claude.ai/api/organizations/\(trimmedOrg)") else {
            throw PingError.invalidURL
        }

        let storedConversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedConversationID.isEmpty {
            do {
                return try await sendCompletion(
                    conversationID: storedConversationID,
                    baseURL: baseURL,
                    sessionKey: trimmedKey,
                    model: trimmedModel,
                    message: message,
                    cookieHeader: cookieHeader,
                    timeoutSeconds: timeoutSeconds
                )
            } catch let error as PingError {
                if shouldReplaceConversation(after: error) {
                    // The dedicated chat was deleted or expired. Replace it
                    // once and continue instead of failing the scheduled ping.
                } else {
                    throw error
                }
            }
        }

        let newConversationID = try await createConversation(
            baseURL: baseURL,
            sessionKey: trimmedKey,
            cookieHeader: cookieHeader,
            timeoutSeconds: timeoutSeconds
        )
        return try await sendCompletion(
            conversationID: newConversationID,
            baseURL: baseURL,
            sessionKey: trimmedKey,
            model: trimmedModel,
            message: message,
            cookieHeader: cookieHeader,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func shouldReplaceConversation(after error: PingError) -> Bool {
        guard case .serverError(let code, let body) = error else { return false }
        if code == 404 { return true }
        guard code == 400 else { return false }
        let message = body.lowercased()
        return message.contains("conversation") && (
            message.contains("has been ended")
                || message.contains("was deleted")
                || message.contains("has expired")
        )
    }

    private static func createConversation(
        baseURL: URL,
        sessionKey: String,
        cookieHeader: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let conversationID = UUID().uuidString.lowercased()
        let createURL = baseURL.appendingPathComponent("chat_conversations")
        var createRequest = URLRequest(url: createURL)
        createRequest.httpMethod = "POST"
        createRequest.timeoutInterval = timeoutSeconds
        applyCommonHeaders(&createRequest, sessionKey: sessionKey, cookieHeader: cookieHeader)
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: ["uuid": conversationID, "name": "Session Pinger"])

        let (createData, createResponse) = try await perform(createRequest)
        try validate(response: createResponse, data: createData)
        return conversationID
    }

    private static func sendCompletion(
        conversationID: String,
        baseURL: URL,
        sessionKey: String,
        model: String,
        message: String,
        cookieHeader: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> PingOutcome {
        let completionURL = baseURL
            .appendingPathComponent("chat_conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("completion")
        var completionRequest = URLRequest(url: completionURL)
        completionRequest.httpMethod = "POST"
        completionRequest.timeoutInterval = timeoutSeconds
        applyCommonHeaders(&completionRequest, sessionKey: sessionKey, cookieHeader: cookieHeader)
        let payload: [String: Any] = [
            "prompt": message,
            "timezone": TimeZone.current.identifier,
            "attachments": [],
            "files": [],
            "rendering_mode": "messages",
            "model": model
        ]
        completionRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (completionData, completionResponse) = try await perform(completionRequest)
        try validate(response: completionResponse, data: completionData)

        let replyText = parseCompletionStream(completionData).trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = !replyText.isEmpty
        return PingOutcome(conversationID: conversationID, replyText: replyText, matchedExpected: matched)
    }

    private static func applyCommonHeaders(_ request: inout URLRequest, sessionKey: String, cookieHeader: String? = nil) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/new", forHTTPHeaderField: "Referer")
        // Send the full captured login cookies when available so requests
        // look exactly like the browser session; fall back to the bare key.
        let cookies = (cookieHeader?.isEmpty == false) ? cookieHeader! : "sessionKey=\(sessionKey)"
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw PingError.network(error)
        } catch let error as PingError {
            throw error
        } catch {
            throw PingError.unknown(error)
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PingError.unexpectedResponse("No HTTP response received")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw PingError.sessionExpired
        case 429:
            throw PingError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PingError.serverError(http.statusCode, body)
        }
    }

    private static func parseCompletionStream(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var combined = ""
        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let jsonPart = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !jsonPart.isEmpty, let jsonData = jsonPart.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
            if let completion = object["completion"] as? String {
                combined += completion
            } else if let delta = object["delta"] as? [String: Any], let deltaText = delta["text"] as? String {
                combined += deltaText
            }
        }
        return combined
    }
}

import CryptoKit
import Foundation

/// Consumer-web client for one dedicated ChatGPT conversation. ChatGPT's
/// browser backend requires both the signed-in cookies and the short-lived
/// bearer/sentinel tokens that its own web client uses for each turn.
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
        let cookies = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookies.isEmpty, !selectedModel.isEmpty else { throw PingError.missingCredentials }

        let auth = try await ChatGPTWebSession.resolve(
            savedCredential: sessionKey,
            accountID: organizationID,
            cookieHeader: cookies
        )
        let storedConversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let conversation = try await resolveConversation(
            storedConversationID,
            auth: auth,
            cookies: cookies
        )
        let parentMessageID = conversation.parentMessageID ?? UUID().uuidString.lowercased()
        let requirements: Requirements
        do {
            requirements = try await fetchRequirements(auth: auth, cookies: cookies)
        } catch PingError.browserVerificationRequired {
            return try await ChatGPTBrowserMessenger.shared.send(
                message: message,
                model: selectedModel,
                conversationID: conversation.id,
                previousNodeID: conversation.parentMessageID,
                auth: auth,
                cookieHeader: cookies,
                timeoutSeconds: max(timeoutSeconds, 45)
            )
        }

        let messageID = UUID().uuidString.lowercased()
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
            "conversation_mode": ["kind": "primary_assistant"],
            "force_paragen": false,
            "force_rate_limit": false,
            "suggestions": [],
            "timezone_offset_min": TimeZone.current.secondsFromGMT() / -60,
            "history_and_training_disabled": false
        ]
        if let existingID = conversation.id { payload["conversation_id"] = existingID }

        let body = try JSONSerialization.data(withJSONObject: payload)
        guard var request = ChatGPTWebSession.makeBackendRequest(
            path: "/conversation",
            method: "POST",
            auth: auth,
            cookieHeader: cookies,
            accept: "text/event-stream",
            body: body
        ) else { throw PingError.invalidURL }
        request.timeoutInterval = timeoutSeconds
        request.setValue(requirements.token, forHTTPHeaderField: "Openai-Sentinel-Chat-Requirements-Token")
        if let proofToken = requirements.proofToken {
            request.setValue(proofToken, forHTTPHeaderField: "Openai-Sentinel-Proof-Token")
        }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw PingError.network(error) }
        catch { throw PingError.unknown(error) }
        try validate(response: response, data: data)

        let streamed = parseCompletionResponse(data)
        let resultingConversationID = streamed.conversationID.isEmpty
            ? (conversation.id ?? "")
            : streamed.conversationID
        guard !resultingConversationID.isEmpty else {
            throw PingError.unexpectedResponse("ChatGPT accepted the turn but did not return a conversation ID.")
        }

        var reply = streamed.reply
        if reply.isEmpty {
            reply = try await waitForAssistantReply(
                conversationID: resultingConversationID,
                previousNodeID: conversation.parentMessageID,
                auth: auth,
                cookies: cookies
            )
        }
        return PingOutcome(
            conversationID: resultingConversationID,
            replyText: reply,
            matchedExpected: !reply.isEmpty
        )
    }

    private struct ResolvedConversation {
        let id: String?
        let parentMessageID: String?
    }

    private struct Requirements {
        let token: String
        let proofToken: String?
    }

    /// Loads ChatGPT's current node before continuing a saved conversation.
    /// If the user deleted that chat, the next ping starts one replacement.
    private static func resolveConversation(
        _ conversationID: String,
        auth: ChatGPTAuthSession,
        cookies: String
    ) async throws -> ResolvedConversation {
        guard !conversationID.isEmpty else { return ResolvedConversation(id: nil, parentMessageID: nil) }
        guard let request = ChatGPTWebSession.makeBackendRequest(
            path: "/conversation/\(conversationID)",
            auth: auth,
            cookieHeader: cookies
        ) else { throw PingError.invalidURL }

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw PingError.unexpectedResponse("No HTTP response while loading the saved chat.")
        }
        if http.statusCode == 404 { return ResolvedConversation(id: nil, parentMessageID: nil) }
        try validate(response: response, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PingError.unexpectedResponse("The saved ChatGPT conversation could not be read.")
        }
        return ResolvedConversation(
            id: conversationID,
            parentMessageID: object["current_node"] as? String
        )
    }

    private static func fetchRequirements(
        auth: ChatGPTAuthSession,
        cookies: String
    ) async throws -> Requirements {
        guard let request = ChatGPTWebSession.makeBackendRequest(
            path: "/sentinel/chat-requirements",
            method: "POST",
            auth: auth,
            cookieHeader: cookies
        ) else { throw PingError.invalidURL }

        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String,
              !token.isEmpty else {
            throw PingError.unexpectedResponse("ChatGPT did not issue a chat requirements token.")
        }

        for challengeName in ["arkose", "turnstile"] {
            if let challenge = object[challengeName] as? [String: Any], challenge["required"] as? Bool == true {
                throw PingError.browserVerificationRequired
            }
        }

        var proofToken: String?
        if let proof = object["proofofwork"] as? [String: Any],
           proof["required"] as? Bool == true,
           let seed = proof["seed"] as? String,
           let difficulty = proof["difficulty"] as? String {
            proofToken = generateProofToken(seed: seed, difficulty: difficulty)
            if proofToken == nil {
                throw PingError.unexpectedResponse("ChatGPT's browser proof-of-work challenge could not be completed.")
            }
        }
        return Requirements(token: token, proofToken: proofToken)
    }

    private static func generateProofToken(seed: String, difficulty: String) -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        return generateSHA3ProofToken(seed: seed, difficulty: difficulty)
    }

    @available(macOS 26.0, *)
    private static func generateSHA3ProofToken(seed: String, difficulty: String) -> String? {
        let parseTime = Date().description
        var fingerprint: [Any] = [
            4012,
            parseTime,
            4_294_705_152,
            0,
            ChatGPTWebSession.userAgent,
            "https://tcr9i.chat.openai.com/v2/35536E1E-65B4-4D96-9D97-6ADB7EFF8147/api.js",
            "dpl=1440a687921de39ff5ee56b92807faaadce73f13",
            "en",
            "en-US",
            4_294_705_152,
            "plugins−[object PluginArray]",
            "_reactListening9ne2dfo1i47",
            "onprogress"
        ]
        let normalizedDifficulty = difficulty.lowercased()
        for nonce in 0..<500_000 {
            fingerprint[3] = nonce
            guard let json = try? JSONSerialization.data(withJSONObject: fingerprint),
                  let jsonText = String(data: json, encoding: .utf8) else { return nil }
            let base64 = Data(jsonText.utf8).base64EncodedString()
            let digest = SHA3_512.hash(data: Data((seed + base64).utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            if String(hex.prefix(normalizedDifficulty.count)) <= normalizedDifficulty {
                return "gAAAAAB" + base64
            }
        }
        return nil
    }

    private static func waitForAssistantReply(
        conversationID: String,
        previousNodeID: String?,
        auth: ChatGPTAuthSession,
        cookies: String
    ) async throws -> String {
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let request = ChatGPTWebSession.makeBackendRequest(
                path: "/conversation/\(conversationID)",
                auth: auth,
                cookieHeader: cookies
            ) else { throw PingError.invalidURL }
            let (data, response) = try await perform(request)
            try validate(response: response, data: data)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let turn = ChatGPTConversationParser.newestAssistantTurn(
                in: object,
                stoppingAt: previousNodeID
            ), turn.isComplete {
                return turn.text
            }
        }
        return ""
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw PingError.network(error) }
        catch { throw PingError.unknown(error) }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw PingError.unexpectedResponse("No HTTP response received") }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200...299: return
        case 401: throw PingError.sessionExpired
        case 403: throw PingError.serverError(http.statusCode, body.isEmpty ? "ChatGPT rejected the browser session or verification token." : body)
        case 429: throw PingError.rateLimited
        default: throw PingError.serverError(http.statusCode, body)
        }
    }

    private static func parseCompletionResponse(_ data: Data) -> (conversationID: String, reply: String) {
        guard let text = String(data: data, encoding: .utf8) else { return ("", "") }
        var conversationID = ""
        var reply = ""
        var jsonRecords: [[String: Any]] = []

        for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard json != "[DONE]", let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            jsonRecords.append(object)
        }
        if jsonRecords.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            jsonRecords.append(object)
        }

        for object in jsonRecords {
            if let id = object["conversation_id"] as? String { conversationID = id }
            guard let message = object["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  author["role"] as? String == "assistant",
                  let content = message["content"] as? [String: Any],
                  let parts = content["parts"] as? [Any] else { continue }
            let textParts = parts.compactMap { $0 as? String }
            if !textParts.isEmpty { reply = textParts.joined(separator: "\n") }
        }
        return (conversationID, reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

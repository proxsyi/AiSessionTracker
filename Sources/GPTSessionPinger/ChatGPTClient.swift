import Foundation

struct ChatGPTPingOutcome: Sendable {
    let conversationID: String
    let parentMessageID: String
    let replyText: String?
    let confirmedModel: String?
    let confirmedReasoningEffort: String?
}

struct ChatGPTResponseMetadata: Equatable, Sendable {
    let model: String?
    let reasoningEffort: String?
}

struct ChatGPTConversationSnapshot: Equatable, Sendable {
    let replyText: String?
    let metadata: ChatGPTResponseMetadata?
}

enum ChatGPTPingError: Error, LocalizedError {
    case missingCredentials, sessionExpired, rateLimited, serverError(Int, String), emptyReply
    case modelSelectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Sign in with ChatGPT before sending a ping."
        case .sessionExpired: return "Your ChatGPT session expired. Sign in again from Settings."
        case .rateLimited: return "ChatGPT rate-limited the ping. Try again later."
        case .serverError(let code, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "ChatGPT returned an error (HTTP \(code))."
                : "ChatGPT returned an error (HTTP \(code)): \(trimmed)"
        case .emptyReply: return "ChatGPT accepted the ping but returned no reply."
        case .modelSelectionFailed(let title): return "ChatGPT did not select \(title). Refresh the model list and try again."
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
        modelTitle: String,
        mode: ChatGPTComposerMode,
        reasoningEffort: String,
        message: String,
        conversationID: String?,
        parentMessageID: String?,
        timeout: TimeInterval = 120
    ) async throws -> ChatGPTPingOutcome {
        guard !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatGPTPingError.missingCredentials }
        let conversation = conversationID?.nilIfEmpty
        _ = auth
        _ = parentMessageID
        let browserResponse = try await ChatGPTBrowserTransport.shared.send(
            message: message,
            conversationID: conversation,
            model: model,
            modelTitle: modelTitle,
            mode: mode,
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
            throw ChatGPTPingError.serverError(statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let browserConversationID = browserResponse.conversationID else {
            throw ChatGPTPingError.emptyReply
        }
        let snapshot = await waitForConversationSnapshot(
            conversationID: browserConversationID,
            auth: auth,
            cookieHeader: cookieHeader,
            requireReply: false
        )
        return ChatGPTPingOutcome(
            conversationID: browserConversationID,
            parentMessageID: UUID().uuidString.lowercased(),
            replyText: browserResponse.replyText?.nilIfEmpty ?? snapshot?.replyText?.nilIfEmpty,
            confirmedModel: snapshot?.metadata?.model,
            confirmedReasoningEffort: snapshot?.metadata?.reasoningEffort
        )
    }

    static func parseResponseMetadata(_ object: [String: Any]) -> ChatGPTResponseMetadata? {
        parseConversationSnapshot(object)?.metadata
    }

    static func parseConversationSnapshot(_ object: [String: Any]) -> ChatGPTConversationSnapshot? {
        var candidates: [(createdAt: Double, snapshot: ChatGPTConversationSnapshot)] = []
        collectAssistantSnapshots(in: object, into: &candidates)
        return candidates.max(by: { $0.createdAt < $1.createdAt })?.snapshot
    }

    private static func waitForConversationSnapshot(
        conversationID: String,
        auth: ChatGPTAuthSession,
        cookieHeader: String,
        requireReply: Bool
    ) async -> ChatGPTConversationSnapshot? {
        let deadline = Date().addingTimeInterval(requireReply ? 15 : 3)
        repeat {
            if let snapshot = await conversationSnapshot(
                conversationID: conversationID,
                auth: auth,
                cookieHeader: cookieHeader
            ), !requireReply || snapshot.replyText?.nilIfEmpty != nil {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        return nil
    }

    private static func conversationSnapshot(
        conversationID: String,
        auth: ChatGPTAuthSession,
        cookieHeader: String
    ) async -> ChatGPTConversationSnapshot? {
        guard let request = ChatGPTWebSession.makeBackendRequest(
            path: "/conversation/\(conversationID)",
            auth: auth,
            cookieHeader: cookieHeader
        ), let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse,
           (200...299).contains(http.statusCode),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseConversationSnapshot(object)
    }

    private static func collectAssistantSnapshots(
        in value: Any,
        into candidates: inout [(createdAt: Double, snapshot: ChatGPTConversationSnapshot)]
    ) {
        if let dictionary = value as? [String: Any] {
            if let message = dictionary["message"] as? [String: Any],
               let author = message["author"] as? [String: Any],
               author["role"] as? String == "assistant" {
                let metadataDictionary = message["metadata"] as? [String: Any] ?? [:]
                let model = firstString(in: metadataDictionary, keys: ["model_slug", "model", "default_model_slug"])
                let effort = firstString(in: metadataDictionary, keys: ["reasoning_effort", "thinking_effort"])
                let metadata = model == nil && effort == nil
                    ? nil
                    : ChatGPTResponseMetadata(model: model, reasoningEffort: effort)
                let replyText = assistantText(from: message)
                if replyText != nil || metadata != nil {
                    let createdAt = (message["create_time"] as? NSNumber)?.doubleValue ?? 0
                    candidates.append((createdAt, ChatGPTConversationSnapshot(replyText: replyText, metadata: metadata)))
                }
            }
            for child in dictionary.values { collectAssistantSnapshots(in: child, into: &candidates) }
        } else if let array = value as? [Any] {
            for child in array { collectAssistantSnapshots(in: child, into: &candidates) }
        }
    }

    private static func assistantText(from message: [String: Any]) -> String? {
        guard let content = message["content"] as? [String: Any] else { return nil }
        var values: [String] = []
        if let text = content["text"] as? String { values.append(text) }
        if let parts = content["parts"] as? [Any] {
            for part in parts {
                if let text = part as? String {
                    values.append(text)
                } else if let object = part as? [String: Any],
                          let text = firstString(in: object, keys: ["text", "content"]) {
                    values.append(text)
                }
            }
        }
        let joined = values.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

import Foundation

struct ChatGPTThinkingEffort: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

struct ChatGPTModelOption: Equatable, Identifiable, Sendable {
    let slug: String
    let title: String
    let reasoningType: String
    let thinkingEfforts: [ChatGPTThinkingEffort]
    let isWorkMode: Bool

    var id: String { slug }
    var usesReasoning: Bool { reasoningType != "none" }

    var selectableEfforts: [ChatGPTThinkingEffort] {
        if !usesReasoning {
            return [ChatGPTThinkingEffort(id: "none", title: "None")]
        }
        if !thinkingEfforts.isEmpty { return thinkingEfforts }
        return [ChatGPTThinkingEffort(id: "default", title: "Model default")]
    }
}

enum ChatGPTModelCatalog {
    static let lowestUsageModelSlug = "gpt-5-3-mini"
    static let lowestUsageModelTitle = "GPT-5.3 Mini"
    static let lowestUsageWorkModelSlug = "gpt-5.6-sol-wm"
    static let lowestUsageWorkModelTitle = "GPT-5.6 Sol"

    static func fetch(
        auth: ChatGPTAuthSession,
        cookieHeader: String
    ) async throws -> [ChatGPTModelOption] {
        guard let request = ChatGPTWebSession.makeBackendRequest(
            path: "/models?history_and_training_disabled=false",
            auth: auth,
            cookieHeader: cookieHeader
        ) else {
            throw ChatGPTPingError.serverError(0, "Invalid ChatGPT model catalog URL")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTPingError.serverError(0, "ChatGPT model catalog returned no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            if [401, 403].contains(http.statusCode) { throw ChatGPTPingError.sessionExpired }
            throw ChatGPTPingError.serverError(http.statusCode, "ChatGPT model catalog unavailable")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTPingError.serverError(http.statusCode, "ChatGPT model catalog was invalid")
        }
        return parse(object)
    }

    static func parse(_ object: [String: Any]) -> [ChatGPTModelOption] {
        guard let models = object["models"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return models.compactMap { model in
            guard let rawSlug = (model["slug"] as? String) ?? (model["id"] as? String) else { return nil }
            let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty,
                  slug != "research",
                  seen.insert(slug).inserted else { return nil }
            let title = ((model["title"] as? String) ?? (model["display_name"] as? String) ?? slug)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoningType = ((model["reasoning_type"] as? String) ?? "none").lowercased()
            var efforts = ((model["thinking_efforts"] as? [[String: Any]]) ?? []).compactMap { effort -> ChatGPTThinkingEffort? in
                guard let rawID = effort["thinking_effort"] as? String else { return nil }
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return nil }
                let label = ((effort["short_label"] as? String) ?? (effort["full_label"] as? String) ?? id.capitalized)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatGPTThinkingEffort(id: id, title: label)
            }
            let isWorkMode = model["is_work_mode_model"] as? Bool == true
            if isWorkMode, !efforts.contains(where: { $0.id == "min" }) {
                efforts.insert(ChatGPTThinkingEffort(id: "min", title: "Light"), at: 0)
            }
            return ChatGPTModelOption(
                slug: slug,
                title: title,
                reasoningType: reasoningType,
                thinkingEfforts: efforts,
                isWorkMode: isWorkMode
            )
        }
    }

    static func fallbackTitle(for slug: String) -> String {
        if slug == lowestUsageModelSlug { return lowestUsageModelTitle }
        if slug == lowestUsageWorkModelSlug { return lowestUsageWorkModelTitle }
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    static func normalizedSelection(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}

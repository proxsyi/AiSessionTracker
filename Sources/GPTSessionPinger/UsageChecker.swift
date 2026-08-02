import Foundation

enum GPTUsageScope: String, Equatable {
    case chatGPTModel
    case chatGPTFeature
    case codex
    case workspace
}

struct GPTUsageTrack: Identifiable, Equatable {
    var id: String
    var scope: GPTUsageScope
    var title: String
    var usedPercent: Int?
    var remaining: Int?
    var limit: Int?
    var resetsAt: Date?
    var windowSeconds: Int?
    var isBlocked: Bool
    var modelSlug: String?
    var valueText: String? = nil

    var remainingText: String? {
        if let remaining, let limit { return "\(remaining) of \(limit) remaining" }
        if let remaining { return "\(remaining) remaining" }
        return nil
    }

    /// Stable Settings/alert identity. Server payload ordering and the
    /// primary/secondary label may change, while the actual usage scope does
    /// not. Keeping this stable prevents visibility toggles from resetting.
    var preferenceID: String {
        if id.hasPrefix("codex-") {
            if windowSeconds == 604_800 { return "codex-weekly" }
            if windowSeconds == 18_000 { return "codex-rolling-5h" }
            if let windowSeconds { return "codex-window-\(windowSeconds)" }
        }
        if id.hasPrefix("code-review-") {
            if windowSeconds == 604_800 { return "code-review-weekly" }
            if windowSeconds == 18_000 { return "code-review-rolling-5h" }
            if let windowSeconds { return "code-review-window-\(windowSeconds)" }
            return "code-review"
        }
        if id.hasPrefix("model-") { return id }
        return id
    }

    var isCodexTrack: Bool {
        scope == .codex || scope == .workspace
    }
}

struct GPTUsage: Equatable {
    var tracks: [GPTUsageTrack]
    var blockedFeatures: [String]
    var planType: String?
    var fetchedAt: Date

    var rollingFiveHourTrack: GPTUsageTrack? {
        tracks.first { $0.id.hasPrefix("codex-") && $0.windowSeconds == 18_000 }
    }
    var weeklyTrack: GPTUsageTrack? {
        tracks.first { $0.id.hasPrefix("codex-") && $0.windowSeconds == 604_800 }
    }
    var rollingFiveHourPercent: Int? { rollingFiveHourTrack?.usedPercent }
    var rollingFiveHourResetsAt: Date? { rollingFiveHourTrack?.resetsAt }
    var weeklyPercent: Int? { weeklyTrack?.usedPercent }
    var weeklyResetsAt: Date? { weeklyTrack?.resetsAt }

}

struct GPTServiceStatus: Equatable {
    enum Level: Equatable { case operational, degraded, outage }
    var level: Level
    var message: String
    var checkedAt: Date
    var operational: Bool { level == .operational }
}

enum UsageError: Error, LocalizedError {
    case missingCredentials, sessionExpired, network(URLError), serverError(Int), unexpectedResponse
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Sign in with ChatGPT in Settings to see account details."
        case .sessionExpired: return "Your ChatGPT session expired. Sign in again from Settings."
        case .network(let error): return "Network error while checking ChatGPT: \(error.localizedDescription)"
        case .serverError(let code): return "ChatGPT returned an error (HTTP \(code))."
        case .unexpectedResponse: return "ChatGPT did not report usage data for this account."
        }
    }
}

/// Reads only account data returned by ChatGPT's consumer web session. Usage
/// limits vary by plan and model; absent fields remain unavailable rather than
/// being inferred from message history.
enum UsageChecker {
    static func fetchUsage(sessionKey: String, organizationID: String, cookieHeader: String? = nil) async throws -> GPTUsage {
        guard let cookies = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !cookies.isEmpty else {
            throw UsageError.missingCredentials
        }
        let auth: ChatGPTAuthSession
        do {
            auth = try await ChatGPTWebSession.resolve(
                savedCredential: sessionKey,
                accountID: organizationID,
                cookieHeader: cookies
            )
        } catch {
            throw UsageError.sessionExpired
        }
        var tracks: [GPTUsageTrack] = []
        var blockedFeatures: [String] = []
        var planType = auth.planType
        var successfulSourceCount = 0
        var sawSessionFailure = false

        if let request = ChatGPTWebSession.makeBackendRequest(
            path: "/wham/usage",
            auth: auth,
            cookieHeader: cookies
        ), let (data, response) = try? await perform(request),
           let http = response as? HTTPURLResponse {
            if (200...299).contains(http.statusCode),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                successfulSourceCount += 1
                tracks.append(contentsOf: parseAgenticTracks(object))
                planType = (object["plan_type"] as? String) ?? planType
            } else if [401, 403].contains(http.statusCode) {
                sawSessionFailure = true
            }
        }

        let initBody = try JSONSerialization.data(withJSONObject: [
            "gizmo_id": NSNull(),
            "requested_default_model": NSNull(),
            "conversation_id": NSNull(),
            "timezone_offset_min": TimeZone.current.secondsFromGMT() / -60,
            "system_hints": []
        ])
        if let request = ChatGPTWebSession.makeBackendRequest(
            path: "/conversation/init",
            method: "POST",
            auth: auth,
            cookieHeader: cookies,
            body: initBody
        ), let (data, response) = try? await perform(request),
           let http = response as? HTTPURLResponse {
            if (200...299).contains(http.statusCode),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                successfulSourceCount += 1
                tracks.append(contentsOf: parseChatGPTTracks(object))
                blockedFeatures = stringArray(object["blocked_features"])
            } else if [401, 403].contains(http.statusCode) {
                sawSessionFailure = true
            }
        }

        guard successfulSourceCount > 0 else {
            if sawSessionFailure { throw UsageError.sessionExpired }
            throw UsageError.unexpectedResponse
        }
        return GPTUsage(
            tracks: deduplicated(tracks),
            blockedFeatures: blockedFeatures,
            planType: planType,
            fetchedAt: Date()
        )
    }

    static func fetchServiceStatus() async -> GPTServiceStatus? {
        guard let url = URL(string: "https://status.openai.com/api/v2/status.json") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? [String: Any], let indicator = status["indicator"] as? String else { return nil }
        let level: GPTServiceStatus.Level
        switch indicator.lowercased() { case "none": level = .operational; case "minor": level = .degraded; default: level = .outage }
        let description = status["description"] as? String
        let message: String
        switch level {
        case .operational: message = "All OpenAI services operational"
        case .degraded: message = description ?? "OpenAI is reporting degraded performance"
        case .outage: message = description ?? "OpenAI is reporting a service outage"
        }
        return GPTServiceStatus(level: level, message: message, checkedAt: Date())
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw UsageError.network(error) }
        catch { throw UsageError.unexpectedResponse }
    }

    static func parseAgenticTracks(_ object: [String: Any]) -> [GPTUsageTrack] {
        var tracks: [GPTUsageTrack] = []
        if let rateLimit = object["rate_limit"] as? [String: Any] {
            tracks.append(contentsOf: parseRateLimitGroup(rateLimit, idPrefix: "codex", titlePrefix: "Codex / agentic"))
        }
        if let rateLimit = object["code_review_rate_limit"] as? [String: Any] {
            tracks.append(contentsOf: parseRateLimitGroup(rateLimit, idPrefix: "code-review", titlePrefix: "Code review"))
        }
        if let credits = object["credits"] as? [String: Any] {
            let unlimited = credits["unlimited"] as? Bool == true
            let balance = string(credits["balance"]) ?? numeric(credits["balance"]).map { String(format: "%.2f", $0) }
            tracks.append(GPTUsageTrack(
                id: "codex-credits",
                scope: .codex,
                title: "Purchased credits",
                usedPercent: nil,
                remaining: nil,
                limit: nil,
                resetsAt: nil,
                windowSeconds: nil,
                // A zero add-on balance does not block included plan usage.
                // Present it as an exact balance, not an account failure.
                isBlocked: false,
                modelSlug: nil,
                valueText: unlimited ? "Unlimited" : balance.map { "\($0) credits" }
            ))
        }
        if let spendControl = object["spend_control"] as? [String: Any],
           let reached = spendControl["reached"] as? Bool {
            tracks.append(GPTUsageTrack(
                id: "workspace-spend-control",
                scope: .workspace,
                title: "Workspace spend control",
                usedPercent: nil,
                remaining: nil,
                limit: nil,
                resetsAt: resetDate(spendControl),
                windowSeconds: integer(spendControl["limit_window_seconds"] ?? spendControl["window_seconds"]),
                isBlocked: reached,
                modelSlug: nil,
                valueText: reached ? "Limit reached" : "Available"
            ))
        }
        return tracks
    }

    private static func parseRateLimitGroup(
        _ rateLimit: [String: Any],
        idPrefix: String,
        titlePrefix: String
    ) -> [GPTUsageTrack] {
        let preferredOrder = ["primary_window", "secondary_window"]
        let windowKeys = rateLimit.keys
            .filter { $0.hasSuffix("_window") && rateLimit[$0] is [String: Any] }
            .sorted { left, right in
                let leftIndex = preferredOrder.firstIndex(of: left) ?? preferredOrder.count
                let rightIndex = preferredOrder.firstIndex(of: right) ?? preferredOrder.count
                return leftIndex == rightIndex ? left < right : leftIndex < rightIndex
            }

        return windowKeys.compactMap { key in
            let name = String(key.dropLast("_window".count))
            let value = rateLimit[key]
            guard let dictionary = value as? [String: Any],
                  let percent = numeric(dictionary["used_percent"] ?? dictionary["usage_percentage"] ?? dictionary["percent"]) else {
                return nil
            }
            let seconds = windowSeconds(dictionary)
            return GPTUsageTrack(
                id: "\(idPrefix)-\(name)-\(seconds ?? 0)",
                scope: .codex,
                title: usageWindowTitle(prefix: titlePrefix, seconds: seconds),
                usedPercent: clampedPercent(percent),
                remaining: nil,
                limit: nil,
                resetsAt: resetDate(dictionary),
                windowSeconds: seconds,
                isBlocked: (rateLimit["limit_reached"] as? Bool) == true || percent >= 100,
                modelSlug: nil
            )
        }
    }

    static func parseChatGPTTracks(_ object: [String: Any]) -> [GPTUsageTrack] {
        var tracks: [GPTUsageTrack] = []
        for (dictionaryKey, limitObject) in dictionaryEntries(object["limits_progress"]) {
            guard let feature = string(limitObject["feature_name"] ?? limitObject["name"] ?? limitObject["feature"])
                ?? dictionaryKey else { continue }
            let normalizedFeature = normalizedFeatureID(feature)
            let remaining = integer(limitObject["remaining"] ?? limitObject["remaining_count"])
            let total = integer(limitObject["limit"] ?? limitObject["total"] ?? limitObject["max"])
            tracks.append(GPTUsageTrack(
                id: "feature-\(normalizedFeature)",
                scope: .chatGPTFeature,
                title: featureTitle(feature),
                usedPercent: usedPercent(remaining: remaining, limit: total, explicit: limitObject),
                remaining: remaining,
                limit: total,
                resetsAt: resetDate(limitObject),
                windowSeconds: integer(limitObject["limit_window_seconds"] ?? limitObject["window_seconds"]),
                isBlocked: (limitObject["blocked"] as? Bool) == true || remaining == 0,
                modelSlug: nil
            ))
        }

        for (dictionaryKey, limitObject) in dictionaryEntries(object["model_limits"]) {
            guard let slug = string(limitObject["model_slug"] ?? limitObject["slug"] ?? limitObject["model"])
                ?? dictionaryKey else { continue }
            let remaining = integer(limitObject["remaining"] ?? limitObject["remaining_messages"] ?? limitObject["messages_remaining"])
            let total = integer(limitObject["limit"] ?? limitObject["message_limit"] ?? limitObject["max_messages"])
            tracks.append(GPTUsageTrack(
                id: "model-\(slug.lowercased())",
                scope: .chatGPTModel,
                title: "\(displayModelName(slug)) messages",
                usedPercent: usedPercent(remaining: remaining, limit: total, explicit: limitObject),
                remaining: remaining,
                limit: total,
                resetsAt: resetDate(limitObject),
                windowSeconds: integer(limitObject["limit_window_seconds"] ?? limitObject["window_seconds"]),
                isBlocked: (limitObject["blocked"] as? Bool) == true
                    || (limitObject["limit_reached"] as? Bool) == true
                    || remaining == 0,
                modelSlug: slug
            ))
        }
        return tracks
    }

    /// ChatGPT has shipped both array-shaped and slug-keyed limit payloads.
    /// Normalize both forms so plan and backend rollouts do not hide counters.
    private static func dictionaryEntries(_ value: Any?) -> [(String?, [String: Any])] {
        if let array = value as? [[String: Any]] {
            return array.map { (nil, $0) }
        }
        guard let dictionary = value as? [String: Any] else { return [] }
        let nested = dictionary.compactMap { key, value -> (String?, [String: Any])? in
            guard let value = value as? [String: Any] else { return nil }
            return (key, value)
        }
        if !nested.isEmpty { return nested.sorted { ($0.0 ?? "") < ($1.0 ?? "") } }
        return [(nil, dictionary)]
    }

    private static func windowSeconds(_ value: Any?) -> Int? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return numeric(dictionary["limit_window_seconds"] ?? dictionary["window_seconds"]).map(Int.init)
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func clampedPercent(_ value: Double) -> Int {
        min(100, max(0, Int(value.rounded())))
    }

    private static func date(_ value: Any?) -> Date? {
        if let epoch = value as? TimeInterval { return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch) }
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        return nil
    }

    /// Backends have used `reset_after` for both an absolute ISO timestamp
    /// and a relative number of seconds. Keep the two meanings distinct so a
    /// duration never turns into a date near 1970.
    private static func resetDate(_ object: [String: Any]) -> Date? {
        if let absolute = object["reset_at"] ?? object["resets_at"] ?? object["reset_time"] {
            return date(absolute)
        }
        guard let after = object["reset_after"] ?? object["reset_after_seconds"] else { return nil }
        if let seconds = numeric(after), seconds >= 0, seconds < 10_000_000 {
            return Date().addingTimeInterval(seconds)
        }
        return date(after)
    }

    private static func integer(_ value: Any?) -> Int? { numeric(value).map { Int($0.rounded()) } }
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { item in
            string(item) ?? string((item as? [String: Any])?["feature_name"])
        } ?? []
    }
    private static func usedPercent(remaining: Int?, limit: Int?, explicit: [String: Any]) -> Int? {
        if let value = numeric(explicit["used_percent"] ?? explicit["usage_percentage"] ?? explicit["percent"]) {
            return clampedPercent(value)
        }
        guard let remaining, let limit, limit > 0 else { return nil }
        return clampedPercent(Double(limit - remaining) / Double(limit) * 100)
    }
    private static func deduplicated(_ tracks: [GPTUsageTrack]) -> [GPTUsageTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }
    private static func usageWindowTitle(prefix: String, seconds: Int?) -> String {
        switch seconds {
        case 18_000: return "\(prefix) (5 hour)"
        case 604_800: return "\(prefix) (7 day)"
        case 2_592_000: return "\(prefix) (30 day)"
        case let seconds?: return "\(prefix) (\(durationLabel(seconds)))"
        case nil: return prefix
        }
    }
    private static func durationLabel(_ seconds: Int) -> String {
        if seconds % 604_800 == 0 { return "\(seconds / 604_800) day" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600) hour" }
        return "\(seconds / 60) min"
    }
    private static func featureTitle(_ raw: String) -> String {
        let known = [
            "deep_research": "Deep research",
            "image_gen": "Image generation",
            "file_upload": "File uploads",
            "paste_text_to_file": "Paste to file",
            "odyssey": "Agent mode",
            "voice": "Voice"
        ]
        return known[raw.lowercased()] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func normalizedFeatureID(_ raw: String) -> String {
        let normalized = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        let aliases = [
            "deep-research": "deep-research",
            "image-gen": "image-generation",
            "image-generation": "image-generation",
            "file-upload": "file-uploads",
            "file-uploads": "file-uploads",
            "file-storage": "file-storage",
            "paste-text-to-file": "paste-to-file",
            "paste-to-file": "paste-to-file",
            "video": "video-screenshare",
            "screenshare": "video-screenshare",
            "screen-share": "video-screenshare",
            "scheduled-tasks": "scheduled-tasks",
            "tasks": "scheduled-tasks"
        ]
        return aliases[normalized] ?? normalized
    }
    private static func displayModelName(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ").uppercased()
    }

}

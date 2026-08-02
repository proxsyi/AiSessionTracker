import Foundation

struct GPTUsage: Equatable {
    var sessionPercent: Int?
    var sessionResetsAt: Date?
    var weeklyPercent: Int?
    var weeklyResetsAt: Date?
    var fetchedAt: Date

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
    static let fallbackModels = ["gpt-5-4-t-mini"]

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
        guard let request = ChatGPTWebSession.makeBackendRequest(
            path: "/wham/usage",
            auth: auth,
            cookieHeader: cookies
        ) else { throw UsageError.unexpectedResponse }
        let (data, response) = try await perform(request)
        try validate(response: response)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.unexpectedResponse
        }
        let windows = parseUsageWindows(object)
        return GPTUsage(
            sessionPercent: windows.session?.percent,
            sessionResetsAt: windows.session?.reset,
            weeklyPercent: windows.weekly?.percent,
            weeklyResetsAt: windows.weekly?.reset,
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

    static func fetchOrganizationID(sessionKey: String, cookieHeader: String? = nil) async -> String? { nil }
    static func fetchAvailableModels(sessionKey: String, organizationID: String, cookieHeader: String? = nil) async -> [String] {
        guard let cookies = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !cookies.isEmpty,
              let auth = try? await ChatGPTWebSession.resolve(
                savedCredential: sessionKey,
                accountID: organizationID,
                cookieHeader: cookies
              ),
              let request = ChatGPTWebSession.makeBackendRequest(
                path: "/models",
                auth: auth,
                cookieHeader: cookies
              ) else { return fallbackModels }
        guard let (data, response) = try? await perform(request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) else { return fallbackModels }
        let models = collectModels(object)
        return models.isEmpty ? fallbackModels : models
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw UsageError.network(error) }
        catch { throw UsageError.unexpectedResponse }
    }

    private static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UsageError.unexpectedResponse }
        switch http.statusCode { case 200...299: return; case 401, 403: throw UsageError.sessionExpired; default: throw UsageError.serverError(http.statusCode) }
    }

    private static func parseUsageWindows(_ object: [String: Any]) -> (session: (percent: Int, reset: Date?)?, weekly: (percent: Int, reset: Date?)?) {
        if let rateLimit = object["rate_limit"] as? [String: Any] {
            let primary = usageWindow(rateLimit["primary_window"])
            let secondary = usageWindow(rateLimit["secondary_window"])
            let primarySeconds = windowSeconds(rateLimit["primary_window"])
            let secondarySeconds = windowSeconds(rateLimit["secondary_window"])

            if primarySeconds == 604_800, secondary == nil {
                return (nil, primary)
            }
            if secondarySeconds == 18_000, primarySeconds == 604_800 {
                return (secondary, primary)
            }
            return (primary, secondary)
        }

        // Keep a tolerant fallback for gradual backend rollouts while only
        // accepting usage percentages actually returned by ChatGPT.
        var candidates: [(String, Int, Date?)] = []
        func walk(_ node: Any, path: String) {
            if let dictionary = node as? [String: Any] {
                let percent = numeric(dictionary["used_percent"])
                    ?? numeric(dictionary["usage_percentage"])
                    ?? numeric(dictionary["percent"])
                let reset = date(dictionary["reset_at"] ?? dictionary["reset_time"] ?? dictionary["resets_at"])
                if let percent { candidates.append((path.lowercased(), clampedPercent(percent), reset)) }
                dictionary.forEach { walk($0.value, path: path + "." + $0.key) }
            } else if let array = node as? [Any] { array.forEach { walk($0, path: path) } }
        }
        walk(object, path: "")
        let session = candidates.first { $0.0.contains("primary") || $0.0.contains("session") || $0.0.contains("five_hour") || $0.0.contains("5h") }
        let weekly = candidates.first { $0.0.contains("secondary") || $0.0.contains("week") || $0.0.contains("seven_day") || $0.0.contains("7d") }
        return (session.map { ($0.1, $0.2) }, weekly.map { ($0.1, $0.2) })
    }

    private static func usageWindow(_ value: Any?) -> (percent: Int, reset: Date?)? {
        guard let dictionary = value as? [String: Any],
              let percent = numeric(dictionary["used_percent"] ?? dictionary["usage_percentage"] ?? dictionary["percent"]) else {
            return nil
        }
        return (
            clampedPercent(percent),
            date(dictionary["reset_at"] ?? dictionary["resets_at"] ?? dictionary["reset_time"])
        )
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
        if let text = value as? String { return ISO8601DateFormatter().date(from: text) }
        return nil
    }

    private static func collectModels(_ value: Any) -> [String] {
        var values = Set<String>()
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                for key in ["slug", "model", "id"] {
                    if let value = dictionary[key] as? String, value.lowercased().hasPrefix("gpt-") {
                        values.insert(value)
                    }
                }
                dictionary.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(value)
        return values.sorted()
    }
}

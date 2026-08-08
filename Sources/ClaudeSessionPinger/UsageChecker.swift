import Foundation

/// A snapshot of claude.ai plan usage, mirroring what claude.ai/settings/usage
/// shows: the rolling 5-hour session window and the 7-day weekly window.
struct ClaudeUsage: Equatable {
    var planType: String?
    var sessionPercent: Int?
    var sessionResetsAt: Date?
    var weeklyPercent: Int?
    var weeklyResetsAt: Date?
    var fable5Percent: Int?
    var fable5ResetsAt: Date?
    var fable5UsesSharedWeekly: Bool
    var fetchedAt: Date
}

/// Claude service health, read from the public Claude status page.
struct ClaudeServiceStatus: Equatable {
    /// Health level mapped from the status page's indicator field:
    /// "none" = operational, "minor" = degraded performance, anything
    /// worse ("major"/"critical") = outage.
    enum Level: Equatable {
        case operational
        case degraded
        case outage
    }

    var level: Level
    var message: String
    var checkedAt: Date

    var operational: Bool { level == .operational }
}

enum UsageError: Error, LocalizedError {
    case missingCredentials
    case sessionExpired
    case network(URLError)
    case serverError(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Add your session key and organization ID in Settings to see usage."
        case .sessionExpired:
            return "Session key expired or invalid -- sign in again from Settings."
        case .network(let error):
            return "Network error while fetching usage: \(error.localizedDescription)"
        case .serverError(let code):
            return "claude.ai returned an error while fetching usage (HTTP \(code))."
        case .unexpectedResponse:
            return "Couldn't read usage data -- claude.ai's usage API may have changed."
        }
    }
}

/// Fetches claude.ai plan usage and Claude service status. Reads the same
/// internal endpoint that backs claude.ai/settings/usage (the approach used
/// by ClaudeUsageBar and similar menu bar trackers), authenticated with the
/// session key cookie this app already stores for pinging.
enum UsageChecker {
    static func fetchUsage(sessionKey: String, organizationID: String, cookieHeader: String? = nil) async throws -> ClaudeUsage {
        let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrg = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedOrg.isEmpty else {
            throw UsageError.missingCredentials
        }
        guard let url = URL(string: "https://claude.ai/api/organizations/\(trimmedOrg)/usage") else {
            throw UsageError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue((cookieHeader?.isEmpty == false) ? cookieHeader! : "sessionKey=\(trimmedKey)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw UsageError.network(error)
        } catch {
            throw UsageError.unexpectedResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.unexpectedResponse
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw UsageError.sessionExpired
        default:
            throw UsageError.serverError(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.unexpectedResponse
        }
        let session = usageWindow(in: object, keys: ["five_hour", "fiveHour", "session"])
        let weekly = usageWindow(in: object, keys: ["seven_day", "sevenDay", "seven_day_all_models", "weekly"])
        let fable5 = usageWindow(
            in: object,
            keys: [
                "seven_day_fable_5", "seven_day_fable5", "seven_day_fable",
                "fable_5", "fable5", "fable", "fable_weekly",
                "fable_5_weekly", "sevenDayFable5", "sevenDayFable"
            ]
        ) ?? fableUsageWindow(in: object)
        guard session != nil || weekly != nil || fable5 != nil else {
            throw UsageError.unexpectedResponse
        }
        let fableUsesSharedWeekly = fable5 == nil && weekly != nil
        var planType = accountPlan(in: object)
        if planType == nil {
            planType = await fetchAccountPlan(
                sessionKey: trimmedKey,
                organizationID: trimmedOrg,
                cookieHeader: cookieHeader
            )
        }
        return ClaudeUsage(
            planType: planType,
            sessionPercent: session?.percent,
            sessionResetsAt: session?.resetsAt,
            weeklyPercent: weekly?.percent,
            weeklyResetsAt: weekly?.resetsAt,
            fable5Percent: fable5?.percent ?? weekly?.percent,
            fable5ResetsAt: fable5?.resetsAt ?? weekly?.resetsAt,
            fable5UsesSharedWeekly: fableUsesSharedWeekly,
            fetchedAt: Date()
        )
    }

    private static func fetchAccountPlan(
        sessionKey: String,
        organizationID: String,
        cookieHeader: String?
    ) async -> String? {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(organizationID)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue((cookieHeader?.isEmpty == false) ? cookieHeader! : "sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return accountPlan(in: object)
    }

    static func accountPlan(in object: [String: Any]) -> String? {
        let preferredKeys = [
            "plan_type", "plan", "subscription_type", "subscription_tier",
            "billing_plan", "account_tier"
        ]
        for key in preferredKeys {
            if let value = nonemptyString(object[key]), isUsefulPlan(value) { return value }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let plan = accountPlan(in: nested) { return plan }
            if let array = value as? [[String: Any]] {
                for nested in array {
                    if let plan = accountPlan(in: nested) { return plan }
                }
            }
        }
        return nil
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isUsefulPlan(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return !normalized.hasPrefix("default")
            && !["unknown", "none"].contains(normalized)
    }

    /// Never throws -- service status is informational and must not break the
    /// usage display when the status page is unreachable.
    static func fetchServiceStatus() async -> ClaudeServiceStatus? {
        for host in ["https://status.claude.com", "https://status.anthropic.com"] {
            guard let url = URL(string: "\(host)/api/v2/status.json") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard
                let (data, response) = try? await URLSession.shared.data(for: request),
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let status = object["status"] as? [String: Any],
                let indicator = status["indicator"] as? String
            else { continue }
            let level: ClaudeServiceStatus.Level
            switch indicator.lowercased() {
            case "none":
                level = .operational
            case "minor":
                level = .degraded
            default:
                level = .outage
            }
            let message: String
            switch level {
            case .operational:
                message = "All Claude services operational"
            case .degraded:
                message = (status["description"] as? String) ?? "Claude services are performing poorly"
            case .outage:
                message = (status["description"] as? String) ?? "Claude is reporting a service outage"
            }
            return ClaudeServiceStatus(level: level, message: message, checkedAt: Date())
        }
        return nil
    }

    /// Fetches the account's organization UUID straight from claude.ai using
    /// the captured session key. Used right after login as a fallback when
    /// the `lastActiveOrg` cookie hasn't been set yet, so signing in always
    /// captures everything the app needs. Never throws -- returns nil and
    /// lets the manual Settings field handle it.
    static func fetchOrganizationID(sessionKey: String, cookieHeader: String? = nil) async -> String? {
        let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let url = URL(string: "https://claude.ai/api/organizations") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue((cookieHeader?.isEmpty == false) ? cookieHeader! : "sessionKey=\(trimmedKey)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        // Some responses are the organizations themselves; others wrap them
        // in membership objects. Prefer an org with chat capability.
        func uuid(of item: [String: Any]) -> String? {
            (item["uuid"] as? String) ?? ((item["organization"] as? [String: Any])?["uuid"] as? String)
        }
        func capabilities(of item: [String: Any]) -> [String] {
            (item["capabilities"] as? [String])
                ?? ((item["organization"] as? [String: Any])?["capabilities"] as? [String])
                ?? []
        }
        let preferred = array.first { capabilities(of: $0).contains("chat") } ?? array.first
        return preferred.flatMap { uuid(of: $0) }
    }

    /// Known model slugs, cheapest first, used when the live list can't be
    /// fetched so automatic selection always has something to try.
    static let fallbackModels = [
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-1-20250805"
    ]

    /// Fetches the model slugs available to this account from claude.ai.
    /// The endpoint is internal and undocumented, so parsing is deliberately
    /// tolerant: any "claude-..." string found in the response counts,
    /// whether the payload is a bare array, a {"models": [...]} wrapper, or
    /// objects keyed "model"/"id"/"slug". Never throws -- returns [] when
    /// nothing could be read, and callers fall back to `fallbackModels`.
    static func fetchAvailableModels(sessionKey: String, organizationID: String, cookieHeader: String? = nil) async -> [String] {
        let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrg = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedOrg.isEmpty,
              let url = URL(string: "https://claude.ai/api/organizations/\(trimmedOrg)/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/new", forHTTPHeaderField: "Referer")
        request.setValue((cookieHeader?.isEmpty == false) ? cookieHeader! : "sessionKey=\(trimmedKey)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var slugs: [String] = []
        func harvest(_ value: Any) {
            if let text = value as? String {
                if text.hasPrefix("claude-"), !slugs.contains(text) {
                    slugs.append(text)
                }
            } else if let array = value as? [Any] {
                array.forEach { harvest($0) }
            } else if let dict = value as? [String: Any] {
                dict.values.forEach { harvest($0) }
            }
        }
        harvest(json)
        return slugs
    }

    // MARK: - Tolerant JSON parsing

    private struct UsageWindow {
        var percent: Int?
        var resetsAt: Date?
    }

    private static func usageWindow(in object: [String: Any], keys: [String]) -> UsageWindow? {
        for key in keys {
            guard let dict = object[key] as? [String: Any], let window = usageWindow(in: dict) else { continue }
            return window
        }
        return nil
    }

    /// Fable has appeared both as a named top-level limit and inside the
    /// newer dynamic model-scoped limit collection. A scoped entry can keep
    /// model metadata and usage values in sibling dictionaries, so identify
    /// the whole entry first and then search that entry for its usage window.
    private static func fableUsageWindow(in value: Any) -> UsageWindow? {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if normalized.contains("fable"), let window = usageWindowRecursively(in: child) {
                    return window
                }
            }

            let identifyingKeys = [
                "model", "model_id", "modelId", "model_name", "modelName",
                "model_family", "modelFamily", "scope", "name", "slug", "label", "id"
            ]
            let identifiesFable = identifyingKeys.contains { key in
                dict[key].map { valueContainsFable($0) } ?? false
            }
            if identifiesFable, let window = usageWindowRecursively(in: dict) {
                return window
            }

            for child in dict.values {
                if let window = fableUsageWindow(in: child) { return window }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let window = fableUsageWindow(in: child) { return window }
            }
        }
        return nil
    }

    private static func valueContainsFable(_ value: Any) -> Bool {
        if let text = value as? String {
            return text.lowercased().contains("fable")
        }
        if let dict = value as? [String: Any] {
            return dict.values.contains { valueContainsFable($0) }
        }
        if let array = value as? [Any] {
            return array.contains { valueContainsFable($0) }
        }
        return false
    }

    private static func usageWindowRecursively(in value: Any) -> UsageWindow? {
        if let dict = value as? [String: Any] {
            if let window = usageWindow(in: dict) { return window }
            let preferredKeys = ["seven_day", "sevenDay", "weekly", "rate_limit", "rateLimit", "usage", "window", "limit"]
            for key in preferredKeys {
                if let child = dict[key], let window = usageWindowRecursively(in: child) {
                    return window
                }
            }
            for child in dict.values {
                if let window = usageWindowRecursively(in: child) { return window }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let window = usageWindowRecursively(in: child) { return window }
            }
        }
        return nil
    }

    private static func usageWindow(in dict: [String: Any]) -> UsageWindow? {
        let percent = percentValue(dict["utilization"])
            ?? percentValue(dict["utilization_percentage"])
            ?? percentValue(dict["percentage"])
            ?? percentValue(dict["usage_percentage"])
            ?? percentValue(dict["used_percentage"])
            ?? percentValue(dict["percent_used"])
            ?? percentValue(dict["percent"])
        let resets = dateValue(dict["resets_at"])
            ?? dateValue(dict["reset_at"])
            ?? dateValue(dict["resetsAt"])
            ?? dateValue(dict["reset_time"])
            ?? dateValue(dict["resetTime"])
        if percent != nil || resets != nil {
            return UsageWindow(percent: percent, resetsAt: resets)
        }

        // Some responses wrap the actual values one level below the model.
        for key in ["usage", "window", "limit", "rate_limit", "rateLimit"] {
            if let child = dict[key] as? [String: Any], let window = usageWindow(in: child) {
                return window
            }
        }
        return nil
    }

    /// claude.ai reports utilization as a 0-100 number; numeric strings are
    /// also accepted. Clamped to 0...100.
    private static func percentValue(_ raw: Any?) -> Int? {
        let number: Double?
        if let value = raw as? Double {
            number = value
        } else if let value = raw as? Int {
            number = Double(value)
        } else if let text = raw as? String, let value = Double(text) {
            number = value
        } else {
            number = nil
        }
        guard let number else { return nil }
        return max(0, min(100, Int(number.rounded())))
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        let numeric: Double?
        if let value = raw as? Double {
            numeric = value
        } else if let value = raw as? Int {
            numeric = Double(value)
        } else {
            numeric = nil
        }
        if let numeric {
            let seconds = numeric > 1_000_000_000_000 ? numeric / 1_000 : numeric
            if seconds > 1_000_000_000 {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        if let text = raw as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        }
        return nil
    }
}

import Foundation

struct ChatGPTAuthSession: Sendable {
    let accessToken: String
    let accountID: String?
}

/// Resolves the short-lived bearer token used by ChatGPT's web backend from
/// the same signed-in browser session whose cookies are stored in Keychain.
/// The cookie header remains the source of truth, so an expired bearer token
/// can be refreshed without asking the user to log in again.
enum ChatGPTWebSession {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func resolve(
        savedCredential: String,
        accountID: String? = nil,
        cookieHeader: String
    ) async throws -> ChatGPTAuthSession {
        if let current = await fetchAuthSession(cookieHeader: cookieHeader) {
            return current
        }

        let trimmed = savedCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeAccessToken(trimmed) else { throw PingError.sessionExpired }
        return ChatGPTAuthSession(accessToken: trimmed, accountID: accountID?.nilIfEmpty)
    }

    static func fetchAuthSession(cookieHeader: String) async -> ChatGPTAuthSession? {
        let cookies = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookies.isEmpty, let url = URL(string: "https://chatgpt.com/api/auth/session") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = findString(in: object, keys: ["accessToken", "access_token"]),
              looksLikeAccessToken(accessToken) else { return nil }

        let accountID = findString(in: object, keys: ["accountId", "account_id", "chatgpt_account_id"])
            ?? ((object["account"] as? [String: Any])?["id"] as? String)
        return ChatGPTAuthSession(accessToken: accessToken, accountID: accountID?.nilIfEmpty)
    }

    static func deviceID(from cookieHeader: String) -> String? {
        cookieValue(named: "oai-did", in: cookieHeader)
    }

    static func makeBackendRequest(
        path: String,
        method: String = "GET",
        auth: ChatGPTAuthSession,
        cookieHeader: String,
        accept: String = "application/json",
        body: Data? = nil
    ) -> URLRequest? {
        guard let url = URL(string: "https://chatgpt.com/backend-api\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Oai-Language")
        if let deviceID = deviceID(from: cookieHeader) {
            request.setValue(deviceID, forHTTPHeaderField: "Oai-Device-Id")
        }
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    private static func looksLikeAccessToken(_ value: String) -> Bool {
        value.count > 40 && (value.hasPrefix("eyJ") || value.split(separator: ".").count == 3)
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            return pair[1].nilIfEmpty
        }
        return nil
    }

    private static func findString(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let string = dictionary[key] as? String, !string.isEmpty { return string }
            }
            for child in dictionary.values {
                if let found = findString(in: child, keys: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findString(in: child, keys: keys) { return found }
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

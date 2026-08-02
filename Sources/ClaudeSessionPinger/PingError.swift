import Foundation

enum PingError: LocalizedError {
    case missingCredentials
    case invalidURL
    case network(URLError)
    case sessionExpired
    case rateLimited
    case serverError(Int, String)
    case unexpectedResponse(String)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "ChatGPT session or model is missing. Open Settings and sign in."
        case .invalidURL:
            return "Could not build a valid ChatGPT request URL."
        case .network(let urlError):
            return "Network error: \(urlError.localizedDescription)"
        case .sessionExpired:
            return "Your ChatGPT session looks expired or invalid. Sign in again from Settings."
        case .rateLimited:
            return "Rate limited by the server. Will try again next scheduled time."
        case .serverError(let code, let body):
            return "Server returned \(code): \(body.prefix(200))"
        case .unexpectedResponse(let details):
            return "Unexpected response: \(details.prefix(200))"
        case .unknown(let error):
            return "Unexpected error: \(error.localizedDescription)"
        }
    }
}

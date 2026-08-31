import WebKit

@MainActor
public enum TrackerWebsiteData {
    public static let claudeDomains = ["claude.ai", "anthropic.com"]
    public static let openAIDomains = ["chatgpt.com", "openai.com"]

    public static func matches(_ host: String, domains: [String]) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The combined app shares a WebKit container. Delete only this provider's
    /// cookies and records; never clear the entire container for a logout.
    public static func clear(domains: [String], store suppliedStore: WKWebsiteDataStore? = nil) async {
        let store = suppliedStore ?? WKWebsiteDataStore.default()
        let cookies = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies where matches(cookie.domain, domains: domains) {
            await withCheckedContinuation { continuation in
                store.httpCookieStore.delete(cookie) { continuation.resume() }
            }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let owned = records.filter { matches($0.displayName, domains: domains) }
        guard !owned.isEmpty else { return }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: owned) { continuation.resume() }
        }
    }
}

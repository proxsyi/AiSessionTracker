import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status \(status)."
        }
    }
}

enum KeychainStore {
    struct WebSession: Codable, Equatable {
        var sessionKey: String
        var cookieHeader: String
    }

    private static let service = "com.proxsyi.gptsessionpinger"
    private static let account = "webSession"
    private static let legacyAccounts = ["sessionKey", "cookieHeader"]

    static func save(sessionKey: String, cookieHeader: String) throws {
        if sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            delete()
            return
        }
        let session = WebSession(sessionKey: sessionKey, cookieHeader: cookieHeader)
        let data = try JSONEncoder().encode(session)
        try save(data, account: account)
    }

    static func load() -> WebSession? {
        if let data = loadData(account: account),
           let session = try? JSONDecoder().decode(WebSession.self, from: data) {
            deleteLegacyItems()
            return session
        }

        let sessionKey = loadString(account: "sessionKey") ?? ""
        let cookieHeader = loadString(account: "cookieHeader") ?? ""
        guard !sessionKey.isEmpty || !cookieHeader.isEmpty else { return nil }
        let session = WebSession(sessionKey: sessionKey, cookieHeader: cookieHeader)
        do {
            try save(sessionKey: sessionKey, cookieHeader: cookieHeader)
            deleteLegacyItems()
        } catch {
            return session
        }
        return session
    }

    static func delete() {
        delete(account: account)
        deleteLegacyItems()
    }

    private static func save(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }

    private static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func loadString(account: String) -> String? {
        guard let data = loadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacyItems() {
        for legacyAccount in legacyAccounts { delete(account: legacyAccount) }
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

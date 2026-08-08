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

    private static let service = "com.proxsyi.claudesessionpinger"
    private static let legacyServices = ["com.cash.claudesessionpinger"]
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
        try save(data, account: account, service: service)
    }

    static func load() -> WebSession? {
        if let data = loadData(account: account, service: service),
           let session = try? JSONDecoder().decode(WebSession.self, from: data) {
            deleteLegacyItems()
            return session
        }

        let services = [service] + legacyServices
        for candidateService in services {
            let sessionKey = loadString(account: "sessionKey", service: candidateService) ?? ""
            let cookieHeader = loadString(account: "cookieHeader", service: candidateService) ?? ""
            guard !sessionKey.isEmpty || !cookieHeader.isEmpty else { continue }
            let session = WebSession(sessionKey: sessionKey, cookieHeader: cookieHeader)
            do {
                try save(sessionKey: sessionKey, cookieHeader: cookieHeader)
                deleteLegacyItems()
            } catch {
                return session
            }
            return session
        }
        return nil
    }

    static func delete() {
        delete(account: account, service: service)
        deleteLegacyItems()
    }

    private static func save(_ data: Data, account: String, service: String) throws {
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

    private static func loadData(account: String, service: String) -> Data? {
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

    private static func loadString(account: String, service: String) -> String? {
        guard let data = loadData(account: account, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacyItems() {
        for candidateService in [service] + legacyServices {
            for legacyAccount in legacyAccounts {
                delete(account: legacyAccount, service: candidateService)
            }
        }
    }

    private static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

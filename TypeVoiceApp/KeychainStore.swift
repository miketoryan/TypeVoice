import Foundation
import Security

struct ChatGPTTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var expiresAt: Date
    var accountID: String?
    var email: String?
    var plan: String?
}

enum KeychainStore {
    private static let service = "com.miketoryan.TypeVoice"
    private static let chatGPTAccount = "chatgpt-codex-oauth"

    static func saveChatGPTTokens(_ tokens: ChatGPTTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try save(data, account: chatGPTAccount)
    }

    static func loadChatGPTTokens() -> ChatGPTTokens? {
        guard let data = load(account: chatGPTAccount) else { return nil }
        return try? JSONDecoder().decode(ChatGPTTokens.self, from: data)
    }

    static func deleteChatGPTTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: chatGPTAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func save(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)

        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.status(updateStatus)
            }
        } else if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.status(addStatus)
            }
        } else {
            throw KeychainError.status(status)
        }
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }

        return data
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let value):
            return "Keychain error: \(value)"
        }
    }
}

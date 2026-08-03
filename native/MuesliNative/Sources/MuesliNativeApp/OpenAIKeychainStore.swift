import Foundation
import Security

/// Stores the OpenAI dictation API key in the macOS Keychain instead of in the
/// app's `config.json`. A dedicated service keeps it separate from any other
/// OpenAI credentials the app may hold (e.g. meeting summaries).
enum OpenAIKeychainStore {
    static let service = "com.muesli.app.openai-dictation"
    static let account = "api_key"

    static func save(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let attributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        case errSecItemNotFound:
            var query = baseQuery
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        default:
            fputs("[openai-dictation] keychain save failed with status \(status)\n", stderr)
        }
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                fputs("[openai-dictation] keychain read failed with status \(status)\n", stderr)
            }
            return nil
        }
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

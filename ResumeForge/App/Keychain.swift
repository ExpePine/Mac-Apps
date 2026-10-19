import Foundation
import Security

/// Stores the Groq API key in the macOS Keychain (not in UserDefaults or the data file).
enum Keychain {
    private static let service = "com.rajmishra.ResumeForge"
    private static let account = "groq-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = baseQuery
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

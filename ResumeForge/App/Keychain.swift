import Foundation
import Security

/// Stores API keys and tokens in the macOS Keychain (never in UserDefaults or the data file).
enum Keychain {
    private static let service = "com.rajmishra.ResumeForge"
    static let groqAccount = "groq-api-key"   // original account name, kept for existing installs

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = query(account)
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // Back-compat helpers: "is any AI key configured?"
    static func save(_ value: String) { save(value, account: groqAccount) }
    static func load() -> String { ProviderSettings.anyKeyConfigured ? "configured" : "" }
}

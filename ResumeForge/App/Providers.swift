import Foundation

/// AI providers that speak the OpenAI-style Chat Completions API.
/// You can add keys for several; the app uses them in your chosen order and falls back
/// to the next one when a provider runs out of free quota.
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case gemini, groq, cerebras, mistral, openrouter, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .cerebras: return "Cerebras"
        case .mistral: return "Mistral"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    /// Starting model. Free line-ups change — use "Test & list models" in Settings to pick a current one.
    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-2.5-flash"
        case .groq: return "openai/gpt-oss-120b"
        case .cerebras: return ""
        case .mistral: return "mistral-small-latest"
        case .openrouter: return ""
        case .custom: return ""
        }
    }

    var keyURL: String {
        switch self {
        case .gemini: return "https://aistudio.google.com/apikey"
        case .groq: return "https://console.groq.com/keys"
        case .cerebras: return "https://cloud.cerebras.ai"
        case .mistral: return "https://console.mistral.ai/api-keys"
        case .openrouter: return "https://openrouter.ai/keys"
        case .custom: return ""
        }
    }

    /// Size of one request (input + output) the app plans for until it learns the real limit.
    var defaultRequestBudget: Int {
        switch self {
        case .groq: return 8_000
        case .gemini: return 100_000
        case .cerebras: return 30_000
        case .mistral: return 60_000
        case .openrouter: return 30_000
        case .custom: return 16_000
        }
    }

    var defaultVision: Bool { self == .gemini }

    var keychainAccount: String { self == .groq ? Keychain.groqAccount : "ai-key-\(rawValue)" }

    var privacyNote: String {
        switch self {
        case .gemini: return "Free tier: Google may use inputs to improve products and human reviewers may read them."
        case .mistral: return "Free mode: Mistral may train on your data unless you opt out in its Privacy settings."
        case .openrouter: return "Free models are run by third parties whose logging policies vary."
        default: return ""
        }
    }
}

struct ProviderConfig: Codable, Identifiable, Hashable {
    var kind: ProviderKind
    var enabled = true
    var model: String
    var baseURL: String
    var vision: Bool
    var fastModel: String?          // optional smaller/faster model for bulk work (fit checks)

    var id: ProviderKind { kind }

    /// The same provider, using its fast model if you set one.
    var forBulk: ProviderConfig {
        guard let f = fastModel?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { return self }
        var c = self
        c.model = f
        return c
    }

    init(kind: ProviderKind) {
        self.kind = kind
        model = kind.defaultModel
        baseURL = kind.defaultBaseURL
        vision = kind.defaultVision
        enabled = true
    }

    var apiKey: String { Keychain.load(account: kind.keychainAccount) }
    var isUsable: Bool { enabled && !apiKey.isEmpty && !model.isEmpty && !baseURL.isEmpty }
}

/// Provider list (in priority order) persisted in UserDefaults; keys live in the Keychain.
enum ProviderSettings {
    private static let key = "aiProviders"

    static var all: [ProviderConfig] {
        get {
            if let d = UserDefaults.standard.data(forKey: key),
               var list = try? JSONDecoder().decode([ProviderConfig].self, from: d) {
                for k in ProviderKind.allCases where !list.contains(where: { $0.kind == k }) {
                    list.append(ProviderConfig(kind: k))
                }
                return list
            }
            return defaults()
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: key) }
        }
    }

    /// First run: Gemini first, then Groq (carrying over the model chosen in older versions).
    private static func defaults() -> [ProviderConfig] {
        var list = ProviderKind.allCases.map(ProviderConfig.init(kind:))
        if let old = UserDefaults.standard.string(forKey: "groqModel"), !old.isEmpty,
           let i = list.firstIndex(where: { $0.kind == .groq }) {
            list[i].model = old
        }
        return list
    }

    static var usable: [ProviderConfig] { all.filter(\.isUsable) }
    static var anyKeyConfigured: Bool { !usable.isEmpty }
}

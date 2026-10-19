import Foundation

struct GroqError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal client for Groq's OpenAI-compatible Chat Completions endpoint.
/// Docs: https://console.groq.com/docs  (verify parameter names there if a call fails)
struct GroqClient {
    static let baseURL = URL(string: "https://api.groq.com/openai/v1")!

    let apiKey: String
    let model: String

    struct Message {
        let role: String      // system | user | assistant
        let content: String
    }

    func complete(messages: [Message],
                  jsonMode: Bool,
                  temperature: Double = 0.4,
                  maxTokens: Int = 8000) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GroqError(message: "Add your Groq API key in Settings (⌘,).")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_completion_tokens": maxTokens
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }

        var req = URLRequest(url: Self.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(status) else {
            let err = obj?["error"] as? [String: Any]
            let msg = (err?["message"] as? String) ?? String(decoding: data.prefix(600), as: UTF8.self)
            let code = (err?["code"] as? String) ?? ""
            throw GroqError(message: "Groq API error \(status) \(code): \(msg)")
        }
        guard let choices = obj?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw GroqError(message: "Groq returned an empty response. Try again, or pick another model in Settings.")
        }
        return content
    }

    /// JSON-mode call. If Groq rejects the output as invalid JSON, retries once without JSON mode
    /// and extracts the object from the text.
    func json(messages: [Message], temperature: Double = 0.4) async throws -> [String: Any] {
        let text: String
        do {
            text = try await complete(messages: messages, jsonMode: true, temperature: temperature)
        } catch let e as GroqError where e.message.contains("json_validate_failed") {
            text = try await complete(messages: messages, jsonMode: false, temperature: temperature)
        }
        return try JSONExtract.object(from: text)
    }

    func json(system: String, user: String, temperature: Double = 0.4) async throws -> [String: Any] {
        try await json(messages: [Message(role: "system", content: system),
                                  Message(role: "user", content: user)],
                       temperature: temperature)
    }

    /// GET /models — lists model IDs currently active on your Groq account.
    func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw GroqError(message: "Enter an API key first.") }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("models"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GroqError(message: "Groq API error \(status): \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ids = (obj?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.sorted()
    }
}

enum JSONExtract {
    static func object(from text: String) throws -> [String: Any] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end {
            t = String(t[start...end])
        }
        guard let data = t.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GroqError(message: "The model's reply wasn't valid JSON. Try again, or switch to a larger model in Settings.")
        }
        return obj
    }
}

/// Tolerant readers for LLM JSON (fields may be missing, strings vs numbers, etc.)
enum J {
    static func str(_ d: [String: Any]?, _ k: String) -> String {
        guard let v = d?[k] else { return "" }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func bool(_ d: [String: Any]?, _ k: String) -> Bool {
        if let b = d?[k] as? Bool { return b }
        if let s = d?[k] as? String { return s.lowercased() == "true" }
        return false
    }

    static func strings(_ d: [String: Any]?, _ k: String) -> [String] {
        if let arr = d?[k] as? [Any] {
            return arr.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let s = d?[k] as? String, !s.isEmpty {
            return s.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    static func dict(_ d: [String: Any]?, _ k: String) -> [String: Any]? { d?[k] as? [String: Any] }

    static func dicts(_ d: [String: Any]?, _ k: String) -> [[String: Any]] { d?[k] as? [[String: Any]] ?? [] }

    static func bullets(_ d: [String: Any]?, _ k: String) -> [ResumeBullet] {
        guard let arr = d?[k] as? [Any] else { return [] }
        return arr.compactMap { item -> ResumeBullet? in
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : ResumeBullet(text: t, sources: [])
            }
            if let o = item as? [String: Any] {
                let t = str(o, "text")
                return t.isEmpty ? nil : ResumeBullet(text: t, sources: strings(o, "sources"))
            }
            return nil
        }
    }
}

extension ResumeDoc {
    init(json d: [String: Any], mode: String) {
        self.init()
        self.mode = mode
        name = J.str(d, "name")
        contactLine = J.str(d, "contactLine")
        summary = J.str(d, "summary")
        experience = J.dicts(d, "experience").map {
            ResumeRole(company: J.str($0, "company"), location: J.str($0, "location"),
                       title: J.str($0, "title"), dates: J.str($0, "dates"),
                       bullets: J.bullets($0, "bullets"))
        }
        achievements = J.dicts(d, "achievements").map {
            ResumeAchievement(label: J.str($0, "label"), text: J.str($0, "text"),
                              subItems: J.strings($0, "subItems"), sources: J.strings($0, "sources"))
        }
        education = J.dicts(d, "education").map {
            ResumeEducation(qualification: J.str($0, "qualification"), institution: J.str($0, "institution"),
                            location: J.str($0, "location"), year: J.str($0, "year"))
        }
        additional = J.dicts(d, "additional").map {
            LabeledLine(label: J.str($0, "label"), value: J.str($0, "value"))
        }.filter { !$0.value.isEmpty }
        generatedAt = Date()
    }
}

extension Story {
    init(json d: [String: Any], origin: String) {
        self.init()
        title = J.str(d, "title")
        company = J.str(d, "company")
        role = J.str(d, "role")
        period = J.str(d, "period")
        text = J.str(d, "text")
        metrics = J.strings(d, "metrics")
        skills = J.strings(d, "skills")
        self.origin = origin
    }
}

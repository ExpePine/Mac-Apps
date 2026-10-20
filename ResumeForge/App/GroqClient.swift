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

    // MARK: Token-per-minute budget

    /// The account's tokens-per-minute limit for a model. Learned from Groq's responses
    /// (x-ratelimit-limit-tokens header, or the "Limit N" in a 413 error). Free tier = 8,000.
    static func tpmLimit(for model: String) -> Int {
        let v = UserDefaults.standard.integer(forKey: "groqTPM.\(model)")
        return v > 0 ? v : 8000
    }
    static func setTPMLimit(_ v: Int, for model: String) {
        guard v > 0 else { return }
        UserDefaults.standard.set(v, forKey: "groqTPM.\(model)")
    }

    /// Conservative token estimate (English + JSON averages ~3.5–4 chars per token; 3 leaves headroom).
    static func estimateTokens(_ s: String) -> Int { s.count / 3 + 1 }

    /// Posted while waiting out a per-minute limit, so the UI can say so. userInfo["message"]: String
    static let waitingNotification = Notification.Name("GroqClientWaiting")

    struct RequestTooLarge: LocalizedError {
        let limit: Int
        let requested: Int
        var errorDescription: String? {
            "This request (\(requested) tokens) is larger than your Groq plan allows per minute (\(limit))."
        }
    }

    /// One request at a time: with a per-minute token limit, parallel calls only collide.
    static let gate = AsyncGate()

    func complete(messages: [Message],
                  jsonMode: Bool,
                  temperature: Double = 0.4,
                  maxTokens: Int = 3000) async throws -> String {
        await Self.gate.acquire()
        do {
            let r = try await send(messages: messages, jsonMode: jsonMode, temperature: temperature, maxTokens: maxTokens)
            await Self.gate.release()
            return r
        } catch {
            await Self.gate.release()
            throw error
        }
    }

    private func send(messages: [Message],
                      jsonMode: Bool,
                      temperature: Double,
                      maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GroqError(message: "Add your Groq API key in Settings (⌘,).")
        }
        // Keep input + requested output under the per-minute limit.
        let limit = Self.tpmLimit(for: model)
        let inputEstimate = messages.reduce(0) { $0 + Self.estimateTokens($1.content) + 8 }
        let output = max(256, min(maxTokens, limit - inputEstimate - 150))

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_completion_tokens": output
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        if model.hasPrefix("openai/gpt-oss") {
            // Short private reasoning leaves more of the per-minute budget for the actual answer.
            body["reasoning_effort"] = "low"
            body["include_reasoning"] = false
        }
        let payload = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: Self.baseURL.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.timeoutInterval = 180
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload

            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if let h = http?.value(forHTTPHeaderField: "x-ratelimit-limit-tokens"), let v = Int(h) {
                Self.setTPMLimit(v, for: model)
            }

            if (200..<300).contains(status) {
                guard let choices = obj?["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String,
                      !content.isEmpty else {
                    throw GroqError(message: "Groq returned an empty response. Try again, or pick another model in Settings.")
                }
                return content
            }

            let err = obj?["error"] as? [String: Any]
            let msg = (err?["message"] as? String) ?? String(decoding: data.prefix(600), as: UTF8.self)
            let code = (err?["code"] as? String) ?? ""

            // 413 "Request too large … Limit N, Requested M": learn the limit; caller shrinks and retries.
            if status == 413, let lim = Self.firstInt(after: "Limit ", in: msg) {
                Self.setTPMLimit(lim, for: model)
                throw RequestTooLarge(limit: lim, requested: Self.firstInt(after: "Requested ", in: msg) ?? 0)
            }

            // 429: per-minute (or per-day) limit reached — wait as Groq says and retry.
            if status == 429 && attempt <= 4 {
                if msg.localizedCaseInsensitiveContains("per day") {
                    throw GroqError(message: "You've used today's Groq allowance for \(model). Try again tomorrow, or pick another model in Settings.\n\n\(msg)")
                }
                let wait = min(90, max(2, http.flatMap { Self.retryAfter($0) } ?? Self.parseWait(msg) ?? 20))
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.waitingNotification, object: nil,
                                                    userInfo: ["message": "Groq per-minute limit — waiting \(Int(wait.rounded(.up)))s…"])
                }
                try await Task.sleep(nanoseconds: UInt64((wait + 0.5) * 1_000_000_000))
                continue
            }
            throw GroqError(message: "Groq API error \(status) \(code): \(msg)")
        }
    }

    private static func retryAfter(_ r: HTTPURLResponse) -> Double? {
        r.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
    }

    /// Parses "Please try again in 12.5s" / "in 1m3.2s" / "in 450ms".
    private static func parseWait(_ msg: String) -> Double? {
        guard let r = msg.range(of: #"try again in ([0-9hms\.]+)"#, options: .regularExpression) else { return nil }
        let token = msg[r].replacingOccurrences(of: "try again in ", with: "")
        var total = 0.0
        var num = ""
        var i = token.startIndex
        while i < token.endIndex {
            let c = token[i]
            if c.isNumber || c == "." { num.append(c) }
            else {
                let v = Double(num) ?? 0
                if c == "m", token.index(after: i) < token.endIndex, token[token.index(after: i)] == "s" {
                    total += v / 1000; i = token.index(after: i)
                } else if c == "h" { total += v * 3600 }
                else if c == "m" { total += v * 60 }
                else if c == "s" { total += v }
                num = ""
            }
            i = token.index(after: i)
        }
        return total > 0 ? total : nil
    }

    private static func firstInt(after label: String, in s: String) -> Int? {
        guard let r = s.range(of: label) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// JSON-mode call. If Groq rejects the output as invalid JSON, retries once without JSON mode
    /// and extracts the object from the text.
    func json(messages: [Message], temperature: Double = 0.4, maxTokens: Int = 3000) async throws -> [String: Any] {
        let text: String
        do {
            text = try await complete(messages: messages, jsonMode: true, temperature: temperature, maxTokens: maxTokens)
        } catch let e as GroqError where e.message.contains("json_validate_failed") {
            text = try await complete(messages: messages, jsonMode: false, temperature: temperature, maxTokens: maxTokens)
        }
        return try JSONExtract.object(from: text)
    }

    func json(system: String, user: String, temperature: Double = 0.4, maxTokens: Int = 3000) async throws -> [String: Any] {
        try await json(messages: [Message(role: "system", content: system),
                                  Message(role: "user", content: user)],
                       temperature: temperature, maxTokens: maxTokens)
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

/// A tiny async mutex.
actor AsyncGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

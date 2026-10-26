import AppKit
import Foundation

struct GroqError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Older code refers to GroqClient; the client now talks to any OpenAI-compatible provider.
typealias GroqClient = AIClient

/// Minimal client for OpenAI-compatible Chat Completions APIs (Gemini, Groq, Cerebras, Mistral, OpenRouter…).
struct AIClient {
    let provider: ProviderConfig

    var apiKey: String { provider.apiKey }
    var model: String { provider.model }
    var baseURL: URL? { URL(string: provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))) }

    struct Message {
        let role: String      // system | user | assistant
        let content: String
        var images: [Data] = []   // JPEG/PNG bytes, sent as data: URLs (vision models only)
    }

    // MARK: Request-size budget

    private static func limitKey(_ p: ProviderConfig) -> String { "tpm.\(p.kind.rawValue).\(p.model)" }

    /// Largest single request (input + output) this provider/model accepts. Learned from replies; falls back to a default.
    static func tpmLimit(for p: ProviderConfig) -> Int {
        let v = UserDefaults.standard.integer(forKey: limitKey(p))
        if v > 0 { return v }
        if p.kind == .groq {   // value learned by older versions
            let old = UserDefaults.standard.integer(forKey: "groqTPM.\(p.model)")
            if old > 0 { return old }
        }
        return p.kind.defaultRequestBudget
    }
    static func setTPMLimit(_ v: Int, for p: ProviderConfig) {
        guard v > 0 else { return }
        UserDefaults.standard.set(v, forKey: limitKey(p))
    }

    /// Conservative token estimate (English + JSON averages ~3.5–4 chars per token; 3 leaves headroom).
    static func estimateTokens(_ s: String) -> Int { s.count / 3 + 1 }

    /// Posted while waiting out a rate limit, so the UI can say so. userInfo["message"]: String
    static let waitingNotification = Notification.Name("GroqClientWaiting")

    struct RequestTooLarge: LocalizedError {
        let limit: Int
        let requested: Int
        var errorDescription: String? {
            "This request (\(requested) tokens) is larger than the provider allows (\(limit))."
        }
    }

    /// Provider is out of quota (daily cap, or still rate-limited after retries) — try the next provider.
    struct QuotaExceeded: LocalizedError {
        let provider: String
        let detail: String
        var daily = true                 // false = only the per-minute limit (try again in a minute)
        var errorDescription: String? { "\(provider) is out of free quota for now. \(detail)" }
    }

    /// Every provider is at its per-minute limit right now — not out for the day. Wait a minute and carry on.
    struct RateLimited: LocalizedError {
        var errorDescription: String? { "Your AI providers are at their per-minute limit — continuing in a minute." }
    }

    /// One request at a time PER PROVIDER (per-minute limits are per provider), so different providers work in parallel.
    @MainActor private static var gates: [ProviderKind: AsyncGate] = [:]
    @MainActor static func gate(for kind: ProviderKind) -> AsyncGate {
        if let g = gates[kind] { return g }
        let g = AsyncGate()
        gates[kind] = g
        return g
    }

    func complete(messages: [Message],
                  jsonMode: Bool,
                  temperature: Double = 0.4,
                  maxTokens: Int = 3000) async throws -> String {
        let gate = await Self.gate(for: provider.kind)
        await gate.acquire()
        do {
            let r = try await send(messages: messages, jsonMode: jsonMode, temperature: temperature, maxTokens: maxTokens)
            await gate.release()
            return r
        } catch {
            await gate.release()
            throw error
        }
    }

    private func encode(_ m: Message) -> [String: Any] {
        guard !m.images.isEmpty else { return ["role": m.role, "content": m.content] }
        var parts: [[String: Any]] = [["type": "text", "text": m.content]]
        for img in m.images {
            let mime = img.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            parts.append(["type": "image_url",
                          "image_url": ["url": "data:\(mime);base64,\(img.base64EncodedString())"]])
        }
        return ["role": m.role, "content": parts]
    }

    private func send(messages: [Message],
                      jsonMode: Bool,
                      temperature: Double,
                      maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GroqError(message: "Add an AI provider key in Settings (⌘,).")
        }
        guard let base = baseURL else { throw GroqError(message: "\(provider.kind.title): base URL is missing in Settings.") }

        let limit = Self.tpmLimit(for: provider)
        let inputEstimate = messages.reduce(0) { $0 + Self.estimateTokens($1.content) + 8 + $1.images.count * 1600 }
        let output = max(256, min(maxTokens, limit - inputEstimate - 150))

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(encode),
            "temperature": temperature
        ]
        if provider.kind == .groq {
            body["max_completion_tokens"] = output
            if model.hasPrefix("openai/gpt-oss") {
                // Short private reasoning leaves more of the per-minute budget for the actual answer.
                body["reasoning_effort"] = "low"
                body["include_reasoning"] = false
            }
        } else {
            body["max_tokens"] = output
        }
        var useJSON = jsonMode

        var attempt = 0
        while true {
            attempt += 1
            if useJSON { body["response_format"] = ["type": "json_object"] } else { body.removeValue(forKey: "response_format") }
            var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.timeoutInterval = 240
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if provider.kind == .openrouter {
                req.setValue("https://github.com/ExpePine/Mac-Apps", forHTTPHeaderField: "HTTP-Referer")
                req.setValue("ResumeForge", forHTTPHeaderField: "X-Title")
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let parsed = try? JSONSerialization.jsonObject(with: data)
            let obj = (parsed as? [String: Any]) ?? ((parsed as? [[String: Any]])?.first)

            if let h = http?.value(forHTTPHeaderField: "x-ratelimit-limit-tokens"), let v = Int(h), provider.kind == .groq {
                Self.setTPMLimit(v, for: provider)
            }

            if (200..<300).contains(status) {
                guard let choices = obj?["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any] else {
                    throw GroqError(message: "\(provider.kind.title) returned an unexpected reply. Try again, or pick another model in Settings.")
                }
                var content = message["content"] as? String ?? ""
                if content.isEmpty, let parts = message["content"] as? [[String: Any]] {
                    content = parts.compactMap { $0["text"] as? String }.joined()
                }
                if content.isEmpty {
                    let finish = choices.first?["finish_reason"] as? String ?? ""
                    throw GroqError(message: "\(provider.kind.title) returned an empty answer\(finish == "length" ? " (it ran out of output space)" : ""). Try again, or pick another model in Settings.")
                }
                return content
            }

            let errObj = (obj?["error"] as? [String: Any])
            let msg = (errObj?["message"] as? String) ?? String(decoding: data.prefix(600), as: UTF8.self)
            let code = (errObj?["code"].map { "\($0)" }) ?? ""

            // Some providers/models don't support JSON mode — retry once without it.
            if status == 400 && useJSON && (msg.localizedCaseInsensitiveContains("response_format") || msg.localizedCaseInsensitiveContains("json")) {
                useJSON = false
                continue
            }

            // "Request too large … Limit N, Requested M": learn the limit; caller shrinks and retries.
            if status == 413 || (status == 400 && msg.localizedCaseInsensitiveContains("context")) {
                if let lim = Self.firstInt(after: "Limit ", in: msg) {
                    Self.setTPMLimit(lim, for: provider)
                    throw RequestTooLarge(limit: lim, requested: Self.firstInt(after: "Requested ", in: msg) ?? 0)
                }
                if status == 413 {
                    let smaller = Int(Double(limit) * 0.6)
                    Self.setTPMLimit(smaller, for: provider)
                    throw RequestTooLarge(limit: smaller, requested: inputEstimate + output)
                }
            }

            if status == 429 || status == 402 || msg.contains("RESOURCE_EXHAUSTED") {
                let daily = msg.localizedCaseInsensitiveContains("per day") || msg.localizedCaseInsensitiveContains("PerDay")
                    || msg.localizedCaseInsensitiveContains("daily") || status == 402
                if daily || attempt > 3 {
                    throw QuotaExceeded(provider: provider.kind.title, detail: String(msg.prefix(300)), daily: daily)
                }
                let wait = min(75, max(2, http.flatMap { Self.retryAfter($0) } ?? Self.parseWait(msg) ?? 20))
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.waitingNotification, object: nil,
                                                    userInfo: ["message": "\(provider.kind.title) rate limit — waiting \(Int(wait.rounded(.up)))s…"])
                }
                try await Task.sleep(nanoseconds: UInt64((wait + 0.5) * 1_000_000_000))
                continue
            }
            if status >= 500 && attempt <= 2 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            throw GroqError(message: "\(provider.kind.title) API error \(status) \(code): \(msg)")
        }
    }

    private static func retryAfter(_ r: HTTPURLResponse) -> Double? {
        r.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
    }

    /// Parses "Please try again in 12.5s" / "in 1m3.2s" / "in 450ms" / Gemini's "retryDelay": "17s".
    private static func parseWait(_ msg: String) -> Double? {
        if let r = msg.range(of: #"retryDelay"?\W+([0-9\.]+)s"#, options: .regularExpression) {
            let digits = msg[r].filter { $0.isNumber || $0 == "." }
            if let v = Double(digits) { return v }
        }
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

    /// JSON-mode call. If the provider rejects the output as invalid JSON, retries once without JSON mode.
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

    /// GET /models — model IDs currently available to your key.
    func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw GroqError(message: "Enter an API key first.") }
        guard let base = baseURL else { throw GroqError(message: "Enter the base URL first.") }
        var req = URLRequest(url: base.appendingPathComponent("models"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GroqError(message: "\(provider.kind.title) error \(status): \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ids = (obj?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        return ids.sorted()
    }

    // MARK: Images

    /// Downscales an image to fit `maxSide` and re-encodes as JPEG (keeps requests small).
    static func preparedImage(_ data: Data, maxSide: CGFloat = 1600) -> Data? {
        guard let img = NSImage(data: data), let rep = img.representations.first else { return nil }
        let w = CGFloat(rep.pixelsWide > 0 ? rep.pixelsWide : Int(img.size.width))
        let h = CGFloat(rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(img.size.height))
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
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

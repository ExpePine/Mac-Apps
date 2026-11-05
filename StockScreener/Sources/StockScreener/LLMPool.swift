import SwiftUI
import AppKit

// MARK: - Several free AI keys (OpenAI-compatible chat APIs), used together
//
// Each "endpoint" = provider base URL + model + your key (key in the Keychain). Jobs such as reading results
// filings are shared out: every enabled endpoint works through the queue at the same time, each at its own pace,
// backing off for a minute when its provider says "rate limit". Your main Groq key (News & AI settings) is used too.
//
// Base URLs below are the providers' OpenAI-compatible addresses as far as I know — check them on the provider's
// docs if "Test" fails. Free limits change often and each provider has its own terms.

struct LLMEndpoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: String
    var model: String
    var enabled = true
    var gap: Double = 3            // seconds between requests (Groq's free 8k tokens / minute → ~25)
    var keychain: String { "llm.key." + id.uuidString }
}

struct LLMPreset: Identifiable {
    let name: String, base: String, model: String, gap: Double, note: String
    var id: String { name }
    static let all: [LLMPreset] = [
        LLMPreset(name: "Groq", base: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile", gap: 25,
                  note: "console.groq.com → API Keys"),
        LLMPreset(name: "Cerebras", base: "https://api.cerebras.ai/v1", model: "llama-3.3-70b", gap: 3,
                  note: "cloud.cerebras.ai → API Keys"),
        LLMPreset(name: "Google Gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-3.8-flash", gap: 5,
                  note: "aistudio.google.com → Get API key"),
        LLMPreset(name: "OpenRouter (free models)", base: "https://openrouter.ai/api/v1", model: "meta-llama/llama-3.3-70b-instruct:free", gap: 4,
                  note: "openrouter.ai → Keys · free models end in :free, ~50 requests / day"),
        LLMPreset(name: "Mistral", base: "https://api.mistral.ai/v1", model: "mistral-small-latest", gap: 3,
                  note: "console.mistral.ai → API Keys (free Experiment plan)"),
        LLMPreset(name: "GitHub Models", base: "https://models.github.ai/inference", model: "openai/gpt-4o-mini", gap: 5,
                  note: "a GitHub token with the models permission"),
        LLMPreset(name: "Other (OpenAI-compatible)", base: "https://", model: "", gap: 3, note: "any /v1/chat/completions API"),
    ]
}

@MainActor final class LLMPool: ObservableObject {
    static let shared = LLMPool()
    @Published var endpoints: [LLMEndpoint] = LLMPool.load() { didSet { save() } }
    @Published private(set) var stats: [UUID: String] = [:]         // last result per endpoint
    @Published private(set) var testing: Set<UUID> = []

    /// Your main Groq key (News & AI settings) as an extra worker.
    static let mainGroqID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var mainGroqModel = ""

    private static func load() -> [LLMEndpoint] {
        (UserDefaults.standard.data(forKey: "llm.endpoints")).flatMap { try? JSONDecoder().decode([LLMEndpoint].self, from: $0) } ?? []
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(endpoints), forKey: "llm.endpoints") }

    func key(_ e: LLMEndpoint) -> String { e.id == Self.mainGroqID ? GroqClient.apiKey : Keychain.get(e.keychain) }
    func setKey(_ k: String, for e: LLMEndpoint) { Keychain.set(k.trimmingCharacters(in: .whitespacesAndNewlines), for: e.keychain) }

    /// Everything that can take work now: your endpoints with a key, plus the main Groq key.
    var usable: [LLMEndpoint] {
        var out = endpoints.filter { $0.enabled && !key($0).isEmpty && !$0.model.isEmpty }
        if !GroqClient.apiKey.isEmpty && !mainGroqModel.isEmpty && !out.contains(where: { $0.baseURL.contains("groq.com") && $0.model == mainGroqModel }) {
            out.insert(LLMEndpoint(id: Self.mainGroqID, name: "Groq (main key)", baseURL: GroqClient.base, model: mainGroqModel, gap: 25), at: 0)
        }
        return out
    }

    func note(_ e: LLMEndpoint, _ s: String) { stats[e.id] = s }

    // MARK: Calls

    /// One chat request to one endpoint. 429 → GroqClient.RateLimited, 413 / context errors → GroqClient.TooLarge.
    func chat(_ e: LLMEndpoint, system: String, user: String, maxTokens: Int) async throws -> String {
        let k = key(e)
        guard !k.isEmpty else { throw GroqClient.Failure(message: "\(e.name): no key") }
        let base = e.baseURL.hasSuffix("/") ? String(e.baseURL.dropLast()) : e.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw GroqClient.Failure(message: "\(e.name): bad address") }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": e.model.hasPrefix("models/") ? String(e.model.dropFirst(7)) : e.model, "temperature": 0.1, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        // "thinking" models spend the token budget thinking first — ask them to keep it short so there's room for the answer
        let lm = e.model.lowercased()
        if lm.contains("gpt-oss") || lm.contains("gemini") { body["reasoning_effort"] = "low" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        // 429 = too many requests; 500/502/503/504 = the provider is busy or overloaded right now — both: rest and retry
        if status == 429 || [500, 502, 503, 504].contains(status) { throw GroqClient.RateLimited(who: e.name, code: status) }
        let low = text.lowercased()
        if status == 413 || (status == 400 && (low.contains("context length") || low.contains("too large") || low.contains("maximum context") || low.contains("reduce the length"))) {
            func num(_ key: String) -> Int? {
                guard let r = text.range(of: key + #"\s*\d+"#, options: .regularExpression) else { return nil }
                return Int(text[r].filter(\.isNumber))
            }
            throw GroqClient.TooLarge(limit: num("Limit") ?? 0, requested: num("Requested") ?? 0, message: "\(e.name): request too large")
        }
        guard (200..<300).contains(status) else { throw GroqClient.Failure(message: "\(e.name) HTTP \(status): \(text.prefix(200))") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choice = (obj?["choices"] as? [[String: Any]])?.first
        let msg = (choice?["message"] as? [String: Any])?["content"] as? String
        guard let m = msg, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let why = (choice?["finish_reason"] as? String) == "length" ? " — the model used all its tokens thinking" : ""
            throw GroqClient.Failure(message: "\(e.name): empty answer\(why)")
        }
        return m
    }

    /// First endpoint that answers (for one-off jobs like an earnings summary). TooLarge is passed on so the caller can shrink.
    func chatAny(system: String, user: String, maxTokens: Int) async throws -> String {
        let list = usable
        guard !list.isEmpty else { throw GroqClient.Failure(message: "Add an AI key first (Settings → Free AI keys)") }
        var last: Error = GroqClient.Failure(message: "no AI endpoint answered")
        var allTooLarge = true
        for e in list {
            do { let r = try await chat(e, system: system, user: user, maxTokens: maxTokens); note(e, "ok \(Date().formatted(date: .omitted, time: .shortened))"); return r }
            catch let t as GroqClient.TooLarge { last = t; note(e, "too large") }
            catch { last = error; allTooLarge = false; note(e, error.localizedDescription) }
        }
        if allTooLarge { throw last }
        throw last
    }

    func models(_ e: LLMEndpoint) async throws -> [String] {
        let base = e.baseURL.hasSuffix("/") ? String(e.baseURL.dropLast()) : e.baseURL
        guard let url = URL(string: base + "/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(key(e))", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200 else { throw GroqClient.Failure(message: "couldn't list models") }
        let o = try JSONSerialization.jsonObject(with: data)
        let arr = ((o as? [String: Any])?["data"] as? [[String: Any]]) ?? (o as? [[String: Any]]) ?? []
        return arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }.sorted()
    }

    func test(_ e: LLMEndpoint) {
        testing.insert(e.id)
        Task {
            do {
                let r = try await chat(e, system: "Reply with the single word OK.", user: "Say OK", maxTokens: 400)
                note(e, "✓ works (\(r.prefix(12)))")
            } catch let r as GroqClient.RateLimited {
                note(e, r.code == 429
                     ? "✗ HTTP 429: rate limit — or this model has no free quota on your key (common for Pro / preview models). Pick a \"flash\" model, or wait a minute."
                     : "✗ HTTP \(r.code): \(e.name) is overloaded right now — try again in a minute, or pick another model")
            } catch {
                // 404 is usually a model name the provider no longer has: pick a current text model and try again
                if error.localizedDescription.contains("HTTP 404"), let list = try? await models(e), let m = Self.bestModel(list, now: e.model) {
                    if let i = endpoints.firstIndex(where: { $0.id == e.id }) { endpoints[i].model = m }
                    var e2 = e; e2.model = m
                    do {
                        let r = try await chat(e2, system: "Reply with the single word OK.", user: "Say OK", maxTokens: 400)
                        note(e, "✓ works with \(m) (the old model wasn't found) (\(r.prefix(12)))")
                    } catch { note(e, "✗ " + error.localizedDescription) }
                } else {
                    note(e, "✗ " + error.localizedDescription)
                }
            }
            testing.remove(e.id)
        }
    }

    /// A sensible chat model from a provider's list: fast "flash"/"mini"/"small"/"70b"-type text models first.
    static func bestModel(_ list: [String], now: String) -> String? {
        let text = list.filter { m in
            let l = m.lowercased()
            return !["embed", "image", "tts", "audio", "vision", "whisper", "guard", "moderation", "aqa", "veo", "imagen", "live", "transcribe"].contains(where: l.contains)
        }
        guard !text.isEmpty, !text.contains(now) else { return nil }
        for want in ["flash", "mini", "small", "70b", "versatile", "instruct"] {
            if let m = text.filter({ $0.lowercased().contains(want) && !$0.lowercased().contains("lite") && !$0.lowercased().contains("preview") }).last { return m }
        }
        return text.first
    }
}

// MARK: - Settings

struct LLMPoolSettings: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var pool = LLMPool.shared
    @State private var keys: [UUID: String] = [:]
    @State private var models: [UUID: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add free keys from several providers — reading results filings is shared out between all of them at once. Your main Groq key (News & AI) is used too. Each provider has its own free limits and terms; one account per provider is the safe way.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach($pool.endpoints) { $e in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle("", isOn: $e.enabled).labelsHidden()
                        TextField("Name", text: $e.name).frame(width: 150)
                        TextField("Base URL", text: $e.baseURL).frame(minWidth: 220)
                        Button(role: .destructive) { Keychain.set("", for: e.keychain); pool.endpoints.removeAll { $0.id == e.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    HStack {
                        SecureField(pool.key(e).isEmpty ? "API key" : "key saved — paste to replace", text: Binding(get: { keys[e.id] ?? "" }, set: { keys[e.id] = $0 }))
                            .frame(width: 220)
                            .onSubmit { if let k = keys[e.id], !k.isEmpty { pool.setKey(k, for: e); keys[e.id] = "" } }
                        Button("Save key") { if let k = keys[e.id], !k.isEmpty { pool.setKey(k, for: e); keys[e.id] = "" } }
                        TextField("Model", text: $e.model).frame(width: 220)
                        if let ms = models[e.id], !ms.isEmpty {
                            Menu("Pick") { ForEach(ms, id: \.self) { m in Button(m) { e.model = m } } }.fixedSize()
                        } else {
                            Button("List models") { Task { models[e.id] = (try? await pool.models(e)) ?? [] } }
                        }
                        Stepper("gap \(Int(e.gap)) s", value: $e.gap, in: 0...120, step: 1).fixedSize()
                        Button("Test") { pool.test(e) }.disabled(pool.testing.contains(e.id))
                    }
                    if let s = pool.stats[e.id] { Text(s).font(.caption2).foregroundStyle(s.hasPrefix("✓") || s.hasPrefix("ok") ? Color.green : Color.orange).lineLimit(2) }
                }
                .controlSize(.small)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
            Menu {
                ForEach(LLMPreset.all) { p in
                    Button("\(p.name) — \(p.note)") {
                        pool.endpoints.append(LLMEndpoint(name: p.name, baseURL: p.base, model: p.model, gap: p.gap))
                    }
                }
            } label: { Label("Add a provider", systemImage: "plus") }
            .fixedSize()
            Text("Working now: \(pool.usable.map(\.name).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { pool.mainGroqModel = vm.settings.groqModel }
    }
}

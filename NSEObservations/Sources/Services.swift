import Foundation
import Security

// MARK: - Keychain (Groq API key never touches disk in plain text)

enum Keychain {
    static let service = "com.raj.NSEObservations"

    static func set(_ value: String, account: String) throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain error \(status)"])
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Yahoo Finance daily OHLC (unofficial endpoint; may change without notice)

enum MarketDataError: LocalizedError {
    case badSymbol(String)
    case http(Int)
    case yahoo(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badSymbol(let s): return "Invalid symbol: \(s)"
        case .http(let code): return "Yahoo Finance returned HTTP \(code)."
        case .yahoo(let msg): return "Yahoo Finance: \(msg)"
        case .empty: return "No price data returned."
        }
    }
}

struct QuoteSeries {
    var symbol: String
    var name: String?
    var currency: String?
    var candles: [Candle]
}

actor MarketDataService {
    static let shared = MarketDataService()

    private var cache: [String: (fetched: Date, series: QuoteSeries)] = [:]
    /// Symbols whose series was supplied locally (screenshot mode); never fetched from the network.
    private var pinned: Set<String> = []

    func inject(_ yahooSymbol: String, series: QuoteSeries) {
        cache[yahooSymbol] = (Date(), series)
        pinned.insert(yahooSymbol)
    }
    private let ttl: TimeInterval = 15 * 60

    /// Cached series without a network call (used when building AI context).
    func cached(_ yahooSymbol: String) -> QuoteSeries? { cache[yahooSymbol]?.series }

    /// Daily candles from `from` until now. Cached for 15 minutes per symbol.
    func series(for yahooSymbol: String, from: Date, force: Bool = false) async throws -> QuoteSeries {
        if pinned.contains(yahooSymbol), let hit = cache[yahooSymbol] { return hit.series }
        if !force, let hit = cache[yahooSymbol], Date().timeIntervalSince(hit.fetched) < ttl,
           let first = hit.series.candles.first, first.date <= from.addingTimeInterval(7 * 86_400) {
            return hit.series
        }
        let s = try await fetch(yahooSymbol, from: from)
        cache[yahooSymbol] = (Date(), s)
        return s
    }

    private func fetch(_ symbol: String, from: Date) async throws -> QuoteSeries {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "&/?#")
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw MarketDataError.badSymbol(symbol)
        }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "query1.finance.yahoo.com"
        comps.percentEncodedPath = "/v8/finance/chart/\(encoded)"
        comps.queryItems = [
            URLQueryItem(name: "period1", value: String(Int(from.timeIntervalSince1970))),
            URLQueryItem(name: "period2", value: String(Int(Date().timeIntervalSince1970) + 86_400)),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "includePrePost", value: "false")
        ]
        guard let url = comps.url else { throw MarketDataError.badSymbol(symbol) }

        var req = URLRequest(url: url, timeoutInterval: 30)
        // Yahoo tends to reject requests without a browser-like User-Agent.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let decoded = try? JSONDecoder().decode(YahooChart.self, from: data)
        if let err = decoded?.chart.error {
            throw MarketDataError.yahoo(err.description ?? err.code ?? "unknown error")
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MarketDataError.http(http.statusCode)
        }
        guard let result = decoded?.chart.result?.first,
              let ts = result.timestamp,
              let q = result.indicators.quote.first else { throw MarketDataError.empty }

        var candles: [Candle] = []
        candles.reserveCapacity(ts.count)
        for (i, t) in ts.enumerated() {
            guard let o = q.open?[safe: i] ?? nil,
                  let h = q.high?[safe: i] ?? nil,
                  let l = q.low?[safe: i] ?? nil,
                  let c = q.close?[safe: i] ?? nil else { continue }
            let v = (q.volume?[safe: i] ?? nil) ?? 0
            let day = Calendar.ist.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(t)))
            // Yahoo occasionally returns a duplicate row for today; keep the latest.
            if let last = candles.last, last.date == day { candles.removeLast() }
            candles.append(Candle(date: day, open: o, high: h, low: l, close: c, volume: v))
        }
        guard !candles.isEmpty else { throw MarketDataError.empty }
        return QuoteSeries(symbol: symbol,
                           name: result.meta.longName ?? result.meta.shortName,
                           currency: result.meta.currency,
                           candles: candles)
    }
}

private struct YahooChart: Decodable {
    struct Chart: Decodable {
        let result: [Result]?
        let error: YError?
    }
    struct YError: Decodable {
        let code: String?
        let description: String?
    }
    struct Result: Decodable {
        let meta: Meta
        let timestamp: [Int]?
        let indicators: Indicators
    }
    struct Meta: Decodable {
        let currency: String?
        let symbol: String?
        let longName: String?
        let shortName: String?
    }
    struct Indicators: Decodable {
        let quote: [Quote]
    }
    struct Quote: Decodable {
        let open: [Double?]?
        let high: [Double?]?
        let low: [Double?]?
        let close: [Double?]?
        let volume: [Double?]?
    }
    let chart: Chart
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Groq (OpenAI-compatible chat completions)

enum GroqError: LocalizedError {
    case noKey
    case api(String)
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Groq API key in Settings (⌘,)."
        case .api(let m): return "Groq: \(m)"
        case .http(let code, let body): return "Groq returned HTTP \(code). \(body)"
        case .empty: return "Groq returned an empty answer."
        }
    }
}

struct GroqMessage: Codable {
    var role: String
    var content: String
}

enum GroqClient {
    static let keyAccount = "groq-api-key"
    static let base = URL(string: "https://api.groq.com/openai/v1")!

    static var apiKey: String? { Keychain.get(account: keyAccount) }

    static func complete(messages: [GroqMessage], model: String, temperature: Double = 0.3) async throws -> String {
        guard let key = apiKey, !key.isEmpty else { throw GroqError.noKey }
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"), timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let model: String
            let messages: [GroqMessage]
            let temperature: Double
        }
        req.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages, temperature: temperature))

        let (data, resp) = try await URLSession.shared.data(for: req)
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            struct Err: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Err?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if let msg = reply?.error?.message { throw GroqError.api(msg) }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GroqError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let text = reply?.choices?.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw GroqError.empty }
        return text
    }

    /// Model ids your key can use, from GET /models.
    static func models() async throws -> [String] {
        guard let key = apiKey, !key.isEmpty else { throw GroqError.noKey }
        var req = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 30)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GroqError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        struct List: Decodable {
            struct M: Decodable { let id: String }
            let data: [M]
        }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }
}

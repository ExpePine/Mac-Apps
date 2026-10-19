import Foundation

// MARK: - Index charts (Yahoo intraday)

struct IntradaySeries {
    var times: [Date] = []
    var closes: [Double] = []
    var previousClose: Double?
    var last: Double? { closes.last }
    var change: Double? { previousClose.flatMap { p in last.map { ($0 / p - 1) * 100 } } }
}

extension YahooClient {
    /// Today's 5-minute closes for an index or stock (e.g. ^NSEI, ^BSESN). Unofficial endpoint.
    static func intraday(_ symbol: String, interval: String = "5m") async throws -> IntradaySeries {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol(symbol))?range=1d&interval=\(interval)") else {
            throw Failure(message: "Bad symbol")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(message: "HTTP \(status)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first else {
            throw Failure(message: "no data")
        }
        var out = IntradaySeries()
        let meta = result["meta"] as? [String: Any]
        out.previousClose = (meta?["chartPreviousClose"] as? Double) ?? (meta?["previousClose"] as? Double)
        let stamps = result["timestamp"] as? [Double] ?? []
        let closes = (((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first?["close"] as? [Any]) ?? []
        for (i, t) in stamps.enumerated() where i < closes.count {
            if let c = closes[i] as? Double, c > 0 { out.times.append(Date(timeIntervalSince1970: t)); out.closes.append(c) }
        }
        if out.closes.isEmpty, let p = meta?["regularMarketPrice"] as? Double { out.closes = [p]; out.times = [Date()] }
        return out
    }
}

// MARK: - News headlines

struct Headline: Codable, Hashable {
    let title: String
    let source: String
    let date: Date?
    let link: String
}

enum NewsProvider: String, Codable, CaseIterable {
    case googleNews = "Google News (RSS)"
    case yahoo = "Yahoo Finance"
}

enum NewsClient {
    /// Headlines about a stock from the last few days.
    static func headlines(symbol: String, name: String?, provider: NewsProvider, days: Int = 3) async -> [Headline] {
        switch provider {
        case .googleNews: return (try? await google(symbol: symbol, name: name, days: days)) ?? []
        case .yahoo: return (try? await yahoo(symbol: symbol)) ?? []
        }
    }

    /// news.google.com/rss/search — free, no key; Google may slow it down if polled heavily.
    static func google(symbol: String, name: String?, days: Int) async throws -> [Headline] {
        let who = (name?.isEmpty == false ? "\"\(name!)\"" : symbol)
        var comps = URLComponents(string: "https://news.google.com/rss/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: "\(who) share OR stock when:\(days)d"),
                            URLQueryItem(name: "hl", value: "en-IN"), URLQueryItem(name: "gl", value: "IN"),
                            URLQueryItem(name: "ceid", value: "IN:en")]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return RSSParser.parse(data).prefix(8).map { $0 }
    }

    /// query1.finance.yahoo.com/v1/finance/search — unofficial.
    static func yahoo(symbol: String) async throws -> [Headline] {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(YahooClient.yahooSymbol(symbol))&newsCount=8&quotesCount=0") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let news = json["news"] as? [[String: Any]] else { return [] }
        return news.compactMap { n in
            guard let t = n["title"] as? String else { return nil }
            let ts = (n["providerPublishTime"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return Headline(title: t, source: n["publisher"] as? String ?? "", date: ts, link: n["link"] as? String ?? "")
        }
    }
}

/// Minimal RSS reader: <item><title/><link/><pubDate/><source/></item>.
final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [Headline] = []
    private var field = "", title = "", link = "", date = "", source = "", inItem = false
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return f
    }()

    static func parse(_ data: Data) -> [Headline] {
        let p = RSSParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" { inItem = true; title = ""; link = ""; date = ""; source = "" }
        field = name
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch field {
        case "title": title += string
        case "link": link += string
        case "pubDate": date += string
        case "source": source += string
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" {
            inItem = false
            var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !src.isEmpty, t.hasSuffix(" - " + src) { t = String(t.dropLast(src.count + 3)) }     // Google appends " - Source"
            items.append(Headline(title: t, source: src, date: Self.dateFormat.date(from: date.trimmingCharacters(in: .whitespacesAndNewlines)),
                                  link: link.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        field = ""
    }
}

// MARK: - Groq (OpenAI-compatible chat completions)

enum GroqClient {
    static let keychainAccount = "groqApiKey"
    static let base = "https://api.groq.com/openai/v1"

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static var apiKey: String { Keychain.get(keychainAccount) }

    /// Model IDs your key can use (GET /models). Model names change over time, so the app lists them live.
    static func models() async throws -> [String] {
        guard let url = URL(string: base + "/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(message: "Groq HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    static func chat(model: String, system: String, user: String, json: Bool) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure(message: "Add your Groq API key first") }
        guard let url = URL(string: base + "/chat/completions") else { throw Failure(message: "Bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw Failure(message: "Groq rate limit — try again in a minute") }
        guard (200..<300).contains(status) else {
            throw Failure(message: "Groq HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return msg ?? ""
    }

    /// 5–10 word reasons per stock, using ONLY the given headlines.
    static func explain(model: String, stocks: [(symbol: String, move: Double, headlines: [Headline])]) async throws -> [String: String] {
        let system = """
        You explain Indian stock price moves from news headlines. For each stock, write ONE reason of 5 to 10 words \
        based ONLY on the headlines given. Do not invent facts, numbers or events. If the headlines don't explain the \
        move, answer exactly "No clear news; likely sector or technical move". Reply as JSON: {"reasons": {"SYMBOL": "reason"}}.
        """
        let df = DateFormatter(); df.dateFormat = "d MMM"
        let user = stocks.map { s in
            let lines = s.headlines.prefix(6).map { "- \($0.title)\($0.source.isEmpty ? "" : " (\($0.source)\($0.date.map { ", " + df.string(from: $0) } ?? ""))")" }
            return "\(s.symbol) rose \(String(format: "%.1f", s.move))% today. Headlines:\n" + (lines.isEmpty ? "- (none found)" : lines.joined(separator: "\n"))
        }.joined(separator: "\n\n")
        let text = try await chat(model: model, system: system, user: user, json: true)
        // tolerate code fences or extra text around the JSON
        let start = text.firstIndex(of: "{"), end = text.lastIndex(of: "}")
        guard let s = start, let e = end, s < e,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any] else {
            throw Failure(message: "Groq reply wasn't JSON")
        }
        let reasons = (obj["reasons"] as? [String: Any]) ?? obj
        var out: [String: String] = [:]
        for (k, v) in reasons { if let r = v as? String { out[k.uppercased()] = r.trimmingCharacters(in: .whitespacesAndNewlines) } }
        return out
    }
}

/// Reasons and headlines are cached per day and stock, so re-opening the screen doesn't call the APIs again.
struct NewsCache: Codable {
    var reasons: [String: String] = [:]          // "yyyy-MM-dd|SYMBOL" → reason
    var headlines: [String: [Headline]] = [:]

    private static var url: URL { AppFolders.base.appendingPathComponent("news_cache.json") }
    static func load() -> NewsCache {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(NewsCache.self, from: d) else { return NewsCache() }
        return c
    }
    func save() {
        var c = self
        if c.reasons.count > 4000 {           // keep the newest days
            let keep = Set(c.reasons.keys.sorted().suffix(3000))
            c.reasons = c.reasons.filter { keep.contains($0.key) }
            c.headlines = c.headlines.filter { keep.contains($0.key) }
        }
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: Self.url, options: .atomic) }
    }
}

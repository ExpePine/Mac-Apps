import Foundation

/// Daily closing prices from Yahoo Finance, used for Top Gainers (TG) and the monthly-gainer labels.
///
/// Source: Yahoo's public chart endpoint (query1.finance.yahoo.com/v8/finance/chart/<SYMBOL>.NS).
/// It is unofficial and undocumented, so it can change or rate-limit; failures are reported, not hidden.
struct PriceSeries: Codable {
    var days: [String]          // yyyy-MM-dd (exchange dates), oldest first
    var closes: [Double]

    /// Close on or before `day`, and its index.
    func index(onOrBefore day: String) -> Int? {
        var lo = 0, hi = days.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if days[mid] <= day { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// % change on `day` vs the previous trading day.
    func dailyChange(on day: String) -> Double? {
        guard let i = index(onOrBefore: day), i > 0, days[i] == day, closes[i - 1] > 0 else { return nil }
        return (closes[i] / closes[i - 1] - 1) * 100
    }

    /// % change over `tradingDays` ending on (or before) `day`.
    func change(over tradingDays: Int, endingOn day: String) -> Double? {
        guard let i = index(onOrBefore: day), i - tradingDays >= 0, closes[i - tradingDays] > 0 else { return nil }
        return (closes[i] / closes[i - tradingDays] - 1) * 100
    }

    /// Highest % gain reached at any close within `tradingDays` after `day` (for "did it do 30% within a month").
    func maxGain(within tradingDays: Int, after day: String) -> Double? {
        guard let i = index(onOrBefore: day), closes[i] > 0, i + 1 < closes.count else { return nil }
        let end = min(closes.count - 1, i + tradingDays)
        guard let peak = closes[(i + 1)...end].max() else { return nil }
        return (peak / closes[i] - 1) * 100
    }

    var lastDay: String? { days.last }
}

struct PriceBook: Codable {
    var fetchedAt = Date.distantPast
    var series: [String: PriceSeries] = [:]      // key: sheet symbol, upper-cased
    var failed: [String] = []                    // symbols Yahoo didn't return

    func series(for symbol: String) -> PriceSeries? {
        series[symbol.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// The most common latest trading day across symbols (Yahoo's "today").
    var latestDay: String? {
        var counts: [String: Int] = [:]
        for s in series.values { if let d = s.lastDay { counts[d, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key
    }
}

enum PriceStore {
    private static var fileURL: URL {
        HistoryStore.folder.deletingLastPathComponent().appendingPathComponent("prices.json.lzfse")
    }

    static func load() -> PriceBook {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let book = try? JSONDecoder().decode(PriceBook.self, from: raw) else { return PriceBook() }
        return book
    }

    static func save(_ book: PriceBook) {
        guard let raw = try? JSONEncoder().encode(book),
              let data = try? (raw as NSData).compressed(using: .lzfse) as Data else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum YahooClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    /// NSE symbol as Yahoo writes it, e.g. "TCS" -> "TCS.NS", "M&M" -> "M%26M.NS".
    static func yahooSymbol(_ symbol: String) -> String {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        let base = s.contains(".") || s.hasPrefix("^") ? s : s + ".NS"     // ^NSEI = Nifty 50 index
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return base.addingPercentEncoding(withAllowedCharacters: allowed) ?? base
    }

    /// Daily closes for one symbol. `range` like "3mo", "6mo", "1y".
    static func daily(_ symbol: String, range: String) async throws -> PriceSeries {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol(symbol))?range=\(range)&interval=1d") else {
            throw Failure(message: "Bad symbol")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw Failure(message: "rate-limited") }
        guard (200..<300).contains(status) else { throw Failure(message: "HTTP \(status)") }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let stamps = result["timestamp"] as? [Double],
              let indicators = result["indicators"] as? [String: Any],
              let quote = (indicators["quote"] as? [[String: Any]])?.first,
              let closes = quote["close"] as? [Any] else {
            throw Failure(message: "no data")
        }
        let meta = result["meta"] as? [String: Any]
        let gmtOffset = meta?["gmtoffset"] as? Double ?? 19_800   // IST
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: Int(gmtOffset))
        f.dateFormat = "yyyy-MM-dd"

        var days: [String] = [], values: [Double] = []
        for (i, t) in stamps.enumerated() where i < closes.count {
            guard let c = closes[i] as? Double, c > 0 else { continue }
            let d = f.string(from: Date(timeIntervalSince1970: t))
            if let last = days.last, last == d { values[values.count - 1] = c; continue }   // intraday duplicate
            days.append(d); values.append(c)
        }
        guard !days.isEmpty else { throw Failure(message: "no closes") }
        return PriceSeries(days: days, closes: values)
    }

    struct Candle: Identifiable { var id: String { day }; let day: String; let date: Date; let open, high, low, close, volume: Double }

    /// Daily candles (open / high / low / close / volume) for one symbol.
    static func candles(_ symbol: String, range: String) async throws -> [Candle] {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol(symbol))?range=\(range)&interval=1d") else {
            throw Failure(message: "Bad symbol")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(message: "HTTP \(status)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let stamps = result["timestamp"] as? [Double],
              let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first else {
            throw Failure(message: "no data")
        }
        func arr(_ k: String) -> [Any] { quote[k] as? [Any] ?? [] }
        let o = arr("open"), h = arr("high"), l = arr("low"), c = arr("close"), v = arr("volume")
        let gmtOffset = (result["meta"] as? [String: Any])?["gmtoffset"] as? Double ?? 19_800
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: Int(gmtOffset))
        f.dateFormat = "yyyy-MM-dd"
        var out: [Candle] = []
        for (i, t) in stamps.enumerated() {
            func x(_ a: [Any]) -> Double? { i < a.count ? a[i] as? Double : nil }
            guard let cl = x(c), cl > 0 else { continue }
            let date = Date(timeIntervalSince1970: t)
            let day = f.string(from: date)
            let candle = Candle(day: day, date: f.date(from: day) ?? date, open: x(o) ?? cl, high: x(h) ?? cl, low: x(l) ?? cl, close: cl, volume: x(v) ?? 0)
            if out.last?.day == day { out[out.count - 1] = candle } else { out.append(candle) }
        }
        guard !out.isEmpty else { throw Failure(message: "no candles") }
        return out
    }

    /// Fetches many symbols with a few parallel requests. Calls `progress(done, total)` on the main actor.
    static func fetchAll(_ symbols: [String], range: String, width: Int = 6,
                         progress: @escaping @MainActor (Int, Int) -> Void) async -> (PriceBook, [String]) {
        var book = PriceBook()
        var failed: [String] = []
        let unique = Array(Set(symbols.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty })).sorted()
        var done = 0
        let total = unique.count

        var index = 0
        while index < unique.count {
            let batch = Array(unique[index..<min(index + width, unique.count)])
            index += batch.count
            let results = await withTaskGroup(of: (String, PriceSeries?).self) { group -> [(String, PriceSeries?)] in
                for symbol in batch {
                    group.addTask {
                        for attempt in 0..<3 {
                            do {
                                return (symbol, try await daily(symbol, range: range))
                            } catch let e as Failure where e.message == "rate-limited" {
                                try? await Task.sleep(nanoseconds: UInt64(3 + attempt * 4) * 1_000_000_000)
                            } catch {
                                return (symbol, nil)
                            }
                        }
                        return (symbol, nil)
                    }
                }
                var out: [(String, PriceSeries?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (symbol, series) in results {
                if let series { book.series[symbol] = series } else { failed.append(symbol) }
            }
            done += batch.count
            let d = done
            await progress(d, total)
            if Task.isCancelled { break }
        }
        book.fetchedAt = Date()
        book.failed = failed
        return (book, failed)
    }
}

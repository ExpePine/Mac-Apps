import Foundation

// MARK: - Bulk / block deals (NSE)
//
// Sources (both unofficial, may change or block):
//   • History: https://www.nseindia.com/api/historical/bulk-deals?from=dd-MM-yyyy&to=dd-MM-yyyy (and block-deals).
//     NSE's site usually wants browser-like headers and the cookies it sets on its own pages, so the client first
//     opens the bulk-deals report page, then calls the API with the same cookie jar.
//   • Today only: https://nsearchives.nseindia.com/content/equities/bulk.csv (and block.csv).

struct BulkDeal: Codable, Hashable, Identifiable {
    var id: String { "\(kind)|\(day)|\(symbol)|\(client)|\(side)|\(Int(qty))" }
    let day: String          // yyyy-MM-dd
    let symbol: String
    let client: String
    let side: String         // BUY / SELL
    let qty: Double
    let price: Double
    let kind: String         // Bulk / Block

    var isBuy: Bool { side.uppercased().hasPrefix("B") }
    var valueCr: Double { qty * price / 1e7 }
}

enum NSEDealsClient {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = HTTPCookieStorage()
        c.httpCookieAcceptPolicy = .always
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()
    private static var warmedAt = Date.distantPast
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func request(_ url: URL, json: Bool) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.setValue(json ? "application/json, text/plain, */*" : "text/html,*/*", forHTTPHeaderField: "Accept")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("https://www.nseindia.com/report-detail/display-bulk-and-block-deals", forHTTPHeaderField: "Referer")
        return r
    }

    /// Opens NSE's report page once in a while so its cookies are set.
    private static func warmUp() async {
        guard Date().timeIntervalSince(warmedAt) > 600 else { return }
        for u in ["https://www.nseindia.com/", "https://www.nseindia.com/report-detail/display-bulk-and-block-deals"] {
            if let url = URL(string: u) { _ = try? await session.data(for: request(url, json: false)) }
        }
        warmedAt = Date()
    }

    private static let api: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "dd-MM-yyyy"; return f }()

    /// Deals between two days (inclusive), from NSE's history API.
    static func history(kind: String, from: Date, to: Date) async throws -> [BulkDeal] {
        await warmUp()
        let path = kind == "Block" ? "block-deals" : "bulk-deals"
        guard let url = URL(string: "https://www.nseindia.com/api/historical/\(path)?from=\(api.string(from: from))&to=\(api.string(from: to))") else { return [] }
        var (data, resp) = try await session.data(for: request(url, json: true))
        var status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {          // cookies expired: once more after a fresh warm-up
            warmedAt = .distantPast; await warmUp()
            (data, resp) = try await session.data(for: request(url, json: true))
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard (200..<300).contains(status) else { throw Failure(message: "NSE HTTP \(status)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw Failure(message: "NSE sent no JSON (blocked?)") }
        let rows = (obj as? [String: Any])?["data"] as? [[String: Any]] ?? (obj as? [[String: Any]]) ?? []
        return rows.compactMap { parse($0, kind: kind) }
    }

    /// Today's deals from the archive CSV (works without cookies).
    static func today(kind: String) async throws -> [BulkDeal] {
        guard let url = URL(string: "https://nsearchives.nseindia.com/content/equities/\(kind == "Block" ? "block" : "bulk").csv") else { return [] }
        let (data, resp) = try await session.data(for: request(url, json: false))
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200, let text = String(data: data, encoding: .utf8) else { throw Failure(message: "archive unavailable") }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let head = lines.first else { return [] }
        let h = CSVLine.split(head).map { $0.uppercased() }
        return lines.dropFirst().compactMap { line in
            let c = CSVLine.split(line)
            var d: [String: Any] = [:]
            for (i, k) in h.enumerated() where i < c.count { d[k] = c[i] }
            return parse(d, kind: kind)
        }
    }

    private static let dayOut: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let dayIns: [DateFormatter] = ["dd-MMM-yyyy", "dd-MM-yyyy", "yyyy-MM-dd", "dd MMM yyyy", "d-MMM-yyyy"].map {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = $0; return f
    }
    static func day(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for f in dayIns { if let d = f.date(from: t) { return dayOut.string(from: d) } }
        return nil
    }

    /// Reads a row by key names (NSE's field names vary between the API and the CSV).
    static func parse(_ d: [String: Any], kind: String) -> BulkDeal? {
        func find(_ needles: [String], not: [String] = []) -> String? {
            for n in needles {
                if let k = d.keys.first(where: { key in let u = key.uppercased(); return u.contains(n) && !not.contains { u.contains($0) } }) {
                    if let s = d[k] as? String { return s }
                    if let v = d[k] as? NSNumber { return v.stringValue }
                }
            }
            return nil
        }
        func num(_ s: String?) -> Double? { s.flatMap { Double($0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) } }
        guard let ds = find(["DATE"]), let day = day(ds),
              let sym = find(["SYMBOL"])?.trimmingCharacters(in: .whitespaces).uppercased(), !sym.isEmpty,
              let qty = num(find(["QTY", "QUANTITY"])) else { return nil }
        let side = (find(["BUY_SELL", "BUY/SELL", "BUYSELL", "BUY"]) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let price = num(find(["WATP", "PRICE", "TP"], not: ["QTY"])) ?? 0
        let client = (find(["CLIENT"]) ?? "").trimmingCharacters(in: .whitespaces)
        return BulkDeal(day: day, symbol: sym, client: client, side: side.hasPrefix("S") ? "SELL" : "BUY", qty: qty, price: price, kind: kind)
    }
}

/// Minimal CSV splitter (quotes allowed).
enum CSVLine {
    static func split(_ line: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}

@MainActor final class DealsCenter: ObservableObject {
    static let shared = DealsCenter()

    @Published private(set) var deals: [BulkDeal] = []
    @Published private(set) var bySymbol: [String: [BulkDeal]] = [:]
    @Published private(set) var busy = false
    @Published var status: String?
    @Published private(set) var revision = 0
    private var loaded = false
    private var coveredFrom = ""            // oldest day fetched from history
    private var coveredTo = ""

    private static var url: URL { AppFolders.base.appendingPathComponent("bulk_deals.json.lzfse") }
    private struct File: Codable { var deals: [BulkDeal]; var from: String; var to: String }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: Self.url), let raw = try? (d as NSData).decompressed(using: .lzfse) as Data,
           let f = try? JSONDecoder().decode(File.self, from: raw) {
            coveredFrom = f.from; coveredTo = f.to
            set(f.deals)
        }
    }

    private func set(_ list: [BulkDeal]) {
        var seen = Set<String>()
        deals = list.filter { seen.insert($0.id).inserted }.sorted { $0.day < $1.day }
        bySymbol = Dictionary(grouping: deals, by: \.symbol)
        revision &+= 1
    }

    private func save() {
        let f = File(deals: deals, from: coveredFrom, to: coveredTo)
        guard let raw = try? JSONEncoder().encode(f), let c = try? (raw as NSData).compressed(using: .lzfse) as Data else { return }
        try? c.write(to: Self.url, options: .atomic)
    }

    var summary: String {
        guard let a = deals.first?.day, let b = deals.last?.day else { return "No bulk / block deals downloaded yet" }
        return "\(deals.count) deals · \(a) → \(b)"
    }

    /// Fetches `days` back (first time), then only the new days; once an hour at most.
    func update(days: Int = 730, force: Bool = false) {
        loadIfNeeded()
        guard !busy else { return }
        let last = UserDefaults.standard.object(forKey: "deals.updatedAt") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 3600 else { return }
        busy = true
        status = "Bulk / block deals: contacting NSE…"
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let start = cal.date(byAdding: .day, value: -days, to: today)!
        let wantFrom = Self.ymd(start)
        Task {
            var all = deals
            var fails: [String] = []
            // ranges to fetch: [start … coveredFrom) and (coveredTo-3 … today]
            var ranges: [(Date, Date)] = []
            let haveFrom = Self.date(coveredFrom), haveTo = Self.date(coveredTo)
            if haveFrom != nil, let ht = haveTo, coveredFrom <= wantFrom {
                ranges.append((cal.date(byAdding: .day, value: -3, to: ht)!, today))
            } else if let hf = haveFrom, let ht = haveTo {
                ranges.append((start, hf)); ranges.append((cal.date(byAdding: .day, value: -3, to: ht)!, today))
            } else { ranges.append((start, today)) }
            var got = 0
            for (a, b) in ranges {
                var s = a
                while s < b {
                    let e = min(b, cal.date(byAdding: .day, value: 30, to: s)!)
                    for kind in ["Bulk", "Block"] {
                        do { let d = try await NSEDealsClient.history(kind: kind, from: s, to: e); all += d; got += d.count }
                        catch { fails.append("\(kind) \(Self.ymd(s)): \(error.localizedDescription)") }
                    }
                    status = "Bulk / block deals: \(Self.ymd(e)) · \(got) found"
                    s = cal.date(byAdding: .day, value: 1, to: e)!
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            // today's archive files (also fill in if the history API is blocked)
            for kind in ["Bulk", "Block"] { if let d = try? await NSEDealsClient.today(kind: kind) { all += d; got += d.count } }
            let historyOK = fails.count < max(1, ranges.count * 2)
            if historyOK {
                if coveredFrom.isEmpty || wantFrom < coveredFrom { coveredFrom = wantFrom }
                coveredTo = Self.ymd(today)
            }
            set(all)
            save()
            UserDefaults.standard.set(Date(), forKey: "deals.updatedAt")
            busy = false
            status = fails.isEmpty ? nil
                : (historyOK ? "Some deal requests failed (\(fails.count)) — retried next time."
                             : "NSE blocked the deals history (\(fails.first ?? "")) — only today's archive files were read. Try again later.")
        }
    }

    static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    static func date(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"
        return s.isEmpty ? nil : f.date(from: s)
    }
}

// MARK: - News history per stock, with 3–4 word labels from Groq

struct NewsDay: Codable, Identifiable {
    var id: String { day }
    let day: String
    var headlines: [Headline]
    var label: String?               // Groq's 3–4 words (nil = not labelled yet)
    var labelIsGuess = false         // true = first words of the top headline (no Groq)
    var category: String?            // an event name from the code dictionary (e.g. "Dividend"), "Other", or nil
    var impact: Int?                 // 0 = just a mention … 3 = major effect on revenue / profit / market position
    var impactOn: String?            // "revenue", "profit", "market position" …
    var impactGuess = false          // true = from keywords, not Groq
}

/// How much a news day matters to the business (Groq's rating), and the chart's minimum.
enum NewsImpact {
    static let names = ["0 · Mention only", "1 · Minor", "2 · Material", "3 · Major"]
    static let short = ["mention", "minor", "material", "major"]
    /// Days below this are hidden on the charts and in the list (default: Material).
    static var minimum: Int { UserDefaults.standard.object(forKey: "news.minImpact") as? Int ?? 2 }
    static func dots(_ v: Int?) -> String { guard let v else { return "?" }; return String(repeating: "●", count: v) + String(repeating: "○", count: max(0, 3 - v)) }
    /// Keyword fallback: a known business event = material, anything else = mention.
    static func guess(category: String?) -> Int {
        switch category {
        case nil, "Other"?: return 0
        case "Rating change"?, "Management change"?, "Product / launch"?: return 1
        default: return 2
        }
    }
}

// MARK: - Event dictionary: news category → letters on the chart (editable)

struct EventCode: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String          // e.g. "Dividend"
    var code: String          // e.g. "D"
    var keywords: String      // comma-separated words used when Groq isn't available

    var words: [String] { keywords.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

enum EventCodes {
    static let key = "news.eventCodes"
    static let defaults: [EventCode] = [
        EventCode(name: "Dividend", code: "D", keywords: "dividend, record date"),
        EventCode(name: "Results", code: "R", keywords: "results, q1, q2, q3, q4, quarterly, profit, net loss, revenue, earnings"),
        EventCode(name: "Order win", code: "O", keywords: "order, contract, bags, wins, letter of award"),
        EventCode(name: "Factory fire", code: "FF", keywords: "fire, blaze, explosion, blast"),
        EventCode(name: "Rating change", code: "RT", keywords: "upgrade, downgrade, rating, target price"),
        EventCode(name: "Stake sale", code: "SS", keywords: "stake sale, sells stake, offloads, ofs, offer for sale"),
        EventCode(name: "Stake buy", code: "SB", keywords: "buys stake, acquires stake, raises stake, increases stake"),
        EventCode(name: "Acquisition / merger", code: "A", keywords: "acquire, acquisition, merger, amalgamation, takeover"),
        EventCode(name: "Bonus / split", code: "BS", keywords: "bonus, split, sub-division"),
        EventCode(name: "Buyback", code: "BB", keywords: "buyback, buy-back"),
        EventCode(name: "Fund raise", code: "FR", keywords: "qip, preferential, rights issue, fund raise, ncd, raises"),
        EventCode(name: "Expansion / new plant", code: "EX", keywords: "expansion, new plant, capacity, capex, commissioning, facility"),
        EventCode(name: "Management change", code: "MC", keywords: "ceo, md, resigns, appoints, appointed, cfo, director"),
        EventCode(name: "Regulatory / legal", code: "L", keywords: "sebi, penalty, court, nclt, probe, raid, notice, gst, tax demand"),
        EventCode(name: "Product / launch", code: "P", keywords: "launch, launches, unveils, approval, usfda"),
        EventCode(name: "Block / bulk deal", code: "BD", keywords: "block deal, bulk deal"),
        EventCode(name: "Other", code: "N", keywords: ""),
    ]
    static var all: [EventCode] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([EventCode].self, from: d), !l.isEmpty else { return defaults }
            return l
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
    /// Letters for a category (unknown → its first letter, none → "N").
    static func code(for category: String?, in list: [EventCode] = all) -> String {
        guard let c = category?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return list.first { $0.name == "Other" }?.code ?? "N" }
        if let e = list.first(where: { $0.name.caseInsensitiveCompare(c) == .orderedSame }) { return e.code }
        return String(c.prefix(1)).uppercased()
    }
    /// Keyword match on the headlines (used without Groq).
    static func guess(_ headlines: [Headline], in list: [EventCode] = all) -> String {
        let text = headlines.prefix(4).map(\.title).joined(separator: " ").lowercased()
        for e in list where !e.words.isEmpty { if e.words.contains(where: { text.contains($0) }) { return e.name } }
        return "Other"
    }
}

struct NewsHistory: Codable {
    var symbol: String
    var days: [String: NewsDay] = [:]
    var monthsFetched: [String: Date] = [:]     // "yyyy-MM" → when fetched
}

@MainActor final class NewsTimeline: ObservableObject {
    static let shared = NewsTimeline()
    @Published private(set) var revision = 0
    @Published private(set) var busy: String?          // symbol being fetched
    @Published var status: String?
    private var cache: [String: NewsHistory] = [:]

    private static func url(_ s: String) -> URL { AppFolders.folder("news_history").appendingPathComponent("\(s).json") }

    func history(_ symbol: String) -> NewsHistory? {
        let s = symbol.uppercased()
        if let h = cache[s] { return h }
        if let d = try? Data(contentsOf: Self.url(s)), let h = try? JSONDecoder().decode(NewsHistory.self, from: d) { cache[s] = h; return h }
        return nil
    }

    private func store(_ h: NewsHistory) {
        cache[h.symbol] = h
        if let d = try? JSONEncoder().encode(h) { try? d.write(to: Self.url(h.symbol), options: .atomic) }
        revision &+= 1
    }

    /// Re-runs the labels and categories for one stock (e.g. after editing the event dictionary).
    func reclassify(symbol: String, company: String?, groqModel: String) {
        let sym = symbol.uppercased()
        guard busy == nil, var h = history(sym) else { return }
        for k in h.days.keys { h.days[k]?.category = nil; h.days[k]?.impact = nil }
        busy = sym
        Task {
            await label(&h, company: company ?? sym, model: groqModel)
            store(h)
            busy = nil
            status = "News: \(sym) re-classified"
        }
    }

    /// Bumps the revision so charts redraw (event letters changed).
    func touch() { revision &+= 1 }

    /// News days for the chart, oldest first.
    func days(_ symbol: String) -> [NewsDay] { (history(symbol)?.days.values.map { $0 } ?? []).sorted { $0.day < $1.day } }

    /// Downloads headlines month by month (Google News RSS with after:/before:), then labels each day with Groq.
    func fetch(symbol: String, company: String?, months: Int, groqModel: String, force: Bool = false) {
        let sym = symbol.uppercased()
        guard busy == nil, !sym.isEmpty else { return }
        busy = sym
        status = "News: \(sym)…"
        Task {
            var h = history(sym) ?? NewsHistory(symbol: sym)
            let cal = Calendar(identifier: .gregorian)
            let now = Date()
            let ist = TimeZone(identifier: "Asia/Kolkata")!
            let fm = DateFormatter(); fm.locale = Locale(identifier: "en_US_POSIX"); fm.timeZone = ist; fm.dateFormat = "yyyy-MM"
            let fd = DateFormatter(); fd.locale = Locale(identifier: "en_US_POSIX"); fd.timeZone = ist; fd.dateFormat = "yyyy-MM-dd"
            var newItems = 0
            for k in 0..<max(1, months) {
                guard let mDate = cal.date(byAdding: .month, value: -k, to: now) else { continue }
                let key = fm.string(from: mDate)
                let isCurrent = k == 0
                if !force, let t = h.monthsFetched[key], !isCurrent || now.timeIntervalSince(t) < 6 * 3600 { continue }
                let start = key + "-01"
                let next = fm.string(from: cal.date(byAdding: .month, value: 1, to: fd.date(from: start)!)!) + "-01"
                status = "News: \(sym) · \(key)…"
                let items = await Self.google(sym, company: company, after: start, before: next)
                for it in items {
                    guard let d = it.date else { continue }
                    let day = fd.string(from: d)
                    var nd = h.days[day] ?? NewsDay(day: day, headlines: [])
                    if !nd.headlines.contains(where: { $0.title == it.title }) {
                        nd.headlines.append(it); newItems += 1
                        if nd.labelIsGuess || nd.headlines.count <= 3 { nd.label = nil }     // re-label with the new headline
                    }
                    h.days[day] = nd
                }
                h.monthsFetched[key] = now
                try? await Task.sleep(nanoseconds: 600_000_000)       // be gentle with Google
            }
            store(h)
            await label(&h, company: company ?? sym, model: groqModel)
            store(h)
            busy = nil
            let n = h.days.count
            status = "News: \(sym) — \(n) day\(n == 1 ? "" : "s") with headlines (\(newItems) new)"
        }
    }

    /// Google News RSS for one date window. Free, no key, unofficial; at most ~100 items per request.
    static func google(_ symbol: String, company: String?, after: String, before: String) async -> [Headline] {
        let who = company.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : "\"\($0)\"" } ?? "\"\(symbol)\""
        var comps = URLComponents(string: "https://news.google.com/rss/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: "\(who) (share OR stock OR NSE OR results OR order) after:\(after) before:\(before)"),
                            URLQueryItem(name: "hl", value: "en-IN"), URLQueryItem(name: "gl", value: "IN"), URLQueryItem(name: "ceid", value: "IN:en")]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200 else { return [] }
        return RSSParser.parse(data)
    }

    /// 3–4 word label per day: Groq when a key + model are set, otherwise the top headline's first words.
    private func label(_ h: inout NewsHistory, company: String, model: String) async {
        let todo = h.days.values.filter { $0.label == nil || $0.labelIsGuess || $0.category == nil || $0.impact == nil || $0.impactGuess }.map(\.day).sorted()
        let codes = EventCodes.all
        let names = codes.map(\.name).joined(separator: ", ")
        guard !todo.isEmpty else { return }
        let canGroq = !model.isEmpty && !GroqClient.apiKey.isEmpty
        if canGroq {
            for chunk in stride(from: 0, to: todo.count, by: 40).map({ Array(todo[$0..<min($0 + 40, todo.count)]) }) {
                status = "News: labelling \(h.symbol) with Groq… (\(chunk.first ?? "") →)"
                let lines = chunk.compactMap { d -> String? in
                    guard let nd = h.days[d] else { return nil }
                    return d + ": " + nd.headlines.prefix(4).map(\.title).joined(separator: " | ")
                }.joined(separator: "\n")
                let system = """
                You label news days on a stock chart for \(company) (NSE: \(h.symbol)). For each date: \
                (1) a 3–4 word label that says what the news was about (e.g. "Q2 profit jumps", "Big order win", "Promoter stake sale"); \
                (2) the ONE best category from this list: \(names); \
                (3) "impact": how much this news can change \(company)'s OWN revenue, profit or market position — \
                0 = only a mention (market wrap, list of stocks, the company commenting on / rating others, opinion, share-price chatter, \
                target-price notes), 1 = minor (small order, routine announcement, small management change), \
                2 = material (results, sizeable orders or contracts, capacity / plant news, fire or shutdown, regulatory action, \
                acquisition, fund raise, dividend / bonus / buyback, big stake change), 3 = major (very large relative to the company: \
                transformational deal, plant loss, ban, guidance shock, record results); \
                (4) "on": which of revenue / profit / market position it affects most (or "none"). \
                Use only the headlines given; when unsure, rate lower. If they are not about this company itself, use the label \
                "Not company news", category "Other", impact 0. No advice, no hype. \
                Reply as JSON: {"days": {"yyyy-MM-dd": {"label": "…", "category": "…", "impact": 0, "on": "…"}}}.
                """
                if let text = try? await GroqClient.chat(model: model, system: system, user: lines, json: true),
                   let d = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let labels = (j["days"] as? [String: Any]) ?? (j["labels"] as? [String: Any]) {
                    for (day, v) in labels {
                        guard var nd = h.days[day] else { continue }
                        let lab = (v as? [String: Any])?["label"] as? String ?? (v as? String)
                        let cat = (v as? [String: Any])?["category"] as? String
                        if let s = lab { nd.label = String(s.split(separator: " ").prefix(5).joined(separator: " ").prefix(40)); nd.labelIsGuess = false }
                        nd.category = cat.map { c in codes.first { $0.name.caseInsensitiveCompare(c) == .orderedSame }?.name ?? c } ?? EventCodes.guess(nd.headlines, in: codes)
                        let obj = v as? [String: Any]
                        let imp = (obj?["impact"] as? Int) ?? (obj?["impact"] as? Double).map { Int($0) } ?? (obj?["impact"] as? String).flatMap { Int($0) }
                        if let imp { nd.impact = max(0, min(3, imp)); nd.impactGuess = false } else { nd.impact = NewsImpact.guess(category: nd.category); nd.impactGuess = true }
                        if nd.label == "Not company news" { nd.impact = 0 }
                        if let on = obj?["on"] as? String, on.lowercased() != "none" { nd.impactOn = on.lowercased() } else { nd.impactOn = nil }
                        h.days[day] = nd
                    }
                }
            }
        }
        for d in todo where h.days[d]?.label == nil {
            guard var nd = h.days[d], let t = nd.headlines.first?.title else { continue }
            nd.label = t.split(separator: " ").prefix(4).joined(separator: " ")
            nd.labelIsGuess = true
            h.days[d] = nd
        }
        for d in todo where h.days[d]?.category == nil {
            guard var nd = h.days[d] else { continue }
            nd.category = EventCodes.guess(nd.headlines, in: codes)
            h.days[d] = nd
        }
        for d in todo where h.days[d]?.impact == nil {
            guard var nd = h.days[d] else { continue }
            nd.impact = NewsImpact.guess(category: nd.category); nd.impactGuess = true
            h.days[d] = nd
        }
        if !canGroq { status = "News labels are the first words of each headline — add a Groq key + model (Daily Gainers → … → News & AI settings) for 3–4 word summaries." }
    }
}

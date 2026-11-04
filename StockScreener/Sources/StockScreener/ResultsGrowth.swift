import SwiftUI
import AppKit

// MARK: - Revenue / profit growth from the latest results, filled in automatically
//
// When a stock's results have just come out (EARNINGS 0…3: today, yesterday, or over a weekend / holiday),
// the app reads the results filing from NSE (see EarningsSummary.swift), asks Groq for the raw numbers only
// (revenue from operations and net profit: this quarter, a year ago, last quarter) and works out the growth itself.
// Columns: REV_YOY, PAT_YOY (and REV_QOQ, PAT_QOQ) — kept until the next results.
// One stock at a time with a pause between, so a free Groq key's per-minute limit isn't hit.

struct ResultsGrowth: Codable {
    let symbol: String
    let resultsDay: String          // filing date (yyyy-MM-dd)
    let period: String
    let basis: String               // consolidated / standalone
    let unit: String
    let rev: [Double?]              // current, year ago, previous quarter
    let pat: [Double?]
    let made: Date
    var source: String? = nil       // "NSE" (results comparison) or "Groq" (read from the filing)

    static func growth(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, b > 0 else { return nil }          // no % from a loss or zero base
        return (a / b - 1) * 100
    }
    var revYoY: Double? { Self.growth(rev[0], rev[1]) }
    var revQoQ: Double? { Self.growth(rev[0], rev[2]) }
    var patYoY: Double? { Self.growth(pat[0], pat[1]) }
    var patQoQ: Double? { Self.growth(pat[0], pat[2]) }
}

@MainActor final class ResultsGrowthCenter: ObservableObject {
    static let shared = ResultsGrowthCenter()
    @Published private(set) var bySymbol: [String: ResultsGrowth] = [:]
    @Published private(set) var queue: [String] = []
    @Published private(set) var currentSymbol: String?
    @Published var status: String?
    var onReload: (() -> Void)?
    var model = ""

    var auto: Bool { UserDefaults.standard.object(forKey: "growth.auto") as? Bool ?? true }
    /// Which EARNINGS values start a fetch (days since results), e.g. [1] or [0, 1, 2]. Default 0…3.
    nonisolated static var days: Set<Int> {
        let s = UserDefaults.standard.string(forKey: "growth.days") ?? "0,1,2,3"
        return Set(s.split(separator: ",").compactMap { Int($0) })
    }
    func setDays(_ d: Set<Int>) {
        UserDefaults.standard.set(d.sorted().map(String.init).joined(separator: ","), forKey: "growth.days")
        objectWillChange.send()
        onReload?()                     // re-check the Filter now
    }
    private var tried: [String: (count: Int, at: Date)] = [:]   // "SYM|earnDate" → attempts (filing may not be up yet)
    private var running = false

    private static var url: URL { AppFolders.base.appendingPathComponent("results_growth.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let a = try? JSONDecoder().decode([ResultsGrowth].self, from: d) {
            bySymbol = Dictionary(a.map { ($0.symbol, $0) }, uniquingKeysWith: { x, y in x.resultsDay >= y.resultsDay ? x : y })
        }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(Array(bySymbol.values)) { try? d.write(to: Self.url, options: .atomic) }
    }

    /// Have we got the quarter that results meeting was about? (Quarter ends ≤ ~75 days before the meeting;
    /// NSE numbers are dated by quarter end, Groq ones by filing day — both pass.)
    func has(_ sym: String, since earnDate: String) -> Bool {
        guard let g = bySymbol[sym] else { return false }
        return g.resultsDay >= Self.shift(earnDate, days: -75)
    }

    /// Stocks whose results just came out (from the EARNINGS column); skips ones done or tried recently.
    func consider(_ due: [(symbol: String, earnDate: String)], model: String) {
        guard auto else { return }
        self.model = model
        for d in due {
            let s = d.symbol.uppercased()
            if has(s, since: d.earnDate) || queue.contains(s) || currentSymbol == s { continue }
            let k = s + "|" + d.earnDate
            if let t = tried[k], t.count >= 4 || Date().timeIntervalSince(t.at) < 3 * 3600 { continue }
            queue.append(s)
        }
        pump()
    }

    /// By hand (right-click): fetch now even if the column already has it.
    func request(_ symbols: [String], model: String) {
        self.model = model
        for s in symbols.map({ $0.uppercased() }) where !queue.contains(s) && currentSymbol != s { queue.insert(s, at: 0) }
        pump()
    }

    /// Groq is only a fallback for stocks whose numbers NSE's comparison data doesn't have.
    var groqFallback: Bool { UserDefaults.standard.object(forKey: "growth.groqFallback") as? Bool ?? false }
    @Published private(set) var lastNSEReply = ""
    private var groqQueue: [String] = []

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        Task {
            // 1) NSE's own results-comparison numbers: free, ~1 s a stock, 4 at a time
            while !queue.isEmpty {
                let batch = Array(queue.prefix(4)); queue.removeFirst(batch.count)
                currentSymbol = batch.first
                status = "NSE numbers: \(batch.joined(separator: ", "))… (\(queue.count) waiting)"
                let results = await withTaskGroup(of: (String, Result<ResultsGrowth, Error>, String).self) { g in
                    for s in batch {
                        g.addTask { @MainActor in
                            do { let r = try await NSEResults.growth(s); return (s, .success(r.growth), r.raw) }
                            catch { return (s, .failure(error), (error as? NSEResults.NoData)?.raw ?? "") }
                        }
                    }
                    var out: [(String, Result<ResultsGrowth, Error>, String)] = []
                    for await x in g { out.append(x) }
                    return out
                }
                for (s, r, raw) in results {
                    if !raw.isEmpty { lastNSEReply = "\(s): " + raw }
                    let earn = EarningsCenter.shared.value(s, on: EarningsMath.iso.string(from: Date()))?.date ?? ""
                    switch r {
                    case .success(let g):
                        if (bySymbol[s]?.resultsDay ?? "") <= g.resultsDay { bySymbol[s] = g }
                        // results just announced but NSE's table still ends at the older quarter → try again in a few hours
                        if !earn.isEmpty && !has(s, since: earn) { markTried(s, earn, "NSE hasn't added the latest quarter yet — will retry") }
                    case .failure(let e):
                        if groqFallback && !GroqClient.apiKey.isEmpty { groqQueue.append(s) } else { markTried(s, earn, e.localizedDescription) }
                    }
                }
                save(); onReload?()
            }
            // 2) Groq reads the filing (slow on a free key) — only if you turned it on
            while !groqQueue.isEmpty {
                let s = groqQueue.removeFirst()
                currentSymbol = s
                status = "Groq reading \(s)'s filing… (\(groqQueue.count) waiting)"
                let earn = EarningsCenter.shared.value(s, on: EarningsMath.iso.string(from: Date()))?.date ?? ""
                do {
                    let g = try await Self.extract(s, notBefore: earn.isEmpty ? nil : Self.shift(earn, days: -2), model: model)
                    bySymbol[s] = g; save(); onReload?()
                } catch is GroqClient.RateLimited {
                    groqQueue.insert(s, at: 0)
                    status = "Groq per-minute limit — waiting a minute…"
                    try? await Task.sleep(nanoseconds: 65_000_000_000)
                    continue
                } catch {
                    markTried(s, earn, error.localizedDescription)
                }
                if !groqQueue.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000_000) }
            }
            currentSymbol = nil
            if status?.hasPrefix("NSE numbers") == true || status?.hasPrefix("Groq reading") == true { status = nil }
            running = false
            if !queue.isEmpty { pump() }
        }
    }

    private func markTried(_ s: String, _ earn: String, _ why: String) {
        let k = s + "|" + earn
        let t = tried[k]
        tried[k] = ((t?.count ?? 0) + 1, Date())
        status = "\(s): \(why)"
    }

    /// Every stock in the list that has no numbers yet (NSE, ~1 s each).
    func fillMissing(_ symbols: [String]) {
        for s in symbols.map({ $0.uppercased() }) where bySymbol[s] == nil && !queue.contains(s) { queue.append(s) }
        pump()
    }

    // MARK: Extraction

    static let system = """
    Extract figures from an Indian listed company's quarterly results filing. Use ONLY the text given; never estimate. \
    Prefer CONSOLIDATED figures if both consolidated and standalone are present. Use the latest QUARTER (3 months) column, \
    not half-year, nine-month or full-year columns. \
    revenue = "Revenue from operations" (not total income). net_profit = net profit / profit for the period after tax \
    (use "attributable to owners" if given). Numbers as plain numbers (no commas), losses negative, null if not in the text. \
    Reply as JSON: {"period": "quarter ended …", "basis": "consolidated" or "standalone", "unit": "as written, e.g. ₹ crore", \
    "revenue": {"current": n, "year_ago": n, "prev_quarter": n}, "net_profit": {"current": n, "year_ago": n, "prev_quarter": n}}
    """

    static func extract(_ sym: String, notBefore: String?, model: String) async throws -> ResultsGrowth {
        let ann = try await EarningsSummaryCenter.announcements(sym)
        var pool = ann
        if let nb = notBefore { pool = ann.filter { EarningsMath.iso.string(from: $0.date) >= nb } }
        guard let r = EarningsSummaryCenter.pickResults(pool) else {
            throw GroqClient.Failure(message: "results filing not on NSE yet")
        }
        let full = try await EarningsSummaryCenter.pdfText(r.file, limit: 120_000)
        guard !full.isEmpty else { throw GroqClient.Failure(message: "results PDF has no readable text") }
        var budget = 9_000
        var reply = ""
        for attempt in 0..<4 {
            let user = "Company: \(sym)\n=== RESULTS FILING (key lines) ===\n" + EarningsSummaryCenter.focus(full, limit: budget)
            do { reply = try await GroqClient.chat(model: model, system: system, user: user, json: true, maxTokens: 900); break }
            catch let e as GroqClient.TooLarge {
                guard attempt < 3 else { throw e }
                let f = e.requested > 0 && e.limit > 0 ? Double(e.limit - 1_100) / Double(e.requested - 900) * 0.85 : 0.6
                budget = max(2_000, Int(Double(budget) * min(0.85, max(0.3, f))))
            }
        }
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"), s < e,
              let o = try? JSONSerialization.jsonObject(with: Data(reply[s...e].utf8)) as? [String: Any] else {
            throw GroqClient.Failure(message: "Groq reply wasn't JSON")
        }
        func nums(_ k: String) -> [Double?] {
            let d = o[k] as? [String: Any] ?? [:]
            return ["current", "year_ago", "prev_quarter"].map { key in
                if let n = d[key] as? NSNumber { return n.doubleValue }
                if let t = d[key] as? String { return Double(t.replacingOccurrences(of: ",", with: "")) }
                return nil
            }
        }
        let g = ResultsGrowth(symbol: sym, resultsDay: EarningsMath.iso.string(from: r.date), period: o["period"] as? String ?? "",
                              basis: o["basis"] as? String ?? "", unit: o["unit"] as? String ?? "",
                              rev: nums("revenue"), pat: nums("net_profit"), made: Date(), source: "Groq")
        guard g.rev[0] != nil || g.pat[0] != nil else { throw GroqClient.Failure(message: "couldn't find revenue / profit in the filing") }
        return g
    }

    static func shift(_ day: String, days: Int) -> String {
        guard let d = EarningsMath.iso.date(from: day) else { return day }
        return EarningsMath.iso.string(from: d.addingTimeInterval(Double(days) * 86_400))
    }
}

/// Settings row for the growth columns.
struct ResultsGrowthSettingsRow: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = ResultsGrowthCenter.shared
    @AppStorage("growth.auto") private var auto = true
    @AppStorage("growth.groqFallback") private var groqFallback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle("REV_YOY / PAT_YOY — fill in automatically when results come out (NSE numbers)", isOn: $auto).toggleStyle(.checkbox)
                Spacer()
                Text("\(c.bySymbol.count) stocks").font(.caption).foregroundStyle(.secondary)
                if c.currentSymbol != nil { ProgressView().controlSize(.small) }
            }
            if auto { GrowthDaysPicker() }
            HStack(spacing: 10) {
                Button("Fill all Filter stocks now") { c.fillMissing(vm.filterRows.map { vm.rowKey($0) }) }
                    .help("Every stock in your Filter without numbers yet — from NSE, about a second each")
                Toggle("If NSE has no numbers, let Groq read the filing (slow on a free key)", isOn: $groqFallback).toggleStyle(.checkbox)
                if !c.lastNSEReply.isEmpty {
                    Button("Copy last NSE reply") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.lastNSEReply, forType: .string) }
                        .help("For fixing the column if NSE changes its data")
                }
            }
            .controlSize(.small)
            if let s = c.status { Text(s).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }
    }
}

/// Pick which EARNINGS values start the REV_YOY / PAT_YOY fetch: EARNINGS = 1, or 0, 1, 2 …
struct GrowthDaysPicker: View {
    @ObservedObject private var c = ResultsGrowthCenter.shared
    var compact = false
    var body: some View {
        let on = ResultsGrowthCenter.days
        HStack(spacing: 6) {
            Text(compact ? "Fetch when EARNINGS =" : "Fetch for stocks with EARNINGS =").font(.caption)
            ForEach(0...7, id: \.self) { d in
                Toggle(isOn: Binding(get: { on.contains(d) }, set: { v in
                    var x = on; if v { x.insert(d) } else { x.remove(d) }
                    c.setDays(x)
                })) { Text("\(d)").monospacedDigit() }
                .toggleStyle(.button).controlSize(.small)
            }
            Menu("Presets") {
                Button("Only 1 (the day after results)") { c.setDays([1]) }
                Button("0, 1, 2") { c.setDays([0, 1, 2]) }
                Button("0 – 3 (covers weekends)") { c.setDays([0, 1, 2, 3]) }
                Button("0 – 7") { c.setDays(Set(0...7)) }
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        }
        .help("0 = results today, 1 = yesterday … Stocks whose EARNINGS is one of the ticked values get REV_YOY / PAT_YOY fetched automatically.")
    }
}

// MARK: - NSE's results comparison (the numbers behind nseindia.com's "Financial Results Comparison")
//
// https://www.nseindia.com/api/results-comparision?symbol=SYM   (spelling is NSE's; unofficial, may change)
// Lists the last few quarters' figures. Field names aren't documented, so the parser looks for them by meaning:
// period end date, revenue (net sales / income from operations), net profit after tax, consolidated or not.

enum NSEResults {
    struct NoData: LocalizedError { let why: String; let raw: String; var errorDescription: String? { why } }

    struct Quarter: Equatable {
        let from: String?
        let to: String           // yyyy-MM-dd
        let revenue: Double?
        let profit: Double?
        let consolidated: Bool?
    }

    @MainActor static func growth(_ sym: String) async throws -> (growth: ResultsGrowth, raw: String) {
        let q = sym.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sym
        guard let url = URL(string: "https://www.nseindia.com/api/results-comparision?symbol=\(q)") else { throw NoData(why: "bad symbol", raw: "") }
        let data = try await NSEDealsClient.raw(url, referer: "https://www.nseindia.com/companies-listing/corporate-filings-financial-results-comparision", json: true)
        let raw = String(String(data: data, encoding: .utf8)?.prefix(1500) ?? "")
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw NoData(why: "NSE sent no JSON (blocked?)", raw: raw) }
        let quarters = parse(obj)
        guard let g = compute(sym, quarters) else { throw NoData(why: "no quarterly revenue / profit in NSE's comparison data", raw: raw) }
        return (g, raw)
    }

    /// Every row anywhere in the reply that has a period-end date and a revenue or profit figure.
    static func parse(_ obj: Any) -> [Quarter] {
        var rows: [[String: Any]] = []
        func walk(_ x: Any) {
            if let a = x as? [[String: Any]] { rows += a; a.forEach { $0.values.forEach(walk) } }
            else if let a = x as? [Any] { a.forEach(walk) }
            else if let d = x as? [String: Any] { d.values.forEach(walk) }
        }
        walk(obj)
        return rows.compactMap(quarter)
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String {
            let t = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("(") && t.hasSuffix(")") { return Double(t.dropFirst().dropLast()).map { -$0 } }
            return Double(t)
        }
        return nil
    }

    static func day(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        for c in [s, s.capitalized, s.lowercased().capitalized] { if let d = EarningsMath.normalise(c) { return d } }   // "31-MAR-2026"
        return nil
    }

    static func quarter(_ r: [String: Any]) -> Quarter? {
        let keys = r.keys.map { ($0, $0.lowercased()) }
        func key(_ wants: [String], not: [String] = []) -> String? {
            for w in wants { if let k = keys.first(where: { $0.1.contains(w) && !not.contains(where: $0.1.contains) }) { return k.0 } }
            return nil
        }
        guard let toK = key(["to_date", "todate", "to_dt", "period_end", "periodend", "toperiod"]), let to = day(r[toK]) else { return nil }
        let fromK = key(["from_date", "fromdate", "from_dt", "period_start"])
        let revK = key(["net_sale", "income_from_op", "inc_from_op", "rev_from_op", "revenue", "sales", "turnover", "tot_inc", "total_inc", "totalincome"],
                       not: ["oth", "other", "exp"])
        let patK = key(["pro_loss_aft_tax", "profit_after_tax", "profitaftertax", "net_profit", "netprofit", "net_pro", "pat", "pro_loss", "profit"],
                       not: ["bef", "before", "share", "eps", "margin", "oth"])
        let rev = revK.flatMap { num(r[$0]) }, pat = patK.flatMap { num(r[$0]) }
        guard rev != nil || pat != nil else { return nil }
        var consol: Bool?
        for (k, low) in keys where low.contains("con") || low.contains("type") || low.contains("nature") {
            if let v = (r[k] as? String)?.lowercased() {
                if v.hasPrefix("con") || v == "c" { consol = true } else if v.hasPrefix("stand") || v.hasPrefix("non") || v == "s" { consol = false }
            }
        }
        return Quarter(from: fromK.flatMap { day(r[$0]) }, to: to, revenue: rev, profit: pat, consolidated: consol)
    }

    /// Latest 3-month quarter vs the same quarter a year before and the quarter before it.
    static func compute(_ sym: String, _ all: [Quarter]) -> ResultsGrowth? {
        let f = EarningsMath.iso
        func days(_ a: String, _ b: String) -> Double? { guard let x = f.date(from: a), let y = f.date(from: b) else { return nil }; return y.timeIntervalSince(x) / 86_400 }
        // 3-month periods only (when the start date is known)
        var qs = all.filter { q in q.from.flatMap { days($0, q.to) }.map { $0 > 75 && $0 < 105 } ?? true }
        let anyConsol = qs.contains { $0.consolidated == true }
        if anyConsol { qs = qs.filter { $0.consolidated == true } }
        var byEnd: [String: Quarter] = [:]
        for q in qs where byEnd[q.to] == nil { byEnd[q.to] = q }
        guard let last = byEnd.keys.max(), let cur = byEnd[last] else { return nil }
        func near(_ offsetDays: Double) -> Quarter? {
            byEnd.values.filter { q in days(q.to, last).map { abs($0 - offsetDays) <= 20 } ?? false }.first
        }
        let ya = near(365), pq = near(91)
        guard ya != nil || pq != nil else { return nil }
        let df = DateFormatter(); df.dateFormat = "d MMM yyyy"
        return ResultsGrowth(symbol: sym, resultsDay: last, period: "quarter ended " + (f.date(from: last).map(df.string) ?? last),
                             basis: anyConsol ? "consolidated" : "as reported", unit: "as on NSE",
                             rev: [cur.revenue, ya?.revenue, pq?.revenue], pat: [cur.profit, ya?.profit, pq?.profit], made: Date(), source: "NSE")
    }
}

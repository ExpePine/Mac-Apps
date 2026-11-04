import SwiftUI

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

    /// Have we got growth for results on/after `earnDate` (allowing a few days' slack)?
    func has(_ sym: String, since earnDate: String) -> Bool {
        guard let g = bySymbol[sym] else { return false }
        return g.resultsDay >= Self.shift(earnDate, days: -3)
    }

    /// Stocks whose results just came out (from the EARNINGS column); skips ones done or tried recently.
    func consider(_ due: [(symbol: String, earnDate: String)], model: String) {
        guard auto, !GroqClient.apiKey.isEmpty else { return }
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

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let s = queue.removeFirst()
                currentSymbol = s
                status = "Reading \(s)'s results… (\(queue.count) waiting)"
                let earn = EarningsCenter.shared.value(s, on: EarningsMath.iso.string(from: Date()))?.date ?? ""
                let k = s + "|" + earn
                do {
                    let g = try await Self.extract(s, notBefore: earn.isEmpty ? nil : Self.shift(earn, days: -2), model: model)
                    bySymbol[s] = g
                    save()
                    tried[k] = nil
                    onReload?()
                    status = nil
                } catch is GroqClient.RateLimited {
                    queue.insert(s, at: 0)
                    status = "Groq per-minute limit — waiting a minute…"
                    try? await Task.sleep(nanoseconds: 65_000_000_000)
                    continue
                } catch {
                    let t = tried[k]
                    tried[k] = ((t?.count ?? 0) + 1, Date())
                    status = "\(s): \(error.localizedDescription)"
                }
                currentSymbol = nil
                if !queue.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000_000) }   // spread over the minute limit
            }
            currentSymbol = nil
            running = false
        }
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
                              rev: nums("revenue"), pat: nums("net_profit"), made: Date())
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
    @ObservedObject private var c = ResultsGrowthCenter.shared
    @AppStorage("growth.auto") private var auto = true
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle("REV_YOY / PAT_YOY — fill in automatically when results come out (Groq)", isOn: $auto).toggleStyle(.checkbox)
                Spacer()
                Text("\(c.bySymbol.count) stocks").font(.caption).foregroundStyle(.secondary)
                if c.currentSymbol != nil { ProgressView().controlSize(.small) }
            }
            if auto { GrowthDaysPicker() }
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

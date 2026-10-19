import Foundation

/// A performance study: "for each stock, the event happened N days ago (column value) —
/// how did the stock do from that day on?" Prices from Yahoo daily closes.
struct PerfStudy: Codable, Identifiable, Equatable {
    enum Source: String, Codable, CaseIterable {
        case main, experiments
        var title: String { self == .main ? "Main sheet (MV2)" : "Experiments sheet" }
    }
    enum Unit: String, Codable, CaseIterable {
        case tradingDays, calendarDays, dates
        var title: String {
            switch self {
            case .tradingDays: return "Trading days ago"
            case .calendarDays: return "Calendar days ago"
            case .dates: return "A date"
            }
        }
    }
    enum Scope: String, Codable, CaseIterable {
        case all, filter, watchlists
        var title: String {
            switch self {
            case .all: return "All stocks with a value"
            case .filter: return "Only the Filter list"
            case .watchlists: return "Only my watchlists"
            }
        }
    }

    var id = UUID()
    var name = "D_Trigger performance"
    var source: Source = .main
    var column = "D_Trigger"
    var unit: Unit = .tradingDays
    var scope: Scope = .all
    var successPercent = 20.0          // "rose significantly" = reached +X% from the event close
    var splitBy = ""                   // compare groups by this column ("" = none); "main:" / "exp:" prefix
    var horizons: [Int] = [5, 10, 21, 50, 100]
    var minDaysAgo = 0                 // ignore events newer than this (not enough time to judge)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PerfStudy()
        func v<T: Decodable>(_ k: CodingKeys, _ f: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? f }
        id = v(.id, UUID()); name = v(.name, d.name); source = v(.source, d.source); column = v(.column, d.column)
        unit = v(.unit, d.unit); scope = v(.scope, d.scope); successPercent = v(.successPercent, d.successPercent)
        splitBy = v(.splitBy, d.splitBy); horizons = v(.horizons, d.horizons); minDaysAgo = v(.minDaysAgo, d.minDaysAgo)
    }
}

/// One stock's event, as read from a sheet.
struct PerfEvent {
    let symbol: String
    let value: String           // the column's text: "100" (days ago) or a date
    let group: String?          // split-by value
}

struct PerfRow: Identifiable, Codable {
    var id: String { symbol }
    let symbol: String
    let value: String
    let eventDay: String
    let tradingDaysSince: Int
    let entry: Double
    let now: Double
    let returnNow: Double            // %
    let peak: Double                 // best close after the event, % vs entry
    let daysToPeak: Int
    let worst: Double                // lowest close after the event, % vs entry
    let hitDays: Int?                // trading days until it first closed ≥ success %
    let horizons: [Double?]          // % at each horizon (trading days after the event)
    let benchmark: Double?           // Nifty 50 over the same days, %
    var group: String
    let path: [Double]               // % vs entry for day 0, 1, 2… (up to 250)
    var preMove: Double? = nil       // the stock's own % move over the 21 trading days BEFORE the event
    var marketPre: Double? = nil     // Nifty 50 % move over the 21 trading days before the event

    var excess: Double? { benchmark.map { returnNow - $0 } }
}

struct PerfGroup: Identifiable {
    var id: String { name }
    let name: String
    let count: Int
    let avgReturn: Double
    let medianReturn: Double
    let avgPeak: Double
    let hitRate: Double
    let medianDaysToHit: Double?
}

struct PerfResult {
    var rows: [PerfRow] = []
    var skipped: [(String, String)] = []         // symbol, reason
    var refDay = ""
    var groups: [PerfGroup] = []
    var horizonStats: [(days: Int, count: Int, avg: Double, median: Double, winRate: Double)] = []
    var avgPath: [(day: Int, mean: Double, median: Double, count: Int)] = []
    var histogram: [(from: Double, to: Double, count: Int)] = []

    var count: Int { rows.count }
    var avgReturn: Double? { rows.isEmpty ? nil : rows.map(\.returnNow).reduce(0, +) / Double(rows.count) }
    var medianReturn: Double? { PerfEngine.median(rows.map(\.returnNow)) }
    var avgPeak: Double? { rows.isEmpty ? nil : rows.map(\.peak).reduce(0, +) / Double(rows.count) }
    var hitRate: Double? { rows.isEmpty ? nil : Double(rows.filter { $0.hitDays != nil }.count) / Double(rows.count) }
    var medianDaysToHit: Double? { PerfEngine.median(rows.compactMap { $0.hitDays.map(Double.init) }) }
    var avgExcess: Double? {
        let e = rows.compactMap(\.excess)
        return e.isEmpty ? nil : e.reduce(0, +) / Double(e.count)
    }
    var winRate: Double? { rows.isEmpty ? nil : Double(rows.filter { $0.returnNow > 0 }.count) / Double(rows.count) }
}

enum PerfEngine {
    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Index of the event day in `series`, from the cell value.
    static func eventIndex(_ value: String, series: PriceSeries, refDay: String, unit: PerfStudy.Unit) -> Int? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        if unit == .dates || NumberParser.parse(v) == nil {
            guard let d = DateParser.parse(v) else { return nil }
            return series.index(onOrBefore: HistoryStore.dayKey(d))
        }
        guard let n = NumberParser.parse(v), n >= 0, n < 20_000 else { return nil }
        switch unit {
        case .tradingDays:
            guard let ref = series.index(onOrBefore: refDay) else { return nil }
            let i = ref - Int(n.rounded())
            return i >= 0 ? i : nil
        case .calendarDays, .dates:
            guard let refDate = HistoryStore.date(fromKey: refDay),
                  let d = Calendar.current.date(byAdding: .day, value: -Int(n.rounded()), to: refDate) else { return nil }
            return series.index(onOrBefore: HistoryStore.dayKey(d))
        }
    }

    static func analyze(_ events: [PerfEvent], book: PriceBook, refDay: String, study: PerfStudy) -> PerfResult {
        var result = PerfResult()
        result.refDay = refDay
        let bench = book.series(for: ScreenerViewModel.benchmarkSymbol)
        let target = study.successPercent

        for e in events {
            guard let s = book.series(for: e.symbol) else { result.skipped.append((e.symbol, "No Yahoo prices")); continue }
            guard let i = eventIndex(e.value, series: s, refDay: refDay, unit: study.unit) else {
                result.skipped.append((e.symbol, "Event \"\(e.value)\" is before the price history or unreadable")); continue
            }
            let end = s.closes.count - 1            // latest Yahoo close
            guard end >= i, s.closes[i] > 0 else {
                result.skipped.append((e.symbol, "No prices after the event")); continue
            }
            let since = end - i
            if since < study.minDaysAgo { result.skipped.append((e.symbol, "Event only \(since) trading days ago")); continue }
            let entry = s.closes[i]
            let window = s.closes[i...end]
            var peak = entry, peakAt = 0, worst = entry, hit: Int?
            for (k, c) in window.enumerated() {
                if c > peak { peak = c; peakAt = k }
                if c < worst { worst = c }
                if hit == nil, k > 0, c / entry >= 1 + target / 100 - 1e-9 { hit = k }
            }
            let now = s.closes[end]
            let horizons = study.horizons.map { h -> Double? in i + h <= end ? (s.closes[i + h] / entry - 1) * 100 : nil }
            var benchmark: Double?
            if let b = bench, let bi = b.index(onOrBefore: s.days[i]), let be = b.index(onOrBefore: s.days[end]), b.closes[bi] > 0 {
                benchmark = (b.closes[be] / b.closes[bi] - 1) * 100
            }
            let path = window.prefix(251).map { ($0 / entry - 1) * 100 }
            let preMove: Double? = i >= 21 && s.closes[i - 21] > 0 ? (entry / s.closes[i - 21] - 1) * 100 : nil
            var marketPre: Double?
            if let b = bench, let bi = b.index(onOrBefore: s.days[i]), bi >= 21, b.closes[bi - 21] > 0 {
                marketPre = (b.closes[bi] / b.closes[bi - 21] - 1) * 100
            }
            result.rows.append(PerfRow(symbol: e.symbol, value: e.value, eventDay: s.days[i], tradingDaysSince: since,
                                       entry: entry, now: now, returnNow: (now / entry - 1) * 100,
                                       peak: (peak / entry - 1) * 100, daysToPeak: peakAt,
                                       worst: (worst / entry - 1) * 100, hitDays: hit, horizons: horizons,
                                       benchmark: benchmark, group: e.group ?? "", path: Array(path),
                                       preMove: preMove, marketPre: marketPre))
        }
        let skipped = result.skipped
        var summary = summarize(result.rows, study: study)
        summary.skipped = skipped
        summary.refDay = refDay
        return summary
    }

    /// Aggregates already-built rows (also used to show a stored run again).
    static func summarize(_ rows: [PerfRow], study: PerfStudy) -> PerfResult {
        var result = PerfResult()
        result.rows = rows

        // Group labels: numbers → Low / Mid / High thirds; text → its values
        let raw = result.rows.map(\.group)
        if !study.splitBy.isEmpty {
            let labels = groupLabels(raw)
            result.rows = zip(result.rows, labels).map { r, g in var c = r; c.group = g; return c }
            let byGroup = Dictionary(grouping: result.rows, by: \.group)
            result.groups = byGroup.map { name, rows in
                PerfGroup(name: name, count: rows.count,
                          avgReturn: rows.map(\.returnNow).reduce(0, +) / Double(rows.count),
                          medianReturn: median(rows.map(\.returnNow)) ?? 0,
                          avgPeak: rows.map(\.peak).reduce(0, +) / Double(rows.count),
                          hitRate: Double(rows.filter { $0.hitDays != nil }.count) / Double(rows.count),
                          medianDaysToHit: median(rows.compactMap { $0.hitDays.map(Double.init) }))
            }.sorted { $0.avgReturn > $1.avgReturn }
        }

        // Horizons
        for (h, days) in study.horizons.enumerated() {
            let v = result.rows.compactMap { $0.horizons[h] }
            guard !v.isEmpty else { continue }
            result.horizonStats.append((days, v.count, v.reduce(0, +) / Double(v.count), median(v) ?? 0,
                                        Double(v.filter { $0 > 0 }.count) / Double(v.count)))
        }

        // Average path after the event (needs ≥ 3 stocks on a day)
        let maxLen = result.rows.map(\.path.count).max() ?? 0
        for k in 0..<maxLen {
            let v = result.rows.compactMap { $0.path.count > k ? $0.path[k] : nil }
            guard v.count >= 3 else { break }
            result.avgPath.append((k, v.reduce(0, +) / Double(v.count), median(v) ?? 0, v.count))
        }

        // Histogram of returns since the event (10% bins, clipped at -50 / +200)
        if !result.rows.isEmpty {
            let r = result.rows.map { min(200, max(-50, $0.returnNow)) }
            let lo = (floor((r.min() ?? 0) / 10) * 10), hi = (ceil(((r.max() ?? 0) + 0.0001) / 10) * 10)
            var from = lo
            while from < hi {
                let to = from + 10
                result.histogram.append((from, to, r.filter { $0 >= from && $0 < to }.count))
                from = to
            }
        }
        return result
    }

    static func groupLabels(_ raw: [String]) -> [String] {
        let nums = raw.map { NumberParser.parse($0.trimmingCharacters(in: .whitespaces)) }
        let present = nums.compactMap { $0 }
        let distinct = Set(present)
        if !raw.isEmpty, Double(present.count) / Double(raw.count) >= 0.8, distinct.count > 8 {
            let s = present.sorted()
            let a = s[s.count / 3], b = s[(s.count * 2) / 3]
            func f(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...2))) }
            return nums.map { n in
                guard let n else { return "(blank)" }
                return n <= a ? "Low (≤ \(f(a)))" : (n <= b ? "Mid (\(f(a))–\(f(b)))" : "High (> \(f(b)))")
            }
        }
        var counts: [String: Int] = [:]
        for r in raw { counts[r.trimmingCharacters(in: .whitespaces), default: 0] += 1 }
        let keep = Set(counts.sorted { $0.value > $1.value }.prefix(12).map(\.key))
        return raw.map { r in
            let t = r.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "(blank)" : (keep.contains(t) ? t : "Other")
        }
    }
}

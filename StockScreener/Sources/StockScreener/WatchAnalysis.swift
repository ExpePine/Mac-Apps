import Foundation

/// One watchlist item with its returns and today's sheet row (for sector / extra columns).
struct WatchRow: Identifiable {
    let item: WatchItem
    let r: WatchReturns
    var sector = ""
    var list = ""                        // list name (used by the combined view)
    var id: UUID { item.id }
    var symbol: String { item.symbol }
    var alpha: Double? { r.sinceAdded.flatMap { s in r.benchmark.map { s - $0 } } }
    var month: String { String(item.addedDay.prefix(7)) }
}

/// Summary numbers for a set of watchlist rows.
struct WatchSummary {
    var n = 0, priced = 0
    var avg: Double?, median: Double?, winRate: Double?
    var avgAlpha: Double?
    var avgBest: Double?, avgWorst: Double?
    var avgDays: Double?
    var hit10: Int = 0, hitMinus10: Int = 0
    var avgDaysTo10: Double?
    var targetHits = 0, stopHits = 0, withTarget = 0, withStop = 0
    var best: WatchRow?, worst: WatchRow?
    struct Fwd: Identifiable { let label: String; let n: Int; let avg: Double?; let median: Double?; let win: Double?; var id: String { label } }
    var fwd: [Fwd] = []

    init(_ rows: [WatchRow]) {
        n = rows.count
        let rets = rows.compactMap(\.r.sinceAdded)
        priced = rets.count
        avg = Self.mean(rets); median = Self.median(rets)
        winRate = rets.isEmpty ? nil : Double(rets.filter { $0 > 0 }.count) / Double(rets.count) * 100
        avgAlpha = Self.mean(rows.compactMap(\.alpha))
        avgBest = Self.mean(rows.compactMap(\.r.maxSinceAdded))
        avgWorst = Self.mean(rows.compactMap(\.r.worstSinceAdded))
        avgDays = Self.mean(rows.compactMap { $0.r.tradingDays.map(Double.init) })
        hit10 = rows.filter { $0.r.daysTo10 != nil }.count
        hitMinus10 = rows.filter { $0.r.daysToMinus10 != nil }.count
        avgDaysTo10 = Self.mean(rows.compactMap { $0.r.daysTo10.map(Double.init) })
        withTarget = rows.filter { $0.item.target != nil }.count
        withStop = rows.filter { $0.item.stop != nil }.count
        targetHits = rows.filter(\.r.targetHit).count
        stopHits = rows.filter(\.r.stopHit).count
        let pr = rows.filter { $0.r.sinceAdded != nil }
        best = pr.max { $0.r.sinceAdded! < $1.r.sinceAdded! }
        worst = pr.min { $0.r.sinceAdded! < $1.r.sinceAdded! }
        let fk: [(String, KeyPath<WatchReturns, Double?>)] = [("5 days", \WatchReturns.fwd5), ("10 days", \WatchReturns.fwd10), ("22 days", \WatchReturns.fwd22)]
        for (label, kp) in fk {
            let v = rows.compactMap { $0.r[keyPath: kp] }
            fwd.append(Fwd(label: label, n: v.count, avg: Self.mean(v), median: Self.median(v), win: v.isEmpty ? nil : Double(v.filter { $0 > 0 }.count) / Double(v.count) * 100))
        }
    }

    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}

/// Rows grouped by a key (source, sector, tag, month added) with their stats.
struct WatchGroup: Identifiable {
    let key: String
    let rows: [WatchRow]
    let s: WatchSummary
    var id: String { key }

    static func by(_ rows: [WatchRow], _ key: (WatchRow) -> [String]) -> [WatchGroup] {
        var m: [String: [WatchRow]] = [:]
        for r in rows { for k in key(r) { m[k.isEmpty ? "—" : k, default: []].append(r) } }
        return m.map { WatchGroup(key: $0.key, rows: $0.value, s: WatchSummary($0.value)) }
            .sorted { ($0.s.avg ?? -.infinity) > ($1.s.avg ?? -.infinity) }
    }
}

/// Equal-weight curve: on each trading day, the average return (since each stock's own added close) of every
/// stock added by then — exited stocks stay frozen at their exit. Plus Nifty 50 from the first day, and drawdown.
struct WatchCurvePoint: Identifiable {
    let day: String
    let date: Date
    let value: Double          // %
    let nifty: Double?         // %
    let drawdown: Double       // % from the curve's best so far
    let count: Int
    var id: String { day }
}

enum WatchCurve {
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func date(_ d: String) -> Date { fmt.date(from: d) ?? Date() }

    static func build(_ items: [WatchItem], book: PriceBook, benchmark: String) -> [WatchCurvePoint] {
        let starts = items.map(\.addedDay).filter { !$0.isEmpty }
        guard let first = starts.min() else { return [] }
        let bench = book.series(for: benchmark)
        // trading calendar: Nifty's days, else the union of the stocks' days
        var cal = bench?.days.filter { $0 >= first } ?? []
        if cal.isEmpty {
            var set = Set<String>()
            for it in items { if let s = book.series(for: it.symbol) { s.days.filter { $0 >= first }.forEach { set.insert($0) } } }
            cal = set.sorted()
        }
        struct Pos { let s: PriceSeries; let start: Double; let from: String; let to: String? }
        let pos: [Pos] = items.compactMap { it in
            guard let s = book.series(for: it.symbol) else { return nil }
            let p0 = it.addedPrice ?? s.index(onOrBefore: it.addedDay).map { s.closes[$0] }
            guard let p = p0, p > 0 else { return nil }
            return Pos(s: s, start: p, from: it.addedDay, to: it.exitDay)
        }
        let b0 = bench.flatMap { b in b.index(onOrBefore: first).map { b.closes[$0] } }
        var out: [WatchCurvePoint] = []
        var peak = 1.0
        for d in cal {
            var sum = 0.0, n = 0
            for p in pos where p.from <= d {
                let day = p.to.map { min($0, d) } ?? d
                if let i = p.s.index(onOrBefore: day) { sum += p.s.closes[i] / p.start - 1; n += 1 }
            }
            guard n > 0 else { continue }
            let v = sum / Double(n)
            peak = max(peak, 1 + v)
            var nf: Double?
            if let b = bench, let b0, b0 > 0, let j = b.index(onOrBefore: d) { nf = (b.closes[j] / b0 - 1) * 100 }
            out.append(WatchCurvePoint(day: d, date: date(d), value: v * 100, nifty: nf, drawdown: ((1 + v) / peak - 1) * 100, count: n))
        }
        return out
    }
}

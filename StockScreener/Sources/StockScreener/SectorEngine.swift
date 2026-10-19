import Foundation

// Sector momentum from Yahoo daily closes.
//
// • Each sector gets an equal-weight index: the average daily % change of its stocks, chained from 100.
// • Momentum: 1W / 1M / 3M / 6M change of that index.
// • Relative strength vs the Nifty 50, turned into a rotation map (RRG-style approximation):
//     RS-Ratio    = 100 × RS ÷ its 50-day average      (> 100: stronger than its own recent norm vs Nifty)
//     RS-Momentum = 100 × RS-Ratio ÷ RS-Ratio 10 days ago (> 100: relative strength improving)
//   Quadrants: Leading (>100, >100) · Weakening (>100, <100) · Lagging (<100, <100) · Improving (<100, >100).
// • Trend: index above / below its 50-day average and whether that average is rising or falling.
// • Breadth: share of the sector's stocks above their own 50-day average.
// • A regime change is a new quadrant / trend that holds for `confirmDays` days in a row.

extension PriceSeries {
    /// Combines two downloads; the newer one wins on overlapping days.
    func merged(with newer: PriceSeries) -> PriceSeries {
        var map = Dictionary(zip(days, closes).map { ($0, $1) }, uniquingKeysWith: { a, _ in a })
        for (d, c) in zip(newer.days, newer.closes) { map[d] = c }
        let keys = map.keys.sorted()
        return PriceSeries(days: keys, closes: keys.map { map[$0]! })
    }
}

struct RRGPoint: Hashable {
    let day: String
    let ratio: Double
    let momentum: Double
}

enum Quadrant: String, Codable, CaseIterable {
    case leading = "Leading", weakening = "Weakening", lagging = "Lagging", improving = "Improving"
    static func of(ratio: Double, momentum: Double) -> Quadrant {
        ratio >= 100 ? (momentum >= 100 ? .leading : .weakening) : (momentum >= 100 ? .improving : .lagging)
    }
}

enum Trend: String, Codable {
    case up = "Uptrend", down = "Downtrend", sideways = "Sideways"
}

enum MarketRegime: String, Codable {
    case riskOn = "Risk-on", neutral = "Mixed", riskOff = "Risk-off"
}

struct SectorState: Codable, Equatable {
    let day: String
    let quadrant: Quadrant
    let trend: Trend
    let score: Double
}

struct SectorStat: Identifiable {
    var id: String { name }
    let name: String
    let members: Int
    let priced: Int
    let index: [Double]              // last ~130 index values (for the sparkline)
    let r1w: Double?, r1m: Double?, r3m: Double?, r6m: Double?
    let vsNifty1m: Double?           // 1M change minus the Nifty's
    let rsRatio: Double
    let rsMomentum: Double
    let quadrant: Quadrant
    let trend: Trend
    let breadth: Double              // share above own 50-day average
    let score: Double                // 0–100 composite (rank-based)
    let rank: Int
    let rankChange5d: Int?           // + = moved up
    let tail: [(ratio: Double, momentum: Double)]   // last 10 days on the rotation map
    var path: [RRGPoint] = []                        // every day of the history window (for the animation)
    let history: [SectorState]       // last 40 days
    let topMembers: [(String, Double)]   // best 1M performers
}

struct RegimeChange: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case rotation, trend, market }
    var id: String { "\(kind.rawValue)|\(sector)|\(day)|\(to)" }
    let day: String
    let sector: String               // "Market" for the market regime
    let kind: Kind
    let from: String
    let to: String
    let detail: String

    /// Changes worth a notification: into Leading / Lagging, trend flips, market regime flips.
    var isMajor: Bool {
        switch kind {
        case .rotation: return to == Quadrant.leading.rawValue || to == Quadrant.lagging.rawValue
        case .trend: return to != Trend.sideways.rawValue
        case .market: return true
        }
    }
}

struct SectorReport {
    var asOf = ""
    var sectors: [SectorStat] = []
    var market: MarketRegime = .neutral
    var marketDetail = ""
    var marketHistory: [(day: String, regime: MarketRegime, breadth: Double)] = []
    var niftyTrend: Trend = .sideways
    var overallBreadth = 0.0
    var changes: [RegimeChange] = []     // detected over the history window, newest first
    var pricedStocks = 0
    var totalStocks = 0
}

enum SectorEngine {

    static func sma(_ v: [Double?], _ n: Int, at t: Int) -> Double? {
        guard t >= n - 1 else { return nil }
        var s = 0.0
        for k in (t - n + 1)...t { guard let x = v[k] else { return nil }; s += x }
        return s / Double(n)
    }

    static func trend(_ v: [Double], at t: Int) -> Trend {
        let opt = v.map { Optional($0) }
        guard let m = sma(opt, 50, at: t), let m10 = sma(opt, 50, at: t - 10) else { return .sideways }
        if v[t] > m && m > m10 { return .up }
        if v[t] < m && m < m10 { return .down }
        return .sideways
    }

    /// `members`: sector → symbols. Returns stats plus detected regime changes over `historyDays`.
    static func compute(members: [String: [String]], book: PriceBook, minMembers: Int = 3,
                        confirmDays: Int = 2, historyDays: Int = 40) -> SectorReport {
        var report = SectorReport()
        guard let nifty = book.series(for: ScreenerViewModel.benchmarkSymbol), nifty.days.count > 80 else { return report }
        let cal = Array(nifty.days.suffix(260))
        let T = cal.count
        let pos = Dictionary(cal.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let niftyIdx: [Double] = cal.map { d in nifty.closes[nifty.index(onOrBefore: d) ?? 0] }
        report.asOf = cal.last ?? ""
        report.niftyTrend = trend(niftyIdx, at: T - 1)

        // Aligned closes for every priced stock
        var aligned: [String: [Double?]] = [:]
        let allSymbols = Set(members.values.flatMap { $0 })
        report.totalStocks = allSymbols.count
        for sym in allSymbols {
            guard let s = book.series(for: sym) else { continue }
            var row = [Double?](repeating: nil, count: T)
            for (d, c) in zip(s.days, s.closes) { if let p = pos[d], c > 0 { row[p] = c } }
            if row.compactMap({ $0 }).count >= 30 { aligned[sym] = row }
        }
        report.pricedStocks = aligned.count

        // Per-stock: above own 50-day average (for breadth), per day
        var above: [String: [Bool?]] = [:]
        for (sym, row) in aligned {
            var out = [Bool?](repeating: nil, count: T)
            var sum = 0.0, cnt = 0
            var window: [Double] = []
            for t in 0..<T {
                if let c = row[t] {
                    window.append(c); sum += c; cnt += 1
                    if window.count > 50 { sum -= window.removeFirst(); cnt -= 1 }
                    if window.count == 50 { out[t] = c > sum / Double(cnt) }
                }
            }
            above[sym] = out
        }

        // Market breadth history
        let hStart = max(60, T - historyDays)
        for t in hStart..<T {
            let flags = above.values.compactMap { $0[t] }
            let b = flags.isEmpty ? 0 : Double(flags.filter { $0 }.count) / Double(flags.count)
            let tr = trend(niftyIdx, at: t)
            let regime: MarketRegime = (tr == .up && b >= 0.55) ? .riskOn : ((tr == .down && b <= 0.45) ? .riskOff : .neutral)
            report.marketHistory.append((cal[t], regime, b))
        }
        report.market = report.marketHistory.last?.regime ?? .neutral
        report.overallBreadth = report.marketHistory.last?.breadth ?? 0
        report.marketDetail = "Nifty 50 \(report.niftyTrend.rawValue.lowercased()); \(Int(report.overallBreadth * 100))% of stocks above their 50-day average"

        // Sector indices and states
        struct Work { let name: String; let members: Int; let priced: [String]; let index: [Double]; let ratio: [Double?]; let mom: [Double?] }
        var works: [Work] = []
        for (name, syms) in members {
            let priced = syms.filter { aligned[$0] != nil }
            guard priced.count >= minMembers else { continue }
            var idx = [Double](repeating: 100, count: T)
            for t in 1..<T {
                var rets: [Double] = []
                for s in priced { if let a = aligned[s]?[t], let b = aligned[s]?[t - 1], b > 0 { rets.append(max(-0.2, min(0.2, a / b - 1))) } }
                idx[t] = idx[t - 1] * (1 + (rets.count >= max(2, minMembers / 2) ? rets.reduce(0, +) / Double(rets.count) : 0))
            }
            let rs: [Double?] = (0..<T).map { niftyIdx[$0] > 0 ? idx[$0] / niftyIdx[$0] : nil }
            let ratio: [Double?] = (0..<T).map { t in sma(rs, 50, at: t).flatMap { m in rs[t].map { 100 * $0 / m } } }
            let mom: [Double?] = (0..<T).map { t in t >= 10 ? ratio[t].flatMap { r in ratio[t - 10].map { 100 * r / $0 } } : nil }
            works.append(Work(name: name, members: syms.count, priced: priced, index: idx, ratio: ratio, mom: mom))
        }
        guard !works.isEmpty else { return report }

        func change(_ v: [Double], _ k: Int, at t: Int) -> Double? { t - k >= 0 && v[t - k] > 0 ? (v[t] / v[t - k] - 1) * 100 : nil }
        func breadth(_ w: Work, at t: Int) -> Double {
            let f = w.priced.compactMap { above[$0]?[t] }
            return f.isEmpty ? 0 : Double(f.filter { $0 }.count) / Double(f.count)
        }
        /// Rank-based composite (0–100) of 1M, 3M, RS-Momentum and breadth across sectors on day t.
        func scores(at t: Int) -> [String: Double] {
            let parts: [[Double]] = [
                works.map { change($0.index, 21, at: t) ?? 0 },
                works.map { change($0.index, 63, at: t) ?? 0 },
                works.map { $0.mom[t] ?? 100 },
                works.map { breadth($0, at: t) },
            ]
            var total = [Double](repeating: 0, count: works.count)
            for p in parts {
                let r = PanelBuilder.ranks(p.map { Optional($0) })
                for i in total.indices { total[i] += (r[i] + 1) / 2 }
            }
            return Dictionary(zip(works.map(\.name), total.map { $0 / Double(parts.count) * 100 }), uniquingKeysWith: { a, _ in a })
        }

        var scoreHistory: [Int: [String: Double]] = [:]
        for t in hStart..<T { scoreHistory[t] = scores(at: t) }
        let now = T - 1
        let rankNow = ranks(scoreHistory[now] ?? [:])
        let rank5 = ranks(scoreHistory[now - 5] ?? [:])
        let n1m = change(niftyIdx, 21, at: now)

        for w in works {
            var history: [SectorState] = []
            for t in hStart..<T {
                guard let r = w.ratio[t], let m = w.mom[t] else { continue }
                history.append(SectorState(day: cal[t], quadrant: .of(ratio: r, momentum: m), trend: trend(w.index, at: t),
                                           score: scoreHistory[t]?[w.name] ?? 0))
            }
            let tail: [(Double, Double)] = (max(0, now - 9)...now).compactMap { t in
                guard let r = w.ratio[t], let m = w.mom[t] else { return nil }
                return (r, m)
            }
            let top = w.priced.compactMap { s -> (String, Double)? in
                guard let a = aligned[s]?[now], let b = aligned[s]?[max(0, now - 21)], b > 0 else { return nil }
                return (s, (a / b - 1) * 100)
            }.sorted { $0.1 > $1.1 }.prefix(5)
            let r1m = change(w.index, 21, at: now)
            let path: [RRGPoint] = (hStart..<T).compactMap { t in
                guard let r = w.ratio[t], let m = w.mom[t] else { return nil }
                return RRGPoint(day: cal[t], ratio: r, momentum: m)
            }
            var stat = SectorStat(
                name: w.name, members: w.members, priced: w.priced.count,
                index: Array(w.index.suffix(130)),
                r1w: change(w.index, 5, at: now), r1m: r1m, r3m: change(w.index, 63, at: now), r6m: change(w.index, 126, at: now),
                vsNifty1m: r1m.flatMap { a in n1m.map { a - $0 } },
                rsRatio: w.ratio[now] ?? 100, rsMomentum: w.mom[now] ?? 100,
                quadrant: .of(ratio: w.ratio[now] ?? 100, momentum: w.mom[now] ?? 100),
                trend: trend(w.index, at: now), breadth: breadth(w, at: now),
                score: scoreHistory[now]?[w.name] ?? 0, rank: rankNow[w.name] ?? 0,
                rankChange5d: rank5[w.name].flatMap { old in rankNow[w.name].map { old - $0 } },
                tail: tail, history: history, topMembers: Array(top))
            stat.path = path
            report.sectors.append(stat)
        }
        report.sectors.sort { $0.rank < $1.rank }

        // Regime changes (confirmed)
        var changes: [RegimeChange] = []
        for s in report.sectors {
            changes += detect(s.history.map { ($0.day, $0.quadrant.rawValue) }, confirm: confirmDays).map { d, from, to in
                RegimeChange(day: d, sector: s.name, kind: .rotation, from: from, to: to,
                             detail: String(format: "RS-Ratio %.1f, RS-Momentum %.1f", s.rsRatio, s.rsMomentum))
            }
            changes += detect(s.history.map { ($0.day, $0.trend.rawValue) }, confirm: confirmDays).map { d, from, to in
                RegimeChange(day: d, sector: s.name, kind: .trend, from: from, to: to,
                             detail: s.r1m.map { String(format: "1M %+.1f%%, breadth %d%%", $0, Int(s.breadth * 100)) } ?? "")
            }
        }
        changes += detect(report.marketHistory.map { ($0.day, $0.regime.rawValue) }, confirm: confirmDays).map { d, from, to in
            RegimeChange(day: d, sector: "Market", kind: .market, from: from, to: to, detail: report.marketDetail)
        }
        report.changes = changes.sorted { $0.day != $1.day ? $0.day > $1.day : $0.sector < $1.sector }
        return report
    }

    /// Days where the state changed and then held for `confirm` days (the change is dated on its first day).
    static func detect(_ seq: [(String, String)], confirm: Int) -> [(String, String, String)] {
        guard seq.count > confirm else { return [] }
        var out: [(String, String, String)] = []
        var current = seq[0].1
        var i = 1
        while i < seq.count {
            let s = seq[i].1
            if s != current {
                let end = i + max(1, confirm) - 1
                if end < seq.count && seq[i...end].allSatisfy({ $0.1 == s }) {
                    out.append((seq[i].0, current, s))
                    current = s
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        return out
    }

    private static func ranks(_ scores: [String: Double]) -> [String: Int] {
        Dictionary(scores.sorted { $0.value > $1.value }.enumerated().map { ($1.key, $0 + 1) }, uniquingKeysWith: { a, _ in a })
    }
}

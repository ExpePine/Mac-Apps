import SwiftUI
import Charts

// MARK: - Advanced statistics for a Performance study
//
// From each event's return (event → now), its best / worst close after the event (MFE / MAE), and the Nifty
// over the same days: distribution shape, confidence intervals (Wilson for the win rate, bootstrap and t for the
// mean), risk-adjusted ratios, tail risk, edge ratio, Kelly, regime split, and an equal-weight equity curve.

struct PerfAdvanced {
    var n = 0
    var mean = 0.0, median = 0.0, sd = 0.0, skew = 0.0, kurt = 0.0
    var win = 0.0, winLo = 0.0, winHi = 0.0
    var avgWin = 0.0, avgLoss = 0.0, payoff = 0.0, profitFactor = 0.0, expectancy = 0.0, kelly = 0.0
    var tStat = 0.0, pValue = 1.0
    var bootLo = 0.0, bootHi = 0.0
    var sharpe = 0.0, sortino = 0.0
    var var5 = 0.0, cvar5 = 0.0
    var mfe = 0.0, mae = 0.0, edgeRatio = 0.0
    var excess: Double?, beatNifty: Double?, infoRatio: Double?
    var avgHold = 0.0, annualized: Double?
    var upMarket: (n: Int, avg: Double)?, downMarket: (n: Int, avg: Double)?
    var maxDrawdown: Double?
    var best = 0.0, worst = 0.0

    static func quantile(_ s: [Double], _ q: Double) -> Double {
        guard !s.isEmpty else { return 0 }
        let p = q * Double(s.count - 1), lo = Int(p.rounded(.down)), hi = min(s.count - 1, lo + 1)
        return s[lo] + (s[hi] - s[lo]) * (p - Double(lo))
    }

    /// Two-sided p-value of a t statistic (normal approximation, fine for n ≥ 30).
    static func pNormal(_ t: Double) -> Double { erfc(abs(t) / 2.0.squareRoot()) }

    static func compute(_ rows: [PerfRow], path: [(day: Int, mean: Double, median: Double, count: Int)] = []) -> PerfAdvanced {
        var a = PerfAdvanced()
        let r = rows.map(\.returnNow)
        a.n = r.count
        guard a.n >= 2 else { return a }
        let n = Double(a.n)
        let s = r.sorted()
        a.mean = r.reduce(0, +) / n
        a.median = quantile(s, 0.5)
        let dev = r.map { $0 - a.mean }
        a.sd = (dev.map { $0 * $0 }.reduce(0, +) / (n - 1)).squareRoot()
        if a.sd > 0 {
            a.skew = dev.map { pow($0 / a.sd, 3) }.reduce(0, +) / n
            a.kurt = dev.map { pow($0 / a.sd, 4) }.reduce(0, +) / n - 3
        }
        let wins = r.filter { $0 > 0 }, losses = r.filter { $0 <= 0 }
        a.win = Double(wins.count) / n
        a.winLo = CombiEngine.wilsonLower(wins.count, a.n)
        a.winHi = 1 - CombiEngine.wilsonLower(a.n - wins.count, a.n)
        a.avgWin = wins.isEmpty ? 0 : wins.reduce(0, +) / Double(wins.count)
        a.avgLoss = losses.isEmpty ? 0 : losses.reduce(0, +) / Double(losses.count)
        a.payoff = a.avgLoss < 0 ? a.avgWin / abs(a.avgLoss) : 0
        let gl = abs(losses.reduce(0, +))
        a.profitFactor = gl > 0 ? wins.reduce(0, +) / gl : (wins.isEmpty ? 0 : .infinity)
        a.expectancy = a.win * a.avgWin + (1 - a.win) * a.avgLoss
        a.kelly = a.payoff > 0 ? a.win - (1 - a.win) / a.payoff : 0
        a.tStat = a.sd > 0 ? a.mean / (a.sd / n.squareRoot()) : 0
        a.pValue = pNormal(a.tStat)
        // bootstrap 95% CI of the mean (seeded → stable numbers)
        var rng = SeededRandom(seed: 2026)
        var means: [Double] = []
        for _ in 0..<1000 {
            var sum = 0.0
            for _ in 0..<a.n { sum += r[Int.random(in: 0..<a.n, using: &rng)] }
            means.append(sum / n)
        }
        means.sort()
        a.bootLo = quantile(means, 0.025); a.bootHi = quantile(means, 0.975)
        // risk-adjusted, scaled to a year by the average holding period
        a.avgHold = Double(rows.map(\.tradingDaysSince).reduce(0, +)) / n
        let scale = a.avgHold > 0 ? (252 / a.avgHold).squareRoot() : 1
        a.sharpe = a.sd > 0 ? a.mean / a.sd * scale : 0
        let down = r.filter { $0 < 0 }
        let dd = down.isEmpty ? 0 : (down.map { $0 * $0 }.reduce(0, +) / Double(down.count)).squareRoot()
        a.sortino = dd > 0 ? a.mean / dd * scale : 0
        if a.avgHold >= 5 { a.annualized = (pow(1 + a.median / 100, 252 / a.avgHold) - 1) * 100 }
        // tails
        a.var5 = quantile(s, 0.05)
        let tail = s.prefix(max(1, a.n / 20))
        a.cvar5 = tail.reduce(0, +) / Double(tail.count)
        a.best = s.last ?? 0; a.worst = s.first ?? 0
        // excursions
        a.mfe = rows.map(\.peak).reduce(0, +) / n
        a.mae = rows.map(\.worst).reduce(0, +) / n
        a.edgeRatio = a.mae < 0 ? a.mfe / abs(a.mae) : 0
        // vs the Nifty
        let ex = rows.compactMap(\.excess)
        if ex.count >= 2 {
            let m = ex.reduce(0, +) / Double(ex.count)
            let sdx = (ex.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(ex.count - 1)).squareRoot()
            a.excess = m
            a.beatNifty = Double(ex.filter { $0 > 0 }.count) / Double(ex.count)
            a.infoRatio = sdx > 0 ? m / sdx : nil
        }
        // regime: market up vs down in the 21 days before the event
        let up = rows.filter { ($0.marketPre ?? 0) > 0 }.map(\.returnNow), dn = rows.filter { $0.marketPre != nil && $0.marketPre! <= 0 }.map(\.returnNow)
        if !up.isEmpty { a.upMarket = (up.count, up.reduce(0, +) / Double(up.count)) }
        if !dn.isEmpty { a.downMarket = (dn.count, dn.reduce(0, +) / Double(dn.count)) }
        // equal-weight equity curve from the average path → max drawdown
        if path.count > 2 {
            var peak = 1.0, mdd = 0.0
            for p in path {
                let eq = 1 + p.mean / 100
                peak = max(peak, eq)
                mdd = min(mdd, (eq / peak - 1) * 100)
            }
            a.maxDrawdown = mdd
        }
        return a
    }
}

struct AdvancedPerfPanel: View {
    let rows: [PerfRow]
    let path: [(day: Int, mean: Double, median: Double, count: Int)]
    @State private var open = true

    var body: some View {
        let a = PerfAdvanced.compute(rows, path: path)
        DisclosureGroup(isExpanded: $open) {
            if a.n < 2 {
                Text("Needs at least 2 events.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    verdict(a)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 150), alignment: .topLeading), count: 4), alignment: .leading, spacing: 10) {
                        tile("Average · median", "\(p(a.mean)) · \(p(a.median))", "95% CI of the mean (bootstrap) \(p(a.bootLo)) to \(p(a.bootHi))")
                        tile("Win rate", pc(a.win), "95% range \(pc(a.winLo))–\(pc(a.winHi)) (Wilson)")
                        tile("Profit factor", a.profitFactor.isInfinite ? "∞" : String(format: "%.2f", a.profitFactor), "gross wins ÷ gross losses (> 1.5 is strong)")
                        tile("Expectancy", p(a.expectancy), "per trade · payoff \(String(format: "%.2f", a.payoff)) (avg win \(p(a.avgWin)) / loss \(p(a.avgLoss)))")
                        tile("Sharpe · Sortino", String(format: "%.2f · %.2f", a.sharpe, a.sortino), "per trade, scaled to a year by the average hold (\(Int(a.avgHold)) d)")
                        tile("Significance", String(format: "t = %.2f", a.tStat), a.pValue < 0.001 ? "p < 0.001 — very unlikely to be luck" : String(format: "p = %.3f%@", a.pValue, a.pValue < 0.05 ? " — unlikely to be luck" : " — could be luck"))
                        tile("Tail risk", "VaR 5% \(p(a.var5))", "average of the worst 5% (CVaR) \(p(a.cvar5)) · worst \(p(a.worst))")
                        tile("Shape", String(format: "skew %.2f · kurt %.1f", a.skew, a.kurt), a.skew > 0.5 ? "a few big winners carry it (right tail)" : (a.skew < -0.5 ? "losses are the big ones (left tail)" : "fairly symmetric"))
                        tile("MFE · MAE", "\(p(a.mfe)) · \(p(a.mae))", String(format: "edge ratio %.2f — best gain on offer vs worst pain", a.edgeRatio))
                        tile("Kelly fraction", pc(max(0, a.kelly)), a.kelly <= 0 ? "no edge to size into" : "full-Kelly bet size; most traders use ¼–½ of it")
                        if let ex = a.excess, let b = a.beatNifty {
                            tile("vs Nifty 50", p(ex), "beat the Nifty in \(pc(b))" + (a.infoRatio.map { String(format: " · information ratio %.2f", $0) } ?? ""))
                        }
                        if let ann = a.annualized { tile("Annualised (median)", p(ann), "median return compounded over a year at the average hold") }
                        if let mdd = a.maxDrawdown { tile("Max drawdown", p(mdd), "equal-weight basket of every event, on the average path") }
                        if let u = a.upMarket, let d = a.downMarket {
                            tile("Market regime", "up \(p(u.avg)) · down \(p(d.avg))", "events after a rising Nifty (\(u.n)) vs a falling one (\(d.n)) in the 21 days before")
                        }
                    }
                    excursionChart
                    Text("MFE = best close after the event, MAE = worst close, both vs the entry. Ratios use each event once (they overlap in time, so treat them as indicative). Past behaviour, not a forecast.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        } label: {
            Label("Advanced statistics", systemImage: "function").font(.headline)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func verdict(_ a: PerfAdvanced) -> some View {
        let edge = a.mean > 0 && a.pValue < 0.05 && a.profitFactor > 1.2
        let weak = a.mean > 0 && !edge
        let text = edge ? "Real edge: positive, statistically significant (p \(a.pValue < 0.001 ? "< 0.001" : String(format: "= %.3f", a.pValue))) and wins outweigh losses \(String(format: "%.1f", a.profitFactor))×."
            : (weak ? "Positive on average, but not clearly beyond luck yet (p = \(String(format: "%.2f", a.pValue))) — more events will tell."
                    : "No edge: the average event lost or broke even.")
        return Label(text, systemImage: edge ? "checkmark.seal.fill" : (weak ? "questionmark.circle" : "xmark.octagon"))
            .foregroundStyle(edge ? Color.green : (weak ? Color.orange : Color.red))
            .font(.callout.bold())
    }

    private var excursionChart: some View {
        Chart {
            ForEach(rows) { r in
                PointMark(x: .value("Worst (MAE) %", r.worst), y: .value("Best (MFE) %", r.peak))
                    .foregroundStyle(r.returnNow >= 0 ? Color.green : Color.red)
                    .symbolSize(18)
            }
            RuleMark(x: .value("0", 0)).foregroundStyle(Color.secondary.opacity(0.4))
        }
        .chartXAxisLabel("Worst drop after the event (MAE, %)")
        .chartYAxisLabel("Best gain after the event (MFE, %)")
        .frame(height: 220)
    }

    private func tile(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
            Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func p(_ v: Double) -> String { String(format: "%+.1f%%", v) }
    private func pc(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}

import SwiftUI
import Charts

private func pctS(_ v: Double?, d: Int = 1) -> String { v.map { String(format: "%+.\(d)f%%", $0) } ?? "—" }
private func tone(_ v: Double?) -> Color { v == nil ? .secondary : (v! >= 0 ? .green : .red) }

// MARK: - Performance: portfolio curve vs Nifty, drawdown, each stock's return, distribution

struct WatchPerformanceView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let list: Watchlist
    let rows: [WatchRow]

    private struct Bar: Identifiable { let id: String; let v: Double }
    private struct Bucket: Identifiable { let id: String; let order: Int; let n: Int; let positive: Bool }

    var body: some View {
        let items = rows.map(\.item)
        let curve = WatchCurve.build(items, book: vm.priceBook, benchmark: ScreenerViewModel.benchmarkSymbol)
        let bars = rows.compactMap { r in r.r.sinceAdded.map { Bar(id: r.symbol + (r.item.exited ? " (exited)" : ""), v: $0) } }.sorted { $0.v > $1.v }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if curve.isEmpty {
                    Text("No prices yet — click Refresh prices.").foregroundStyle(.secondary).padding()
                } else {
                    let last = curve.last!
                    let maxDD = curve.map(\.drawdown).min() ?? 0
                    FlowLayout(spacing: 22, lineSpacing: 6) {
                        tile("List return (equal weight)", pctS(last.value), tone(last.value), "since \(curve.first!.day) · \(last.count) stocks")
                        tile("Nifty 50 same period", pctS(last.nifty), tone(last.nifty))
                        tile("Ahead of Nifty", pctS(last.nifty.map { last.value - $0 }), tone(last.nifty.map { last.value - $0 }))
                        tile("Worst drawdown", pctS(maxDD), maxDD < -10 ? .red : .orange, "from the curve's best")
                        tile("Best day of the curve", pctS(curve.map(\.value).max()), .green)
                    }
                    GroupBox("Equal-weight curve vs Nifty 50") {
                        Chart {
                            ForEach(curve) { p in
                                LineMark(x: .value("Day", p.date), y: .value("%", p.value), series: .value("Line", "This list"))
                                    .foregroundStyle(by: .value("Line", "This list"))
                            }
                            ForEach(curve.filter { $0.nifty != nil }) { p in
                                LineMark(x: .value("Day", p.date), y: .value("%", p.nifty!), series: .value("Line", "Nifty 50"))
                                    .foregroundStyle(by: .value("Line", "Nifty 50"))
                            }
                            RuleMark(y: .value("0", 0)).foregroundStyle(Color.gray.opacity(0.4))
                        }
                        .chartForegroundStyleScale(["This list": Color.blue, "Nifty 50": Color.orange])
                        .frame(height: 220)
                        Text("Each day: the average return of every stock added by then, each from its own added close (exited ones frozen at their exit).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    GroupBox("Drawdown") {
                        Chart(curve) { p in
                            AreaMark(x: .value("Day", p.date), y: .value("%", p.drawdown)).foregroundStyle(Color.red.opacity(0.35))
                        }
                        .frame(height: 110)
                    }
                }
                if !bars.isEmpty {
                    GroupBox("Return since added — each stock") {
                        Chart(bars) { b in
                            BarMark(x: .value("Stock", b.id), y: .value("%", b.v)).foregroundStyle(b.v >= 0 ? Color.green : Color.red)
                        }
                        .chartXAxis(bars.count > 25 ? .hidden : .automatic)
                        .frame(height: 220)
                    }
                    GroupBox("How the returns are spread") {
                        Chart(buckets(bars.map(\.v))) { b in
                            BarMark(x: .value("Return", b.id), y: .value("Stocks", b.n)).foregroundStyle(b.positive ? Color.green : Color.red)
                        }
                        .chartXScale(domain: buckets(bars.map(\.v)).sorted { $0.order < $1.order }.map(\.id))
                        .frame(height: 160)
                    }
                }
            }
            .padding(12)
        }
    }

    private func buckets(_ v: [Double]) -> [Bucket] {
        let edges: [(String, Double, Double)] = [("< −20%", -.infinity, -20), ("−20…−10", -20, -10), ("−10…−5", -10, -5), ("−5…0", -5, 0),
                                                ("0…5", 0, 5), ("5…10", 5, 10), ("10…20", 10, 20), ("20…50", 20, 50), ("> 50%", 50, .infinity)]
        return edges.enumerated().map { k, e in Bucket(id: e.0, order: k, n: v.filter { $0 >= e.1 && $0 < e.2 }.count, positive: e.1 >= 0) }
    }

    private func tile(_ t: String, _ v: String, _ c: Color, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.title3.bold().monospacedDigit()).foregroundStyle(c)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Analysis: what happened after adding, and which kinds of picks worked

struct WatchAnalysisView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let rows: [WatchRow]
    @State private var groupBy = "Added from"

    var body: some View {
        let s = WatchSummary(rows)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("After adding — forward returns") {
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            Text("After").gridColumnAlignment(.leading); Text("Stocks"); Text("Average"); Text("Median"); Text("Up")
                        }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(s.fwd) { f in
                            GridRow {
                                Text(f.label).gridColumnAlignment(.leading)
                                Text("\(f.n)").monospacedDigit()
                                Text(pctS(f.avg)).foregroundStyle(tone(f.avg)).monospacedDigit()
                                Text(pctS(f.median)).foregroundStyle(tone(f.median)).monospacedDigit()
                                Text(f.win.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit()
                            }
                        }
                    }
                    .padding(6)
                    Text("Only stocks added long enough ago count for each row.").font(.caption2).foregroundStyle(.secondary)
                }

                GroupBox("Hits") {
                    FlowLayout(spacing: 22, lineSpacing: 8) {
                        tile("Reached +10%", s.priced == 0 ? "—" : "\(s.hit10) of \(s.priced)", .green,
                             s.avgDaysTo10.map { String(format: "after %.0f trading days on avg", $0) })
                        tile("Fell to −10%", s.priced == 0 ? "—" : "\(s.hitMinus10) of \(s.priced)", .red)
                        tile("Target hit", s.withTarget == 0 ? "no targets set" : "\(s.targetHits) of \(s.withTarget)", .green)
                        tile("Stop hit", s.withStop == 0 ? "no stops set" : "\(s.stopHits) of \(s.withStop)", .red)
                        tile("Avg best close", pctS(s.avgBest), .green, "most it was up (MFE)")
                        tile("Avg worst close", pctS(s.avgWorst), .red, "most it was down (MAE)")
                        tile("Avg days held", s.avgDays.map { String(format: "%.0f", $0) } ?? "—", .primary)
                    }
                    .padding(6)
                }

                GroupBox {
                    let groups = WatchGroup.by(rows, key)
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow {
                            Text(groupBy).gridColumnAlignment(.leading); Text("Stocks"); Text("Avg return"); Text("Median"); Text("Up"); Text("vs Nifty"); Text("+22d avg")
                        }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(groups) { g in
                            GridRow {
                                Text(g.key).lineLimit(1).gridColumnAlignment(.leading)
                                Text("\(g.s.n)").monospacedDigit()
                                Text(pctS(g.s.avg)).foregroundStyle(tone(g.s.avg)).monospacedDigit()
                                Text(pctS(g.s.median)).foregroundStyle(tone(g.s.median)).monospacedDigit()
                                Text(g.s.winRate.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit()
                                Text(g.s.avgAlpha.map { String(format: "%+.1f", $0) } ?? "—").foregroundStyle(tone(g.s.avgAlpha)).monospacedDigit()
                                Text(pctS(g.s.fwd.last?.avg)).foregroundStyle(tone(g.s.fwd.last?.avg)).monospacedDigit()
                            }
                        }
                    }
                    .padding(6)
                } label: {
                    HStack {
                        Text("Which picks worked — by")
                        Picker("", selection: $groupBy) {
                            ForEach(["Added from", "Sector", "Tag", "Month added", "Days held"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    topList("Best 5", rows.filter { $0.r.sinceAdded != nil }.sorted { $0.r.sinceAdded! > $1.r.sinceAdded! }.prefix(5))
                    topList("Worst 5", rows.filter { $0.r.sinceAdded != nil }.sorted { $0.r.sinceAdded! < $1.r.sinceAdded! }.prefix(5))
                    topList("Gave back the most (from best close)", rows.filter { $0.r.fromPeak != nil }.sorted { $0.r.fromPeak! < $1.r.fromPeak! }.prefix(5), value: \.r.fromPeak)
                }
            }
            .padding(12)
        }
    }

    private func key(_ r: WatchRow) -> [String] {
        switch groupBy {
        case "Sector": return [r.sector]
        case "Tag": return r.item.tags.isEmpty ? ["no tag"] : r.item.tags
        case "Month added": return [MBEngine.monthTitle(r.month)]
        case "Days held":
            guard let d = r.r.tradingDays else { return ["—"] }
            return [d <= 5 ? "0–5 days" : d <= 22 ? "6–22 days" : d <= 66 ? "23–66 days" : "67+ days"]
        default: return [WatchlistView.sourceKind(r.item.source)]
        }
    }

    private func topList<S: Sequence>(_ title: String, _ rs: S, value: KeyPath<WatchRow, Double?> = \.r.sinceAdded) -> some View where S.Element == WatchRow {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rs)) { r in
                    HStack {
                        Text(r.symbol).fontWeight(.medium)
                        Spacer()
                        Text(pctS(r[keyPath: value])).foregroundStyle(tone(r[keyPath: value])).monospacedDigit()
                    }
                }
            }
            .padding(4)
            .frame(minWidth: 180)
        }
    }

    private func tile(_ t: String, _ v: String, _ c: Color, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.headline.monospacedDigit()).foregroundStyle(c)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Compare all watchlists

struct CompareListsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let rowsFor: (Watchlist) -> [WatchRow]
    @State private var activeOnly = true

    private struct Line: Identifiable { let id: UUID; let name: String; let color: String; let s: WatchSummary; let curve: Double?; let nifty: Double? }

    var body: some View {
        let lines: [Line] = vm.watchlists.map { l in
            let rs = rowsFor(l).filter { !activeOnly || !$0.item.exited }
            let c = WatchCurve.build(rs.map(\.item), book: vm.priceBook, benchmark: ScreenerViewModel.benchmarkSymbol).last
            return Line(id: l.id, name: l.name, color: l.color, s: WatchSummary(rs), curve: c?.value, nifty: c?.nifty)
        }
        let combined = WatchSummary(vm.watchlists.flatMap { rowsFor($0) }.filter { !activeOnly || !$0.item.exited })
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Compare watchlists").font(.title2.bold())
                    Spacer()
                    Toggle("Active stocks only", isOn: $activeOnly).toggleStyle(.checkbox)
                    Button { vm.fetchWatchPrices() } label: { Label("Refresh prices", systemImage: "arrow.clockwise") }.disabled(vm.isFetchingWatch)
                }
                GroupBox {
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("List").gridColumnAlignment(.leading); Text("Stocks"); Text("Avg return"); Text("Median"); Text("Up")
                            Text("vs Nifty"); Text("+5d"); Text("+22d"); Text("Hit +10%"); Text("Best"); Text("Worst")
                        }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(lines) { l in
                            GridRow {
                                HStack(spacing: 5) { Circle().fill(WatchlistView.color(l.color)).frame(width: 8, height: 8); Text(l.name).lineLimit(1) }
                                    .gridColumnAlignment(.leading)
                                    .onTapGesture { vm.selectedWatchlistID = l.id; UserDefaults.standard.set(WatchlistView.Tab.stocks.rawValue, forKey: "watch.tab") }
                                Text("\(l.s.n)").monospacedDigit()
                                Text(pctS(l.s.avg)).foregroundStyle(tone(l.s.avg)).monospacedDigit().fontWeight(.semibold)
                                Text(pctS(l.s.median)).foregroundStyle(tone(l.s.median)).monospacedDigit()
                                Text(l.s.winRate.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit()
                                Text(l.s.avgAlpha.map { String(format: "%+.1f", $0) } ?? "—").foregroundStyle(tone(l.s.avgAlpha)).monospacedDigit()
                                Text(pctS(l.s.fwd.first?.avg)).foregroundStyle(tone(l.s.fwd.first?.avg)).monospacedDigit()
                                Text(pctS(l.s.fwd.last?.avg)).foregroundStyle(tone(l.s.fwd.last?.avg)).monospacedDigit()
                                Text(l.s.priced == 0 ? "—" : "\(l.s.hit10)/\(l.s.priced)").monospacedDigit()
                                Text(l.s.best.map { "\($0.symbol) \(pctS($0.r.sinceAdded, d: 0))" } ?? "—").foregroundStyle(.green).lineLimit(1)
                                Text(l.s.worst.map { "\($0.symbol) \(pctS($0.r.sinceAdded, d: 0))" } ?? "—").foregroundStyle(.red).lineLimit(1)
                            }
                        }
                        Divider()
                        GridRow {
                            Text("All lists").bold().gridColumnAlignment(.leading)
                            Text("\(combined.n)").monospacedDigit()
                            Text(pctS(combined.avg)).foregroundStyle(tone(combined.avg)).bold()
                            Text(pctS(combined.median)).foregroundStyle(tone(combined.median))
                            Text(combined.winRate.map { String(format: "%.0f%%", $0) } ?? "—")
                            Text(combined.avgAlpha.map { String(format: "%+.1f", $0) } ?? "—").foregroundStyle(tone(combined.avgAlpha))
                            Text(pctS(combined.fwd.first?.avg)).foregroundStyle(tone(combined.fwd.first?.avg))
                            Text(pctS(combined.fwd.last?.avg)).foregroundStyle(tone(combined.fwd.last?.avg))
                            Text(combined.priced == 0 ? "—" : "\(combined.hit10)/\(combined.priced)")
                            Text(""); Text("")
                        }
                    }
                    .padding(6)
                    Text("Click a list's name to open it. Up = share of stocks above their added price. +5d / +22d = average return that many trading days after adding.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                let withAvg = lines.filter { $0.s.avg != nil }
                if !withAvg.isEmpty {
                    GroupBox("Average return by list") {
                        Chart(withAvg) { l in
                            BarMark(x: .value("List", l.name), y: .value("%", l.s.avg!)).foregroundStyle(l.s.avg! >= 0 ? Color.green : Color.red)
                            if let a = l.s.avgAlpha {
                                PointMark(x: .value("List", l.name), y: .value("%", a)).foregroundStyle(Color.orange).symbol(.diamond)
                            }
                        }
                        .frame(height: 200)
                        Text("Bars = average return · ◆ = average lead over Nifty 50").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }
}

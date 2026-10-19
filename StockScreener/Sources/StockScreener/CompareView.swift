import SwiftUI
import Charts

/// Compare saved indicator runs on the same footing (return after H trading days) and look for hidden patterns.
struct CompareView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    private let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .red, .mint]

    var body: some View {
        HStack(spacing: 0) {
            runList.frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                controls
                Divider()
                if let r = vm.compareResult, !r.stats.isEmpty {
                    ScrollView { content(r).padding(12) }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text(vm.perfRuns.isEmpty ? "Run a few studies first (one per indicator column)" : "Tick two or more saved runs and click Compare")
                            .font(.title3)
                        Text("Every study you run is saved here. Comparing them uses each stock's return exactly H trading days after its event, so a signal from 200 days ago and one from 30 days ago are judged on the same holding period.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if vm.compareResult == nil && vm.compareSelection.count >= 1 { vm.runComparison() } }
    }

    // MARK: Saved runs

    private var runList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved runs").font(.headline).padding(8)
            List {
                ForEach(vm.perfRuns) { run in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: { vm.compareSelection.contains(run.id) },
                                                 set: { on in if on { vm.compareSelection.insert(run.id) } else { vm.compareSelection.remove(run.id) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.title).lineLimit(1)
                            Text("\(run.study.column) · \(run.rows.count) stocks · \(run.runAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Delete run", role: .destructive) { vm.deleteRun(run.id) }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Button("Latest of each") {
                    var seen = Set<UUID>(); vm.compareSelection = []
                    for r in vm.perfRuns where !seen.contains(r.study.id) { seen.insert(r.study.id); vm.compareSelection.insert(r.id) }
                }
                Button("None") { vm.compareSelection = [] }
            }
            .controlSize(.small).padding(8)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Judge every stock").font(.callout)
            TextField("21", value: $vm.settings.perfCompareHorizon, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
            Text("trading days after its event · target").font(.callout)
            TextField("20", value: $vm.settings.perfCompareTarget, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
            Text("% · stop").font(.callout)
            TextField("10", value: $vm.settings.perfCompareStop, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
            Text("%").font(.callout)
            Spacer()
            if vm.isComparing { ProgressView().controlSize(.small) }
            Button { vm.runComparison() } label: { Label("Compare", systemImage: "arrow.triangle.branch") }
                .buttonStyle(.borderedProminent)
                .disabled(vm.compareSelection.isEmpty || vm.isComparing)
        }
        .padding(10)
    }

    // MARK: Results

    @ViewBuilder
    private func content(_ r: ComparisonResult) -> some View {
        let colors = Dictionary(r.stats.enumerated().map { ($1.runID, palette[$0 % palette.count]) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 16) {
            leaders(r, colors)
            insights(r)
            metricsTable(r, colors)
            HStack(alignment: .top, spacing: 14) {
                riskReturn(r, colors)
                speedChart(r, colors)
            }
            HStack(alignment: .top, spacing: 14) {
                pathChart(r, colors)
                distribution(r, colors)
            }
            if !r.pairs.isEmpty { headToHead(r) }
            patterns(r, colors)
            Text("Returns are close-to-close from the event day's Yahoo close to the close H trading days later. Only stocks with at least H days of history count; the speed curve also uses newer events until they run out of history (Kaplan–Meier). 95% ranges come from 1,000 bootstrap resamples. “vs Nifty” is approximate. Past results are not a forecast or financial advice.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func leaders(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        let byID = Dictionary(r.stats.map { ($0.runID, $0) }, uniquingKeysWith: { a, _ in a })
        func card(_ title: String, _ icon: String, _ id: UUID?, _ value: (IndicatorStats) -> String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon).font(.caption.bold()).foregroundStyle(.secondary)
                if let id, let s = byID[id] {
                    Text(s.name).font(.headline).foregroundStyle(c[id] ?? .primary).lineLimit(1)
                    Text(value(s)).font(.caption.monospacedDigit())
                } else {
                    Text("—").font(.headline)
                    Text("need ≥ 5 stocks").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
        return HStack(spacing: 10) {
            card("Most profitable", "trophy.fill", r.best.profit) { "median \(pct($0.median)) · mean \(pct($0.mean))" }
            card("Fastest to +\(fmt(vm.settings.perfCompareTarget))%", "hare.fill", r.best.fast) { s in
                s.kmMedianDays.map { "half get there in ~\($0) days" } ?? "\(Int(s.hitWithinH * 100))% within \(r.horizon) days"
            }
            card("Least risky", "shield.lefthalf.filled", r.best.safe) { "avg worst dip \(pct($0.avgMaxDown)) · worst 5% \(pct($0.cvar5))" }
            card("Best risk-adjusted", "scalemass.fill", r.best.riskAdjusted) { s in s.sortino.map { String(format: "Sortino %.2f", $0) } ?? "—" }
        }
    }

    private func insights(_ r: ComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hidden patterns & findings").font(.headline)
            if r.insights.isEmpty {
                Text("Nothing stands out yet — more stocks or runs will help.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(r.insights) { i in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: i.icon).foregroundStyle(i.solid ? Color.green : Color.orange).frame(width: 18)
                    Text(i.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(i.solid ? "solid" : "tentative").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill((i.solid ? Color.green : Color.orange).opacity(0.15)))
                        .foregroundStyle(i.solid ? Color.green : Color.orange)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func metricsTable(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        typealias Metric = (title: String, help: String, value: (IndicatorStats) -> Double?, text: (IndicatorStats) -> String, higherBetter: Bool)
        let metrics: [Metric] = [
            ("Stocks", "Stocks with at least H trading days since the event", { Double($0.n) }, { "\($0.n)" }, true),
            ("Median return", "Middle return after H days", { $0.median }, { pct($0.median) }, true),
            ("Mean return", "Average return after H days", { $0.mean }, { pct($0.mean) }, true),
            ("95% range of mean", "Bootstrap interval — if two ranges don't overlap, the difference is probably real", { $0.ciLow }, { "\(pct($0.ciLow)) … \(pct($0.ciHigh))" }, true),
            ("Win rate", "Share of stocks up after H days", { $0.winRate }, { String(format: "%.0f%%", $0.winRate * 100) }, true),
            ("Expectancy", "Avg win × win rate − avg loss × loss rate", { $0.expectancy }, { pct($0.expectancy) }, true),
            ("Profit factor", "Sum of gains ÷ sum of losses (> 1 = more gained than lost)", { $0.profitFactor }, { $0.profitFactor.map { String(format: "%.2f", $0) } ?? "∞" }, true),
            ("Avg best rise", "Highest close within H days, averaged", { $0.avgMaxUp }, { pct($0.avgMaxUp) }, true),
            ("Avg worst dip", "Lowest close within H days, averaged", { $0.avgMaxDown }, { pct($0.avgMaxDown) }, true),
            ("Worst 5% (CVaR)", "Average of the worst 5% of returns", { $0.cvar5 }, { pct($0.cvar5) }, true),
            ("Volatility", "Spread (standard deviation) of returns", { $0.std }, { String(format: "%.1f", $0.std) }, false),
            ("Sortino", "Mean return ÷ downside deviation (higher = better reward for the bad days)", { $0.sortino }, { $0.sortino.map { String(format: "%.2f", $0) } ?? "—" }, true),
            ("Hit target within H", "Reached +target at a close within H days", { $0.hitWithinH }, { String(format: "%.0f%%", $0.hitWithinH * 100) }, true),
            ("Days to target (median)", "Kaplan–Meier: when half the stocks reached +target", { $0.kmMedianDays.map { -Double($0) } }, { $0.kmMedianDays.map { "\($0)" } ?? "> history" }, true),
            ("Target before stop", "+target touched before −stop", { $0.targetFirst }, { String(format: "%.0f%%", $0.targetFirst * 100) }, true),
            ("Stop before target", "−stop touched before +target", { -$0.stopFirst }, { String(format: "%.0f%%", $0.stopFirst * 100) }, true),
            ("vs Nifty (approx.)", "Return minus the Nifty 50, scaled to H days", { $0.excess }, { $0.excess.map { String(format: "%+.1f pts", $0) } ?? "—" }, true),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Side by side — after \(r.horizon) trading days").font(.headline)
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(r.stats) { s in
                            Text(s.name).font(.caption.bold()).foregroundStyle(c[s.runID] ?? .primary).lineLimit(1).frame(maxWidth: 150, alignment: .trailing)
                        }
                    }
                    Divider()
                    ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in
                        let values = r.stats.filter { $0.n >= 5 }.compactMap { m.value($0) }
                        let best = m.higherBetter ? values.max() : values.min()
                        GridRow {
                            Text(m.title).font(.callout).help(m.help).gridColumnAlignment(.leading)
                            ForEach(r.stats) { s in
                                let isBest = s.n >= 5 && r.stats.count > 1 && m.value(s) != nil && m.value(s) == best && m.title != "Stocks"
                                Text(m.text(s)).font(.callout.monospacedDigit())
                                    .fontWeight(isBest ? .bold : .regular)
                                    .foregroundStyle(isBest ? Color.green : Color.primary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Text("Bold green = best in the row. Hover a metric for what it means.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func riskReturn(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        box("Risk vs return") {
            Chart(r.stats) { s in
                PointMark(x: .value("Average worst dip %", -s.avgMaxDown), y: .value("Mean return %", s.mean))
                    .symbolSize(CGFloat(max(40, min(400, s.n * 4))))
                    .foregroundStyle(c[s.runID] ?? .blue)
                    .annotation(position: .top) { Text(s.name).font(.caption2) }
                RuleMark(x: .value("CI", -s.avgMaxDown), yStart: .value("lo", s.ciLow), yEnd: .value("hi", s.ciHigh))
                    .foregroundStyle((c[s.runID] ?? .blue).opacity(0.4))
            }
            .chartXAxisLabel("Average worst dip within H (%) → riskier")
            .chartYAxisLabel("Mean return %")
            .frame(height: 240)
            Text("Top-left is best: high return, small dips. Bubble size = stocks; vertical line = 95% range.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func speedChart(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        box("Speed — share that reached +\(fmt(vm.settings.perfCompareTarget))%") {
            Chart {
                ForEach(r.stats) { s in
                    ForEach(s.kmCurve, id: \.day) { p in
                        LineMark(x: .value("Trading days", p.day), y: .value("Reached", p.reached * 100), series: .value("Indicator", s.name))
                            .foregroundStyle(c[s.runID] ?? .blue)
                            .interpolationMethod(.stepEnd)
                    }
                }
                RuleMark(y: .value("Half", 50)).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 3]))
            }
            .chartYAxisLabel("% of stocks")
            .chartXAxisLabel("Trading days after the event")
            .frame(height: 240)
            legend(r, c)
        }
    }

    private func pathChart(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        box("Average path over the \(r.horizon) days") {
            Chart {
                ForEach(r.stats) { s in
                    ForEach(s.avgPath, id: \.day) { p in
                        LineMark(x: .value("Day", p.day), y: .value("%", p.mean), series: .value("Indicator", s.name))
                            .foregroundStyle(c[s.runID] ?? .blue)
                    }
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.4))
            }
            .chartYAxisLabel("% from event close")
            .frame(height: 220)
            legend(r, c)
        }
    }

    private func distribution(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        box("Spread of returns (10th–90th percentile)") {
            Chart(r.stats) { s in
                RuleMark(x: .value("Indicator", s.name), yStart: .value("p10", s.percentiles.p10), yEnd: .value("p90", s.percentiles.p90))
                    .foregroundStyle((c[s.runID] ?? .blue).opacity(0.5))
                BarMark(x: .value("Indicator", s.name), yStart: .value("p25", s.percentiles.p25), yEnd: .value("p75", s.percentiles.p75), width: .fixed(26))
                    .foregroundStyle((c[s.runID] ?? .blue).opacity(0.75))
                PointMark(x: .value("Indicator", s.name), y: .value("Median", s.percentiles.p50))
                    .foregroundStyle(.white).symbolSize(30)
            }
            .chartYAxisLabel("Return after H days %")
            .frame(height: 220)
            Text("Box = middle half of stocks, line = 10th–90th, dot = median. Taller = less predictable.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func headToHead(_ r: ComparisonResult) -> some View {
        box("Head to head") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("A vs B").gridColumnAlignment(.leading); Text("Mean A − B"); Text("95% range"); Text("Chance A is better")
                    Text("Both flagged"); Text("Both"); Text("Only A"); Text("Only B")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(r.pairs) { p in
                    let clear = p.ciLow > 0 || p.ciHigh < 0
                    GridRow {
                        Text("\(p.a) vs \(p.b)").gridColumnAlignment(.leading).lineLimit(1)
                        Text(String(format: "%+.1f pts", p.diff)).foregroundStyle(p.diff >= 0 ? Color.green : Color.red).fontWeight(clear ? .bold : .regular)
                        Text(String(format: "%+.1f … %+.1f", p.ciLow, p.ciHigh)).foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", p.probABetter * 100))
                        Text("\(p.overlap)")
                        Text(p.bothMean.map(pct) ?? "—")
                        Text(p.onlyAMean.map(pct) ?? "—")
                        Text(p.onlyBMean.map(pct) ?? "—")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("Bold = the 95% range excludes zero, so one is probably really better. “Both flagged” = stocks both indicators picked.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func patterns(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            box("Confluence — flagged by how many indicators") {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("Indicators").gridColumnAlignment(.leading); Text("Stocks"); Text("Mean"); Text("Hit target") }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(r.confluence, id: \.count) { b in
                        GridRow {
                            Text(b.count >= 4 ? "4+" : "\(b.count)").gridColumnAlignment(.leading)
                            Text("\(b.n)")
                            Text(pct(b.mean)).foregroundStyle(b.mean >= 0 ? Color.green : Color.red)
                            Text(String(format: "%.0f%%", b.hit * 100))
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            patternTable("Market before the event (Nifty, 21 days)", r.regime, r, c)
            if !r.momentum.isEmpty { patternTable("Stock's own move before the event (21 days)", r.momentum, r, c) }
        }
    }

    private func patternTable(_ title: String, _ lines: [PatternLine], _ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        box(title) {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(r.stats) { s in Text(s.name).font(.caption2.bold()).foregroundStyle(c[s.runID] ?? .primary).lineLimit(1).frame(maxWidth: 90, alignment: .trailing) }
                    Text("All").font(.caption2.bold())
                }
                ForEach(lines) { l in
                    GridRow {
                        Text(l.label).font(.caption).gridColumnAlignment(.leading)
                        ForEach(r.stats) { s in
                            let v = l.values[s.runID]
                            Text(v.map { $0.n > 0 ? "\(pct($0.mean)) (\($0.n))" : "—" } ?? "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle((v?.n ?? 0) < 5 ? Color.secondary : ((v?.mean ?? 0) >= 0 ? Color.green : Color.red))
                        }
                        Text(l.pooled.n > 0 ? "\(pct(l.pooled.mean)) (\(l.pooled.n))" : "—").font(.caption.monospacedDigit().bold())
                    }
                }
            }
            Text("Mean return after H days (stocks). Grey = fewer than 5 stocks.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func box<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func legend(_ r: ComparisonResult, _ c: [UUID: Color]) -> some View {
        HStack(spacing: 10) {
            ForEach(r.stats) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(c[s.runID] ?? .blue).frame(width: 12, height: 3)
                    Text(s.name).font(.caption2).lineLimit(1)
                }
            }
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%+.1f%%", v) }
    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }
}

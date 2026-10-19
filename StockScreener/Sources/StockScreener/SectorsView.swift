import SwiftUI
import Charts

/// Sectors: momentum, relative strength vs Nifty (rotation map), trend, breadth, and a log of regime changes.
struct SectorsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @State private var tab = 0
    @State private var detail: SectorStat?
    @State private var showSettings = false
    @State private var sortOrder = [KeyPathComparator(\SectorRow.rank)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !vm.regimeBanner.isEmpty { banner; Divider() }
            if vm.sectorColumnIndex == nil {
                empty("No sector column found", "The app looks for a column named Sector or Industry. Pick it in Settings.")
            } else if let r = vm.sectorReport, !r.sectors.isEmpty {
                TabView(selection: $tab) {
                    momentumTable(r).tabItem { Text("Momentum") }.tag(0)
                    rotationMap(r).tabItem { Text("Rotation map") }.tag(1)
                    heatmap(r).tabItem { Text("Change heatmap") }.tag(2)
                    regimeLog.tabItem { Text("Regime changes\(vm.unseenRegimeCount > 0 ? " (\(vm.unseenRegimeCount))" : "")") }.tag(3)
                }
                .padding(10)
            } else if vm.isComputingSectors {
                ProgressView("Calculating…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                empty("Fetch Yahoo prices to start", "Prices for every stock in the sheet (about a year) and the Nifty 50. After that, a light top-up runs once a day when new sheet data arrives.")
            }
        }
        .navigationTitle("Sectors")
        .onAppear { if vm.sectorReport == nil { Task { await vm.computeSectors(notify: true) } } }
        .onChange(of: tab) { t in if t == 3 { vm.markRegimeSeen() } }
        .sheet(item: $detail) { s in SectorDetail(stat: s).environmentObject(vm) }
        .sheet(isPresented: $showSettings) { SectorSettings().environmentObject(vm) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            if let r = vm.sectorReport, !r.sectors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Market").font(.caption).foregroundStyle(.secondary)
                        Text(r.market.rawValue).font(.headline)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(regimeColor(r.market).opacity(0.18)))
                            .foregroundStyle(regimeColor(r.market))
                    }
                    Text(r.marketDetail).font(.caption).foregroundStyle(.secondary)
                }
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Data up to \(r.asOf)").font(.caption)
                    Text("\(r.pricedStocks) of \(r.totalStocks) stocks priced · \(r.sectors.count) sectors").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Sector momentum").font(.title2.bold())
            }
            Spacer()
            if let f = vm.sectorFetch {
                ProgressView(value: Double(f.0), total: Double(max(1, f.1))).frame(width: 140)
                Text("\(f.0)/\(f.1)").font(.caption.monospacedDigit())
            } else if vm.isComputingSectors {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await vm.updateSectorPrices(); await vm.computeSectors(notify: true) }
            } label: { Label("Update prices", systemImage: "arrow.down.circle") }
                .disabled(vm.sectorFetch != nil || vm.sectorColumnIndex == nil)
                .help("Yahoo: a year for stocks not yet loaded, a 1-month top-up for the rest")
            Button { showSettings = true } label: { Label("Alerts & settings", systemImage: "bell.badge") }
        }
        .padding(12)
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            Text("New regime change\(vm.regimeBanner.count == 1 ? "" : "s"): " +
                 vm.regimeBanner.prefix(4).map { "\($0.sector) → \($0.to)" }.joined(separator: " · ") +
                 (vm.regimeBanner.count > 4 ? " …" : ""))
                .font(.callout)
            Spacer()
            Button("View") { tab = 3; vm.markRegimeSeen() }
            Button { vm.regimeBanner = [] } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: Momentum table

    private func momentumTable(_ r: SectorReport) -> some View {
        let rows = r.sectors.map(SectorRow.init).sorted(using: sortOrder)
        return VStack(alignment: .leading, spacing: 6) {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("#", value: \.rank) { row in
                    HStack(spacing: 2) {
                        Text("\(row.rank)").monospacedDigit()
                        if let c = row.stat.rankChange5d, c != 0 {
                            Text(c > 0 ? "▲\(c)" : "▼\(-c)").font(.caption2).foregroundStyle(c > 0 ? Color.green : Color.red)
                        }
                    }
                    .help("Rank by momentum score; arrow = places moved in the last 5 trading days")
                }
                .width(55)
                TableColumn("Sector", value: \.name) { row in
                    Button(row.name) { detail = row.stat }.buttonStyle(.link).lineLimit(1)
                }
                .width(min: 120, ideal: 170)
                TableColumn("Score", value: \.score) { row in
                    HStack(spacing: 4) {
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2).fill(scoreColor(row.score))
                                .frame(width: g.size.width * row.score / 100)
                        }
                        .frame(width: 50, height: 8)
                        Text(String(format: "%.0f", row.score)).font(.caption.monospacedDigit())
                    }
                }
                .width(85)
                TableColumn("1W", value: \.r1w) { pctText($0.stat.r1w) }.width(58)
                TableColumn("1M", value: \.r1m) { pctText($0.stat.r1m) }.width(58)
                TableColumn("3M", value: \.r3m) { pctText($0.stat.r3m) }.width(58)
                TableColumn("vs Nifty 1M", value: \.vsNifty) { row in
                    Text(row.stat.vsNifty1m.map { String(format: "%+.1f", $0) } ?? "—").monospacedDigit()
                        .foregroundStyle((row.stat.vsNifty1m ?? 0) >= 0 ? Color.green : Color.red)
                }
                .width(75)
                TableColumn("Rotation", value: \.quadrantOrder) { row in quadrantBadge(row.stat.quadrant) }.width(90)
                TableColumn("Trend", value: \.trendOrder) { row in trendBadge(row.stat.trend) }.width(95)
                TableColumn("Breadth / 1 year", value: \.breadth) { row in
                    HStack(spacing: 6) {
                        Text("\(Int(row.stat.breadth * 100))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                            .help("Stocks above their own 50-day average")
                        Sparkline(values: row.stat.index, color: (row.stat.r1m ?? 0) >= 0 ? .green : .red).frame(width: 90, height: 18)
                    }
                }
            }
            Text("Score = rank-average of 1M and 3M change, RS-Momentum and breadth (0–100). Click a sector for its stocks. Sector index = equal-weight average of its stocks' daily changes (Yahoo closes).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Rotation map

    private func rotationMap(_ r: SectorReport) -> some View {
        let xs = r.sectors.flatMap { s in s.tail.map(\.ratio) } + [100]
        let ys = r.sectors.flatMap { s in s.tail.map(\.momentum) } + [100]
        let xr = (xs.min()! - 0.5)...(xs.max()! + 0.5), yr = (ys.min()! - 0.5)...(ys.max()! + 0.5)
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                RectangleMark(xStart: .value("x", xr.lowerBound), xEnd: .value("x", 100), yStart: .value("y", 100), yEnd: .value("y", yr.upperBound))
                    .foregroundStyle(Color.blue.opacity(0.06))
                RectangleMark(xStart: .value("x", 100), xEnd: .value("x", xr.upperBound), yStart: .value("y", 100), yEnd: .value("y", yr.upperBound))
                    .foregroundStyle(Color.green.opacity(0.08))
                RectangleMark(xStart: .value("x", 100), xEnd: .value("x", xr.upperBound), yStart: .value("y", yr.lowerBound), yEnd: .value("y", 100))
                    .foregroundStyle(Color.yellow.opacity(0.08))
                RectangleMark(xStart: .value("x", xr.lowerBound), xEnd: .value("x", 100), yStart: .value("y", yr.lowerBound), yEnd: .value("y", 100))
                    .foregroundStyle(Color.red.opacity(0.06))
                ForEach(r.sectors) { s in
                    ForEach(Array(s.tail.enumerated()), id: \.offset) { i, p in
                        LineMark(x: .value("RS-Ratio", p.ratio), y: .value("RS-Momentum", p.momentum), series: .value("Sector", s.name))
                            .foregroundStyle(quadrantColor(s.quadrant).opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    PointMark(x: .value("RS-Ratio", s.rsRatio), y: .value("RS-Momentum", s.rsMomentum))
                        .foregroundStyle(quadrantColor(s.quadrant))
                        .annotation(position: .top, spacing: 2) { Text(s.name).font(.system(size: 9)) }
                }
            }
            .chartXScale(domain: xr)
            .chartYScale(domain: yr)
            .chartXAxisLabel("RS-Ratio (relative strength vs Nifty, 100 = its 50-day norm)")
            .chartYAxisLabel("RS-Momentum")
            .overlay(alignment: .topLeading) { Text("Improving").font(.caption.bold()).foregroundStyle(.blue).padding(6) }
            .overlay(alignment: .topTrailing) { Text("Leading").font(.caption.bold()).foregroundStyle(.green).padding(6) }
            .overlay(alignment: .bottomTrailing) { Text("Weakening").font(.caption.bold()).foregroundStyle(.orange).padding(.bottom, 30).padding(6) }
            .overlay(alignment: .bottomLeading) { Text("Lagging").font(.caption.bold()).foregroundStyle(.red).padding(.bottom, 30).padding(.leading, 40) }
            Text("Each line is the last 10 trading days, ending at the dot. Sectors usually rotate clockwise: Improving → Leading → Weakening → Lagging. This is an approximation of a relative rotation graph built from Yahoo closes.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Heatmap (state changes over time)

    private func heatmap(_ r: SectorReport) -> some View {
        let days = Array((r.sectors.first?.history.map(\.day) ?? []).suffix(30))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(Quadrant.allCases, id: \.self) { q in
                    HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(quadrantColor(q)).frame(width: 12, height: 12); Text(q.rawValue).font(.caption) }
                }
                Spacer()
                Text("Rotation state per trading day · ● = trend flipped that day").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        Text("").frame(width: 150)
                        ForEach(days, id: \.self) { d in
                            Text(String(d.suffix(5))).font(.system(size: 8)).rotationEffect(.degrees(-60)).frame(width: 18, height: 30)
                        }
                    }
                    GridRow {
                        Text("Market").font(.caption.bold()).frame(width: 150, alignment: .leading)
                        ForEach(days, id: \.self) { d in
                            let m = r.marketHistory.first { $0.day == d }
                            RoundedRectangle(cornerRadius: 2).fill(m.map { regimeColor($0.regime) } ?? .clear)
                                .frame(width: 18, height: 14)
                                .help(m.map { "\(d): \($0.regime.rawValue), breadth \(Int($0.breadth * 100))%" } ?? d)
                        }
                    }
                    ForEach(r.sectors) { s in
                        let byDay = Dictionary(s.history.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
                        GridRow {
                            Text(s.name).font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
                            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                                let st = byDay[d]
                                let prev = i > 0 ? byDay[days[i - 1]] : nil
                                ZStack {
                                    RoundedRectangle(cornerRadius: 2).fill(st.map { quadrantColor($0.quadrant) } ?? Color.clear)
                                    if let st, let prev, st.trend != prev.trend {
                                        Circle().fill(Color.white).frame(width: 5, height: 5)
                                    }
                                }
                                .frame(width: 18, height: 14)
                                .help(st.map { "\(s.name) \(d): \($0.quadrant.rawValue), \($0.trend.rawValue), score \(Int($0.score))" } ?? d)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    // MARK: Regime log

    private var regimeLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            let detected = vm.sectorReport?.changes ?? []
            Text("Confirmed changes (held for \(vm.settings.regimeConfirmDays) day\(vm.settings.regimeConfirmDays == 1 ? "" : "s")) over the last 40 trading days. Bell = notified.")
                .font(.caption).foregroundStyle(.secondary)
            List(detected) { c in
                HStack(spacing: 10) {
                    Image(systemName: icon(c.kind)).foregroundStyle(color(c)).frame(width: 18)
                    Text(c.day).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text(c.sector).fontWeight(.semibold).frame(minWidth: 120, alignment: .leading)
                    Text(c.from).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2)
                    Text(c.to).fontWeight(.semibold).foregroundStyle(color(c))
                    Spacer()
                    Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if vm.regimeLog.contains(where: { $0.id == c.id }) {
                        Image(systemName: "bell.fill").foregroundStyle(.orange).help("Notified")
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: Helpers

    private func empty(_ title: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.topleft.filled").font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pctText(_ v: Double?) -> some View {
        Text(v.map { String(format: "%+.1f%%", $0) } ?? "—").monospacedDigit()
            .foregroundStyle(v == nil ? Color.secondary : (v! >= 0 ? Color.green : Color.red))
    }

    private func quadrantBadge(_ q: Quadrant) -> some View {
        Text(q.rawValue).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(quadrantColor(q).opacity(0.18))).foregroundStyle(quadrantColor(q))
    }

    private func trendBadge(_ t: Trend) -> some View {
        Label(t.rawValue, systemImage: t == .up ? "arrow.up.right" : (t == .down ? "arrow.down.right" : "arrow.right"))
            .font(.caption).foregroundStyle(t == .up ? Color.green : (t == .down ? Color.red : Color.secondary))
    }

    private func icon(_ k: RegimeChange.Kind) -> String {
        switch k { case .rotation: return "arrow.triangle.2.circlepath"; case .trend: return "chart.line.uptrend.xyaxis"; case .market: return "globe" }
    }

    private func color(_ c: RegimeChange) -> Color {
        switch c.to {
        case Quadrant.leading.rawValue, Trend.up.rawValue, MarketRegime.riskOn.rawValue: return .green
        case Quadrant.lagging.rawValue, Trend.down.rawValue, MarketRegime.riskOff.rawValue: return .red
        case Quadrant.improving.rawValue: return .blue
        case Quadrant.weakening.rawValue: return .orange
        default: return .secondary
        }
    }
}

func quadrantColor(_ q: Quadrant) -> Color {
    switch q { case .leading: return .green; case .weakening: return .orange; case .lagging: return .red; case .improving: return .blue }
}

func regimeColor(_ r: MarketRegime) -> Color {
    switch r { case .riskOn: return .green; case .neutral: return .orange; case .riskOff: return .red }
}

func scoreColor(_ s: Double) -> Color { s >= 66 ? .green : (s >= 33 ? .orange : .red) }

/// Sortable wrapper for the momentum table.
struct SectorRow: Identifiable {
    let stat: SectorStat
    init(_ s: SectorStat) { stat = s }
    var id: String { stat.name }
    var name: String { stat.name }
    var rank: Int { stat.rank }
    var score: Double { stat.score }
    private static let missing = -Double.greatestFiniteMagnitude
    var r1w: Double { stat.r1w ?? Self.missing }
    var r1m: Double { stat.r1m ?? Self.missing }
    var r3m: Double { stat.r3m ?? Self.missing }
    var vsNifty: Double { stat.vsNifty1m ?? Self.missing }
    var breadth: Double { stat.breadth }
    var quadrantOrder: Int { [Quadrant.leading, .improving, .weakening, .lagging].firstIndex(of: stat.quadrant) ?? 0 }
    var trendOrder: Int { stat.trend == .up ? 0 : (stat.trend == .sideways ? 1 : 2) }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max(), hi > lo else { return }
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: size.width * Double(i) / Double(values.count - 1),
                                 y: size.height * (1 - (v - lo) / (hi - lo)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(color), lineWidth: 1.2)
        }
    }
}

/// One sector: index vs Nifty, state history, and its stocks.
struct SectorDetail: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    let stat: SectorStat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(stat.name).font(.title2.bold())
                Text("#\(stat.rank) · score \(Int(stat.score))").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 18) {
                metric("1W", stat.r1w); metric("1M", stat.r1m); metric("3M", stat.r3m); metric("6M", stat.r6m)
                VStack(alignment: .leading) { Text("Breadth").font(.caption).foregroundStyle(.secondary); Text("\(Int(stat.breadth * 100))%").font(.title3.bold()) }
                VStack(alignment: .leading) {
                    Text("Rotation · trend").font(.caption).foregroundStyle(.secondary)
                    Text("\(stat.quadrant.rawValue) · \(stat.trend.rawValue)").font(.title3.bold()).foregroundStyle(quadrantColor(stat.quadrant))
                }
            }
            Chart {
                ForEach(Array(stat.index.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Day", i), y: .value("Index", v)).foregroundStyle(quadrantColor(stat.quadrant))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel("Sector index (equal weight)")
            .frame(height: 160)
            Text("Score over the last \(stat.history.count) trading days").font(.headline)
            Chart(stat.history, id: \.day) { h in
                BarMark(x: .value("Day", h.day), y: .value("Score", h.score)).foregroundStyle(quadrantColor(h.quadrant))
            }
            .chartXAxis(.hidden)
            .frame(height: 90)
            Text("Stocks (\(stat.priced) priced of \(stat.members)) — best 1M").font(.headline)
            List(stat.topMembers, id: \.0) { sym, r in
                HStack {
                    Text(sym).fontWeight(.semibold)
                    Spacer()
                    Text(String(format: "%+.1f%%", r)).monospacedDigit().foregroundStyle(r >= 0 ? Color.green : Color.red)
                }
                .contextMenu {
                    ForEach(vm.watchlists) { list in Button("Add to “\(list.name)”") { vm.addSymbols([sym], listID: list.id) } }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
        .padding(16)
        .frame(width: 640, height: 640)
    }

    private func metric(_ t: String, _ v: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v.map { String(format: "%+.1f%%", $0) } ?? "—").font(.title3.bold().monospacedDigit())
                .foregroundStyle((v ?? 0) >= 0 ? Color.green : Color.red)
        }
    }
}

/// Sector column and regime-alert settings.
struct SectorSettings: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Sectors") {
                Picker("Sector column", selection: $vm.settings.sectorColumn) {
                    Text("Auto (\(vm.sectorColumnIndex.map { vm.headers[$0] } ?? "not found"))").tag("")
                    ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Ignore sectors with fewer than \(vm.settings.sectorMinMembers) priced stocks", value: $vm.settings.sectorMinMembers, in: 1...20)
                Toggle("Top up Yahoo prices once a day when new sheet data arrives", isOn: $vm.settings.sectorAutoUpdate)
            }
            Section {
                Stepper("Confirm a change after \(vm.settings.regimeConfirmDays) day\(vm.settings.regimeConfirmDays == 1 ? "" : "s") in the new state",
                        value: $vm.settings.regimeConfirmDays, in: 1...5)
                Toggle("Rotation changes (Leading / Weakening / Lagging / Improving)", isOn: $vm.settings.regimeNotifyRotation)
                Toggle("Trend changes (Uptrend / Sideways / Downtrend)", isOn: $vm.settings.regimeNotifyTrend)
                Toggle("Market regime changes (Risk-on / Mixed / Risk-off)", isOn: $vm.settings.regimeNotifyMarket)
                Toggle("Only major changes (into Leading or Lagging, into Up- or Downtrend, market flips)", isOn: $vm.settings.regimeMajorOnly)
                Toggle("Also email me (uses the email set up in Email & Rules)", isOn: $vm.settings.regimeEmail)
            } header: {
                Text("Regime-change notifications")
            } footer: {
                Text("Checked after each sheet update. New changes from the last 5 trading days show as a macOS notification, a banner on this screen, and in the Regime changes tab. A longer confirmation means fewer false alarms but later alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                    Task { await vm.computeSectors(notify: false) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 520)
    }
}

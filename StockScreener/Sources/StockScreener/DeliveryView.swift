import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Delivery Analysis: NSE delivery quantity history per stock (from the daily bhavdata files) and the
/// Pine-style signal "ta.highest(DELIV_QTY, 300) updated", highlighted on a Yahoo candle chart.
struct DeliveryView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var dc = DeliveryCenter.shared

    @AppStorage("chart.styleRev") private var mainStyleRev = 0
    @AppStorage("delsmac.shade2") private var mainShadeLevel = 90.0
    @State private var showRepair = false
    @AppStorage("deliv.length") private var length = 300
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue
    @AppStorage("deliv.jumpMode") private var jumpMode = 0
    private var metric: DeliveryMetric { DeliveryMetric(rawValue: metricRaw) ?? .value }
    @AppStorage("deliv.onlyRises") private var onlyRises = true
    @AppStorage("deliv.full") private var full = true
    @AppStorage("deliv.within") private var within = 5
    @AppStorage("deliv.scope") private var scope = "Sheet stocks"
    @AppStorage("deliv.range") private var range = "1Y"
    @AppStorage("deliv.target") private var target = 600

    @State private var search = ""
    @State private var selected: String?
    @State private var rows: [DelivRow] = []          // signal in the last N days, in scope
    @State private var allRows: [DelivRow] = []       // every stock with delivery data (for search)
    @AppStorage("deliv.pane") private var pane = "Chart"
    @State private var computing = false
    @State private var candles: [YahooClient.Candle] = []
    @State private var chartError: String?
    @State private var loadingChart = false
    @StateObject private var lw = LWChartHolder()
    @AppStorage("deliv.layers") private var layersRaw = ""
    @ObservedObject private var newsTL = NewsTimeline.shared
    @ObservedObject private var i5m = Intraday5mCenter.shared
    @ObservedObject private var dealsC = DealsCenter.shared
    @ObservedObject private var fmarks = FormulaMarks.shared
    @ObservedObject private var pine = PineCenter.shared
    @AppStorage("t3.rev") private var t3Rev = 0
    @Environment(\.colorScheme) private var colorScheme

    struct DelivRow: Identifiable {
        var id: String { symbol }
        let symbol: String
        let lastSignal: String?        // day
        let barsAgo: Int?              // trading days since
        let qty: Double                // DELIV_QTY on the last signal (or latest day)
        let per: Double                // DELIV_PER that day
        let xAvg: Double?              // that qty ÷ average of the window
        let signals: Int
        let latestQty: Double
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if dc.storedDays.isEmpty && !dc.isFetching && !dc.isLoading {
                empty
            } else {
                HSplitView {
                    list.frame(minWidth: 380, idealWidth: 470, maxWidth: 620)
                    chartArea.frame(minWidth: 520)
                }
            }
        }
        .navigationTitle("Delivery Analysis")
        .task(id: selected) { if let s = selected { MBNoteFocus.shared.setChart(s, day: nil) } }
        .onAppear { dc.loadIfNeeded(); recompute() }
        .onChange(of: dc.revision) { _ in recompute(); pushChart() }
        .onChange(of: length) { _ in recompute() }
        .onChange(of: onlyRises) { _ in recompute() }
        .onChange(of: full) { _ in recompute() }
        .onChange(of: metricRaw) { _ in recompute(); DeliveryCenter.shared.refreshColumns() }   // STREAK / HI/T3 follow the signal SMA
        .onChange(of: within) { _ in recompute() }
        .onChange(of: scope) { _ in recompute() }
        .onChange(of: selected) { s in loadCandles(s); pushChart() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 10, lineSpacing: 6) {
                if dc.isFetching {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(dc.progress.done), total: Double(max(1, dc.progress.total))).frame(width: 160)
                        Button("Stop") { dc.cancel() }
                    }.fixedSize()
                } else {
                    HStack(spacing: 6) {
                        Button { dc.download(target: target) } label: {
                            Label(dc.storedDays.isEmpty ? "Download \(target) days from NSE" : "Update now", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        Picker("", selection: $target) {
                            ForEach([300, 450, 600, 750], id: \.self) { Text("\($0) days").tag($0) }
                        }
                        .labelsHidden().help("How many trading days of history to keep complete")
                    }.fixedSize()
                }
                if dc.isLoading { HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Reading…").font(.caption) }.fixedSize() }
                if !dc.isFetching && !dc.storedDays.isEmpty {
                    Button { showRepair = true } label: { Label("Check now", systemImage: "wrench.and.screwdriver") }.fixedSize()
                        .help("Repair NSE data: re-reads the trading calendar, fetches every missing day from several NSE sources with retries, and fills single-stock holes")
                        .sheet(isPresented: $showRepair) { NSERepairView().environmentObject(vm) }
                }
                Text(storedText).font(.caption).foregroundStyle(.secondary).fixedSize()
                HStack(spacing: 4) {
                    if i5m.busy { ProgressView(value: Double(i5m.progress.0), total: Double(max(1, i5m.progress.1))).frame(width: 80) }
                    Text(i5m.status ?? i5m.summary).font(.caption).foregroundStyle(.secondary)
                    Button("Update 5-min") { i5m.update(vm.allSymbols, force: true) }.disabled(i5m.busy)
                        .help("Yahoo 5-minute bars for the Filter's MOR / DAY columns (60 days the first time, then new days; runs by itself daily after 15:40)")
                }.fixedSize()
            }
            if let st = dc.status {
                Text(st).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(st)
            }
            FlowLayout(spacing: 14, lineSpacing: 8) {
                HStack(spacing: 4) {
                    Text("Signal").font(.caption.bold())
                    Text("ta.highest(").font(.caption.monospaced())
                    Picker("", selection: $metricRaw) {
                        ForEach(DeliveryMetric.allCases) { m in Text(m.pine).tag(m.rawValue) }
                    }
                    .labelsHidden()
                    .help("DELIV_QTY × CLOSE_PRICE = value of shares delivered that day (₹); the SMAs smooth it over 22 / 66 days")
                    Text(",").font(.caption.monospaced())
                    TextField("", value: $length, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
                    Text(")").font(.caption.monospaced())
                    Picker("", selection: $onlyRises) {
                        Text("makes a new high").tag(true)
                        Text("changes (any update)").tag(false)
                    }
                    .labelsHidden()
                    .help("New high = the highest rises. Any update = exactly Pine's ta.change(ta.highest(...)) != 0, which also fires when an old high leaves the window.")
                }.fixedSize()
                Toggle("Wait for full \(length) days (Pine na)", isOn: $full).toggleStyle(.checkbox).fixedSize()
                HStack(spacing: 4) {
                    Text("JUMP =").font(.caption)
                    Picker("", selection: $jumpMode) {
                        Text("percentrank now ÷ its previous peak").tag(0)
                        Text("value now ÷ previous \(length)-day high").tag(1)
                    }
                    .labelsHidden()
                    .help("The Filter's JUMP column. 1: ta.percentrank(DELIV_QTY*close, 300) today ÷ the percent rank's previous peak. 2: DELIV_QTY*close today ÷ the previous (different) ta.highest(DELIV_QTY*close, 300).")
                    .onChange(of: jumpMode) { _ in DeliveryCenter.shared.refreshColumns() }
                }.fixedSize()
                IndicatorSettingsButton().fixedSize()
                HStack(spacing: 4) {
                    Text("Within last").font(.caption)
                    Stepper("\(within) day\(within == 1 ? "" : "s")", value: $within, in: 1...250)
                }.fixedSize()
                Picker("", selection: $scope) {
                    ForEach(["Sheet stocks", "My Filter", "All NSE"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { if let s = selected { UserDefaults.standard.set(s, forKey: "news.symbol") }; openWindow(id: "newschart") } label: { Label("News & Deals", systemImage: "newspaper") }.fixedSize()
                    .help("Candle chart with news labelled by Groq (3–4 words) and NSE bulk / block deals (⌥⌘N)")
                Button { copyPine() } label: { Label("Copy Pine Script", systemImage: "doc.on.clipboard") }.fixedSize()
                    .help("A TradingView indicator that paints these exact signal days (orange + ▲DQ) on your TradingView charts — for the stocks in the selected scope")
                SymbolField(vm: vm, placeholder: "Search any NSE stock", text: $search).frame(width: 200)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var metricName: String { metric.pine }

    private var storedText: String {
        guard let a = dc.storedDays.first, let b = dc.storedDays.last else { return "No delivery data yet" }
        let mb = Double(DeliveryFiles.totalBytes()) / 1_048_576
        let g = dc.gaps.count
        return "\(dc.storedDays.count) trading days (\(a) → \(b)) · \(dc.book.series.count) symbols · \(String(format: "%.1f", mb)) MB"
            + (dc.calendar.isEmpty ? "" : (g == 0 ? " · ✓ matches NSE trading calendar" : " · ⚠️ \(g) trading day\(g == 1 ? "" : "s") missing"))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Delivery Analysis").font(.title2.bold())
            Text("Downloads NSE's daily delivery file (sec_bhavdata_full) for each trading day — weekends are skipped, holidays are remembered — and stores it compressed. Then it marks every day where ta.highest(\(metricName), \(length)) updates, on a Yahoo candle chart.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 600)
            Text("The first download is about \(target) files (several hundred MB in total from NSE, ~\(target / 30)–\(target / 15) MB kept) and takes a while. After that only new days are fetched, once an hour while the app runs.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 600)
            Button("Download \(target) days from NSE") { dc.download(target: target) }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    /// No search: the signal list. Searching: every NSE stock with delivery data (any scope, any date).
    private var shownRows: [DelivRow] {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        guard !q.isEmpty else { return rows }
        return allRows.filter { $0.symbol.contains(q) }
            .sorted { ($0.symbol.hasPrefix(q) ? 0 : 1, $0.symbol) < ($1.symbol.hasPrefix(q) ? 0 : 1, $1.symbol) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text(search.isEmpty ? "\(shownRows.count) stocks with a signal in the last \(within) trading day\(within == 1 ? "" : "s")"
                                    : "\(shownRows.count) of \(allRows.count) NSE stocks match “\(search)” (all stocks, any date)").font(.caption.bold())
                if computing { ProgressView().controlSize(.mini) }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Table(shownRows, selection: $selected) {
                TableColumn("Symbol") { r in SymbolWithDots(symbol: r.symbol) }.width(min: 110, ideal: 130)
                TableColumn("Signal day") { r in Text(r.lastSignal ?? "—").monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Ago") { r in Text(r.barsAgo.map { $0 == 0 ? "today" : "\($0)d" } ?? "—").monospacedDigit() }.width(min: 40, ideal: 48)
                TableColumn(metric.short) { r in Text(Self.short(r.qty)).monospacedDigit() }.width(min: 70, ideal: 85)
                TableColumn("× avg") { r in Text(r.xAvg.map { String(format: "%.1f×", $0) } ?? "—").monospacedDigit() }.width(min: 45, ideal: 52)
                TableColumn("Deliv %") { r in Text(String(format: "%.0f%%", r.per)).monospacedDigit() }.width(min: 45, ideal: 52)
                TableColumn("Signals") { r in Text("\(r.signals)").monospacedDigit().foregroundStyle(.secondary) }.width(min: 40, ideal: 50)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let s = ids.first {
                    Button("Open TradingView chart") { vm.openChart(s, queue: shownRows.map(\.symbol), openWindow: openWindow) }
                    WatchlistSubmenu(symbols: Array(ids), source: "Delivery")
                    Button("Copy symbols") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shownRows.map(\.symbol).joined(separator: ", "), forType: .string)
                    }
                }
            } primaryAction: { ids in
                if let s = ids.first { vm.openChart(s, queue: shownRows.map(\.symbol), openWindow: openWindow) }
            }
        }
    }

    // MARK: Chart

    private struct DelivPoint: Identifiable { var id: String { day }; let day: String; let date: Date; let qty: Double; let high: Double?; let signal: Bool }

    private var chartArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = selected, dc.book.series[s] != nil {
                HStack(spacing: 8) {
                    Text(s).font(.title3.bold()).fixedSize()
                    if let c = candles.last { Text(String(format: "%.2f", c.close)).font(.headline.monospacedDigit()).fixedSize() }
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("Scroll / pinch = zoom · drag = pan · double-click the date axis = reset")
                    Spacer(minLength: 8)
                    if pane == "Chart" {
                        ChartStyleButton().controlSize(.small)
                        DelsmacLevelControl(level: $mainShadeLevel).controlSize(.small)
                        ChartLayersButton(raw: $layersRaw, metric: metric.pine, length: length).controlSize(.small).fixedSize()
                        if ChartLayer.decode(layersRaw).contains(.fmark) { FormulaMarkControl(symbol: s).controlSize(.small) }
                        PineButton().controlSize(.small)
                    }
                    Picker("", selection: $pane) { Text("Chart").tag("Chart"); Text("Data").tag("Data") }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Picker("", selection: $range) { ForEach(["6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .opacity(pane == "Chart" ? 1 : 0.4)
                    QuickFButton()
                    Button("TradingView") { vm.openChart(s, queue: shownRows.map(\.symbol), openWindow: openWindow) }.controlSize(.small).fixedSize()
                }
                if let series = dc.book.series[s] { stats(series) }
                if loadingChart { ProgressView("Yahoo prices…").controlSize(.small) }
                if let e = chartError { Text("Yahoo: \(e) — showing delivery only").font(.caption).foregroundStyle(.orange) }
                if pane == "Data", let series = dc.book.series[s] {
                    DeliveryDataTable(symbol: s, series: series, metric: metric, length: max(2, length), full: full, onlyRises: onlyRises,
                                      calendar: dc.calendar, lastDay: dc.book.days.last ?? "")
                } else {
                    LWChartView(holder: lw)
                        .frame(minHeight: 380)
                        .dealRankPopup(lw, symbol: SymbolBook.clean(s))
                    if !lw.hoverLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lw.hoverLines.prefix(4).enumerated()), id: \.offset) { _, l in Text(l).font(.caption).lineLimit(1).help(l) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if let sym = selected, let s = dc.book.series[SymbolBook.clean(sym)] { DelsmacBadge(series: s, day: lw.crossDay) }
                    Text("Orange bands + ▲DQ = ta.highest(\(metricName), \(length)) \(onlyRises ? "made a new high" : "updated") · bars at the bottom = \(metricName) · blue = the rolling highest")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("Select a stock to see its candles with delivery highs marked.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .onChange(of: candles.count) { _ in pushChart() }
        .onChange(of: range) { _ in pushChart() }
        .onChange(of: metricRaw) { _ in pushChart() }
        .onChange(of: length) { _ in pushChart() }
        .onChange(of: onlyRises) { _ in pushChart() }
        .onChange(of: full) { _ in pushChart() }
        .onChange(of: colorScheme) { _ in pushChart() }
        .onChange(of: layersRaw) { _ in pushChart() }
        .onChange(of: mainStyleRev) { _ in pushChart() }
        .onChange(of: mainShadeLevel) { _ in pushChart() }
        .onChange(of: t3Rev) { _ in pushChart() }
        .onChange(of: newsTL.revision) { _ in pushChart() }
        .onChange(of: dealsC.revision) { _ in pushChart() }
        .onChange(of: fmarks.revision) { _ in pushChart() }
        .onChange(of: pine.revision) { _ in pushChart() }
        .onAppear { if ChartLayer.decode(layersRaw).contains(.deals) { DealsCenter.shared.update(days: 1800) } }
    }

    /// One-line summary of the stock's delivery pattern.
    private func stats(_ s: DeliverySeries) -> some View {
        let c = DeliveryColumns.of(s, latestDay: s.days.last ?? "")
        let have = Set(s.days)
        let missing = dc.calendar.filter { $0 >= (s.days.first ?? "") && $0 <= (dc.book.days.last ?? "") && !have.contains($0) }
        let m = s.metric(metric)
        let h = DeliverySignal.highest(m, length: max(2, length), full: full).last ?? nil
        let sig = DeliverySignal.signals(m, length: max(2, length), full: full, onlyRises: onlyRises)
        let p20 = s.per.suffix(20), p100 = s.per.suffix(100)
        let avg20 = p20.isEmpty ? 0 : p20.reduce(0, +) / Double(p20.count)
        let avg100 = p100.isEmpty ? 0 : p100.reduce(0, +) / Double(p100.count)
        return FlowLayout(spacing: 14, lineSpacing: 3) {
            Text("\(s.days.count) days (\(s.days.first ?? "") → \(s.days.last ?? ""))")
            Text("Deliv % 20d \(String(format: "%.0f", avg20))% · 100d \(String(format: "%.0f", avg100))%")
            if let h, let last = m.last, h > 0 { Text("today = \(String(format: "%.0f", last / h * 100))% of the \(length)-day high") }
            Text("\(sig.count) signal\(sig.count == 1 ? "" : "s")").foregroundStyle(.orange)
            if let sf = c.safety { Text("Safety \(Self.short(sf))") }
            if let pr = c.pctRank { Text("DQ_PRANK \(String(format: "%.0f", pr))") }
            if let j = c.jump { Text("JUMP \(String(format: "%.2f", j))") }
            if !missing.isEmpty {
                Text("⚠️ \(missing.count) trading day\(missing.count == 1 ? "" : "s") without an NSE row")
                    .foregroundStyle(.orange)
                    .help("Trading days (NSE calendar) with no row for this stock: \(missing.suffix(12).joined(separator: ", "))\(missing.count > 12 ? " …" : ""). Usually suspension / no trades — or a day not downloaded yet (see the header).")
            }
            if let d = c.dlvr { Text("DLVR \(String(format: "%.2f", d)) Cr today").foregroundStyle(.orange).bold() }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
    }

    private func pushChart() {
        guard let s = selected else { return }
        let ser = dc.book.series[s].map { DeliverySeries.addDeals ? $0.withDeals(s) : $0 }
        lw.show(LWChartData.make(symbol: s, series: ser, candles: candles, metric: metric, length: max(2, length),
                                 full: full, onlyRises: onlyRises, range: range, dark: colorScheme == .dark, calendar: dc.calendar,
                                 layers: ChartLayer.decode(layersRaw), events: LWChartData.eventMarkers(s, layers: ChartLayer.decode(layersRaw)), deals: LWChartData.dealBars(s, layers: ChartLayer.decode(layersRaw))))
    }

    /// Pine Script that paints the same signal days on your TradingView charts (for the stocks in scope).
    private func copyPine() {
        let book = dc.book
        let len = max(2, length)
        var allowed: Set<String>? = nil
        if let label = vm.labelIndex, scope != "All NSE" {
            let rows = scope == "My Filter" ? vm.filterRows : vm.table.rows
            allowed = Set(rows.map { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() })
        }
        var sigs: [(symbol: String, days: [String])] = []
        for (sym, s) in book.series {
            if let allowed, !allowed.contains(sym) { continue }
            let idx = DeliverySignal.signals(s.metric(metric), length: len, full: full, onlyRises: onlyRises)
            if !idx.isEmpty { sigs.append((sym, idx.map { s.days[$0] })) }
        }
        let script = DeliveryPine.script(signals: sigs, metric: metric.pine, length: len)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        dc.status = "Pine Script copied: \(sigs.count) stocks, \(sigs.reduce(0) { $0 + $1.days.count }) signal days (\(script.count / 1024) KB). In TradingView: Pine Editor → paste → Add to chart (on both layouts)."
    }

    private func points(_ s: DeliverySeries) -> [DelivPoint] {
        let m = s.metric(metric)
        let h = DeliverySignal.highest(m, length: length, full: full)
        let sig = Set(DeliverySignal.signals(m, length: length, full: full, onlyRises: onlyRises))
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return s.days.indices.compactMap { i in
            f.date(from: s.days[i]).map { DelivPoint(day: s.days[i], date: $0, qty: m[i], high: h[i], signal: sig.contains(i)) }
        }
    }

    private func visible(_ p: [DelivPoint]) -> [DelivPoint] {
        switch range {
        case "6M": return Array(p.suffix(126))
        case "1Y": return Array(p.suffix(252))
        case "2Y": return Array(p.suffix(504))
        default: return p
        }
    }

    private func priceDomain(_ cs: [YahooClient.Candle]) -> ClosedRange<Double> {
        guard let lo = cs.map(\.low).min(), let hi = cs.map(\.high).max(), hi > lo else { return 0...1 }
        let pad = (hi - lo) * 0.04
        return (lo - pad)...(hi + pad)
    }

    private func loadCandles(_ s: String?) {
        candles = []; chartError = nil
        guard let s else { return }
        loadingChart = true
        Task {
            do {
                let c = try await YahooClient.candles(s, range: "5y")
                if selected == s { candles = c }
            } catch { if selected == s { chartError = error.localizedDescription } }
            if selected == s { loadingChart = false }
        }
    }

    // MARK: Signals for every stock

    private func recompute() {
        let book = dc.book
        let len = max(2, length), fl = full, rises = onlyRises, win = within, val = metric
        let lastIndex = book.days.count - 1
        var allowed: Set<String>? = nil
        if let label = vm.labelIndex {
            func sym(_ r: SheetRow) -> String { r.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
            switch scope {
            case "Sheet stocks": allowed = Set(vm.table.rows.map(sym))
            case "My Filter": allowed = Set(vm.filterRows.map(sym))
            default: allowed = nil
            }
        }
        let dayIndex = Dictionary(uniqueKeysWithValues: book.days.enumerated().map { ($1, $0) })
        computing = true
        Task {
            let both = await Task.detached(priority: .userInitiated) { () -> ([DelivRow], [DelivRow]) in
                var res: [DelivRow] = [], every: [DelivRow] = []
                for (sym, s) in book.series {
                    let m = s.metric(val)
                    let sig = DeliverySignal.signals(m, length: len, full: fl, onlyRises: rises)
                    let at = sig.last ?? (m.count - 1)
                    guard at >= 0 else { continue }
                    let ago = sig.last.flatMap { dayIndex[s.days[$0]] }.map { lastIndex - $0 }
                    let lo = max(0, at - len + 1)
                    let window = m[lo...at]
                    let avg = window.reduce(0, +) / Double(window.count)
                    let r = DelivRow(symbol: sym, lastSignal: sig.last.map { s.days[$0] }, barsAgo: ago, qty: m[at], per: s.per[at],
                                     xAvg: avg > 0 ? m[at] / avg : nil, signals: sig.count, latestQty: m.last ?? 0)
                    every.append(r)
                    if let allowed, !allowed.contains(sym) { continue }
                    if let ago, ago < win { res.append(r) }
                }
                return (res.sorted { ($0.barsAgo ?? 999, -($0.xAvg ?? 0)) < ($1.barsAgo ?? 999, -($1.xAvg ?? 0)) }, every)
            }.value
            let out = both.0
            rows = out
            allRows = both.1
            computing = false
            if selected == nil || !(out + allRows).contains(where: { $0.symbol == selected }) { selected = out.first?.symbol }
        }
    }

    static func short(_ v: Double) -> String {
        switch abs(v) {
        case 1e7...: return String(format: "%.2f Cr", v / 1e7)
        case 1e5...: return String(format: "%.2f L", v / 1e5)
        case 1e3...: return String(format: "%.1f K", v / 1e3)
        default: return String(format: "%.0f", v)
        }
    }
}


/// Delivery panel under the TradingView chart in the Chart viewer: the stock's delivery bars, the rolling
/// ta.highest line and its signal days — zoom / pan like TradingView.
struct DeliveryMiniChart: View {
    @State private var periodTick = 0
    @AppStorage("deliv.addDeals") private var addDeals = false
    @AppStorage("deliv.showM") private var showM = true
    @AppStorage("deliv.showW") private var showW = false
    let symbol: String
    @ObservedObject var lw: LWChartHolder
    var syncNote: String? = nil
    /// Optional day (yyyy-MM-dd) to centre the chart on, e.g. a multibagger's move — about 4 months before to 3 after.
    var focus: String? = nil
    /// The TradingView chart shown with it (its D / W / M setting); nil = the chart viewer's current chart.
    var forChart: Int? = nil
    @ObservedObject private var dc = DeliveryCenter.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("deliv.length") private var length = 300
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue
    @AppStorage(DeliveryChartBasis.key) private var basis = ""
    private var signalMetric: DeliveryMetric { DeliveryMetric(rawValue: metricRaw) ?? .value }
    private var metric: DeliveryMetric { DeliveryChartBasis.metric(signal: signalMetric, basis: basis) }
    @AppStorage("deliv.onlyRises") private var onlyRises = true
    @AppStorage("deliv.full") private var full = true
    @AppStorage("viewer.delivRange") private var range = "1Y"
    @AppStorage("viewer.delivLayers") private var layersRaw = ""
    @AppStorage("sync.offsetBars") private var syncOffset = 0
    @ObservedObject private var news = NewsTimeline.shared
    @ObservedObject private var deals = DealsCenter.shared
    @ObservedObject private var fmarks = FormulaMarks.shared
    @ObservedObject private var pine = PineCenter.shared
    @AppStorage("steep.span") private var steepSpan = 5
    @AppStorage("zp.level") private var zpLevel = 99.0
    @AppStorage("steep.source") private var steepSource = "delsma"
    @AppStorage("steep.norm") private var steepNorm = 250
    @AppStorage("steep.trig") private var steepTrig = 2.0

    /// What the Deals layer has for this stock (or what NSE said); click to download / refresh now.
    static func quickName(_ l: ChartLayer) -> String {
        switch l {
        case .candles: return "Candles"
        case .del2c: return "DEL2C"
        case .hit3: return "HI/T3"
        case .dsmark: return "▲DS"
        case .zpmark: return "▲ZP"
        case .fmark: return "Formula"
        case .deals: return "Deals"
        case .steep: return "Steep"
        default: return "Shade"
        }
    }

    /// A small one-line status capsule.
    /// The overlay switches, full names, never squeezed; each switch's own setting sits right after it.
    private var layerRow: some View {
        let L = ChartLayer.decode(layersRaw)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                layerToggle(.candles, L)
                layerToggle(.del2c, L)
                layerToggle(.hit3, L)
                group {
                    layerToggle(.shade, L)
                    DelsmacLevelControl(level: $shadeLevel).controlSize(.mini).fixedSize()
                }
                layerToggle(.dsmark, L)
                group {
                    layerToggle(.zpmark, L)
                    if L.contains(.zpmark) { ZPLevelControl(level: $zpLevel).controlSize(.mini).fixedSize() }
                }
                group {
                    layerToggle(.fmark, L)
                    if L.contains(.fmark) { FormulaMarkControl(symbol: SymbolBook.clean(symbol)).controlSize(.mini) }
                }
                group {
                    layerToggle(.deals, L)
                    if L.contains(.deals) { dealsNote }
                    Toggle("+ to delivery", isOn: $addDeals).toggleStyle(.button).controlSize(.mini).fixedSize()
                        .help("Add bulk / block deal shares to each day's delivered quantity (the larger of the buy and sell sides) — delivery bars, DELSMA, percentrank and the lines are drawn with them. Off = NSE's delivery as published.")
                }
                group {
                    layerToggle(.steep, L)
                    if L.contains(.steep) { steepMenu }
                }
                Toggle("W_", isOn: $showW).toggleStyle(.button).controlSize(.mini).fixedSize()
                    .help("W_ values (last week-end) in the legend + dashed W_DELSMA line")
                Toggle("M_", isOn: $showM).toggleStyle(.button).controlSize(.mini).fixedSize()
                    .help("M_ values: DELSMA, DELSMAC, Z, Z_PRANK, DEAL_PRANK as they were at the end of the last completed month — in the legend, plus M_DELSMA as a dashed orange step on the %rank scale (same as the M_ Filter columns)")
                Divider().frame(height: 14)
                PineButton().controlSize(.mini)
            }
            .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A switch and its settings, boxed together so it's clear which setting belongs to which switch.
    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 3) { c() }
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.10)))
    }

    private func layerToggle(_ layer: ChartLayer, _ L: Set<ChartLayer>) -> some View {
        Toggle(Self.quickName(layer), isOn: Binding(get: { L.contains(layer) }, set: { on in
            var x = L; if on { x.insert(layer); if layer == .deals { DealsCenter.shared.update(days: 1800) } } else { x.remove(layer) }
            layersRaw = ChartLayer.encode(x)
        }))
        .toggleStyle(.button).controlSize(.mini).fixedSize()
        .help(layer.label(metric.pine, length))
    }

    private var steepMenu: some View {
        Menu {
            SteepSourcePicker(source: $steepSource)
            Picker("Steepness span", selection: $steepSpan) { ForEach([3, 5, 10, 20], id: \.self) { Text("\($0) days").tag($0) } }
            Picker("Normal-steepness window", selection: $steepNorm) { ForEach([100, 150, 250, 500], id: \.self) { Text("\($0) days").tag($0) } }
            Picker("Steep = σ above normal", selection: $steepTrig) { ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { Text(String(format: "%.1f σ", $0)).tag($0) } }
        } label: { Text("\(steepSpan)d·\(String(format: "%g", steepTrig))σ").font(.caption2.monospacedDigit()) }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Sustained steepness: src = DELSMA (or ta.ema(DELIV_QTY×CLOSE, 66)); g = (src/src[span] − 1)×100; z = (g − sma(g, window)) / stdev(g, window); steep = z > σ; run = days steep in a row; energy = Σ z while steep")
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.monospacedDigit()).foregroundStyle(color).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var dealsNote: some View {
        let n = deals.bySymbol[symbol.uppercased()]?.count ?? 0
        let text: String
        if deals.busy { text = "⟳" }
        else if deals.status != nil { text = "⚠︎" }
        else if deals.deals.isEmpty { text = "↓" }
        else { text = "\(n)" }
        return Button { deals.update(days: 1800, force: true) } label: {
            Text(text).font(.caption2.monospacedDigit()).lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(deals.status != nil && !deals.busy ? Color.orange : Color.secondary)
        .fixedSize()
        .help((deals.status.map { $0 + "\n\n" } ?? "") + "\(n) bulk/block deals for \(symbol). Bulk + block deals come from NSE's deals history (nseindia.com/api/historical/bulk-deals and block-deals) and today's nsearchives bulk.csv / block.csv. Most stocks have few or no deals. Click to download / refresh now.")
    }
    @AppStorage("t3.rev") private var t3Rev = 0
    /// What this panel shows: the Delivery chart, Chart 3 (price + DEL2C line), or both stacked.
    @AppStorage("lower.chart") private var lower = "delivery"
    @AppStorage("del2.len") private var del2Len = 100
    @AppStorage("delsmac.shade2") private var shadeLevel = 90.0
    @AppStorage("chart.styleRev") private var styleRev = 0
    @ObservedObject private var candleCache = CandleCache.shared
    @EnvironmentObject var vm: ScreenerViewModel
    private var showChart3: Bool { lower == "chart3" }

    var body: some View {
        let s = dc.book.series[SymbolBook.clean(symbol)]
        let sig = s.map { DeliverySignal.signals($0.metric(metric), length: max(2, length), full: full, onlyRises: onlyRises) } ?? []
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // ── what is drawn ──
                Picker("", selection: $lower) {
                    Text("Delivery").tag("delivery"); Text("Chart 3").tag("chart3")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
                .help("Chart 3 = price with the DEL2C line: the close on the latest day DELIV_QTY×CLOSE made its \(del2Len)-day high (DEL2 = 100). Shown with Chart 1 / 2 above it. The Delivery chart draws DEL2C too (Layers → DEL2C line).")
                if showChart3 || ChartLayer.decode(layersRaw).contains(.del2c) {
                    Picker("", selection: $del2Len) { Text("H100").tag(100); Text("H300").tag(300) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
                        .help("DEL2 = DELI × 100 / ta.highest(DELI, 100 or 300) — also used by the Filter's DEL2, DEL2C and C/DL2C")
                }
                Picker("", selection: Binding(get: { DeliveryChartBasis.shown(signal: signalMetric, basis: basis) }, set: { basis = $0 })) {
                    Text("Raw").tag("raw"); Text(signalMetric.smaLength == nil ? "SMA 22" : signalMetric.avgName).tag("sma")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
                .help("Raw: ta.highest and ta.percentrank of DELIV_QTY*CLOSE_PRICE itself. SMA / EMA: of its \(signalMetric.smaLength ?? 22)-day average (as picked in the Delivery signal). Only changes these charts — not the Delivery Analysis signal or the Filter columns. Now drawing: \(metric.pine)")

                // ── status chips (one line each; details on hover) ──
                if let s, let last = sig.last {
                    let ago = dc.book.days.count - 1 - (dc.book.days.firstIndex(of: s.days[last]) ?? dc.book.days.count - 1)
                    chip("▲ \(String(s.days[last].dropFirst(2))) · \(ago == 0 ? "today" : "\(ago)d")", .orange)
                        .help("Last \(length)-day high of \(metric.pine): \(s.days[last]) (\(ago == 0 ? "today" : "\(ago) trading days ago")) · \(sig.count) highs in the stored history")
                }
                if let s { DelsmacBadge(series: s, day: lw.crossDay).fixedSize() }
                if s == nil {
                    Text(dc.storedDays.isEmpty ? "No NSE delivery data yet — open Delivery Analysis (⌥⌘D)" : "No NSE delivery data for \(symbol)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if s != nil {
                    let sym = SymbolBook.clean(symbol)
                    let gapCount = dc.stockGaps(sym).count
                    Button { dc.recheck(sym) } label: {
                        if dc.rechecking == sym { ProgressView().controlSize(.mini) }
                        else if gapCount > 0 { chip("⚠︎ \(gapCount)d gap", .orange) }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .buttonStyle(.borderless).controlSize(.mini)
                    .disabled(dc.rechecking != nil || dc.isFetching)
                    .help((dc.recheckNote[sym].map { $0 + "\n\n" } ?? "") + (gapCount > 0 ? "\(gapCount) trading day\(gapCount == 1 ? "" : "s") without NSE data for this stock. " : "") + "Click to recheck: re-download NSE's files for the days this stock has no data, then redraw. Days NSE itself has no row for (not traded / suspended) stay empty.")
                }
                if let e = lw.lastError { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(1) }
                Spacer(minLength: 4)

                ChartStyleButton().buttonStyle(.borderless).controlSize(.mini)
                ChartLayersButton(raw: $layersRaw, metric: metric.pine, length: length,
                                  options: ChartLayer.allCases)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.mini).fixedSize()

                // ── sync + range ──
                if let n = syncNote {
                    Stepper(value: $syncOffset, in: -30...30) {
                        (Text(Image(systemName: "link")) + Text(syncOffset == 0 ? "" : String(format: " %+d", syncOffset)))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .controlSize(.mini).fixedSize()
                    .help(n + " — fine-tune: shift the delivery chart by a few bars if it doesn't line up with TradingView")
                }
                periodPicker
                Picker("", selection: $range) { ForEach(["6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
            }
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 3)
            // ── second row: what's drawn on top, each with its own setting right after it ──
            if !showChart3 { layerRow.padding(.horizontal, 8).padding(.bottom, 3) }
            if s != nil { LWChartView(holder: lw).dealRankPopup(lw, symbol: SymbolBook.clean(symbol)) }        // the synced chart: Delivery, or Chart 3
        }
        .onChange(of: lower) { _ in push() }
        .onChange(of: del2Len) { _ in push(); dc.refreshColumns() }
        .onChange(of: shadeLevel) { _ in push() }
        .onChange(of: candleCache.revision) { _ in push() }
        .onChange(of: styleRev) { _ in push() }
        .onAppear { if lower == "both" { lower = "delivery" } }
        .onChange(of: vm.priceBook.series.count) { _ in if showChart3 { push() } }
        .onAppear { dc.loadIfNeeded(); push() }
        .task(id: symbol + "|" + (focus ?? "")) { push() }
        .onChange(of: dc.revision) { _ in push() }
        .onChange(of: fmarks.revision) { _ in push() }
        .onChange(of: pine.revision) { _ in push() }
        .onChange(of: vm.settings.chartLinkColumn) { _ in push() }
        .onChange(of: addDeals) { _ in push() }
        .onChange(of: showM) { _ in push() }
        .onChange(of: showW) { _ in push() }
        .onChange(of: range) { _ in push() }
        .onChange(of: metricRaw) { _ in push() }
        .onChange(of: basis) { _ in push() }
        .onChange(of: colorScheme) { _ in push() }
        .onChange(of: layersRaw) { _ in push() }
        .onChange(of: t3Rev) { _ in push() }
        .onChange(of: syncOffset) { _ in lw.refollow() }
        .onChange(of: steepSpan) { _ in push() }
        .onChange(of: zpLevel) { _ in push() }
        .onChange(of: steepSource) { _ in push(); DeliveryCenter.shared.refreshColumns() }
        .onChange(of: steepNorm) { _ in push() }
        .onChange(of: steepTrig) { _ in push() }
        .onChange(of: news.revision) { _ in push() }
        .onChange(of: deals.revision) { _ in push() }
        .onAppear { if ChartLayer.decode(layersRaw).contains(.deals) { DealsCenter.shared.update(days: 1800) } }
    }

    private func push() {
        let sym = symbol.uppercased()
        guard let s = dc.book.series[sym] else { return }
        let c3 = LWChartData.chart3(symbol: sym, series: s, prices: vm.priceBook.series(for: sym), length: del2Len == 300 ? 300 : 100,
                                    full: full, range: range, dark: colorScheme == .dark)
        if lower == "chart3" { lw.show(c3); centre(); return }
        let ser = DeliverySeries.addDeals ? s.withDeals(sym) : s
        var data = LWChartData.make(symbol: sym, series: ser, candles: CandleCache.shared.candles(sym) ?? Self.candles(vm.priceBook.series(for: sym), nse: s), metric: metric, length: max(2, length),
                                    full: full, onlyRises: onlyRises, range: range, dark: colorScheme == .dark, calendar: dc.calendar,
                                    layers: ChartLayer.decode(layersRaw), events: LWChartData.eventMarkers(sym, layers: ChartLayer.decode(layersRaw)), deals: LWChartData.dealBars(sym, layers: ChartLayer.decode(layersRaw)))
        data.period = period
        if period == "M" && (range == "6M" || range == "1Y") { data.range = "All" }     // 6 / 12 bars would be too few
        lw.show(data)
        centre()
    }

    /// D / W / M for the TradingView chart now shown above (Chart 2 = monthly unless you change it).
    private var chartIndex: Int { min(forChart ?? vm.settings.chartLinkColumn, max(0, vm.chartCount - 1)) }
    private var period: String {
        UserDefaults.standard.string(forKey: "deliv.period.\(chartIndex)") ?? (chartIndex == 1 ? "M" : "D")
    }
    private var periodPicker: some View {
        Picker("", selection: Binding(get: { period }, set: { v in
            UserDefaults.standard.set(v, forKey: "deliv.period.\(chartIndex)"); periodTick &+= 1; push()
        })) { Text("D").tag("D"); Text("W").tag("W"); Text("M").tag("M") }
        .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
        .help("Delivery chart bars: daily, weekly or monthly — remembered for each TradingView chart (Chart \(chartIndex + 1)). Monthly: one bar per month (delivery and deals totalled, lines at month-end).")
        .id(periodTick)
    }

    private func centre() {
        if let f = focus, let w = Self.window(around: f) {
            let holder = lw
            for delay in [0.5, 1.5] {            // after the data has been drawn (first load can take a moment)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { holder.setRange(from: w.0, to: w.1) }
            }
        }
    }

    /// Price candles for the delivery chart: Yahoo OHLC, else NSE's close (flat candles).
    static func candles(_ p: PriceSeries?, nse s: DeliverySeries) -> [YahooClient.Candle] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"
        if let p, let o = p.opens, let h = p.highs, let l = p.lows, o.count == p.closes.count, h.count == o.count, l.count == o.count {
            return p.days.indices.map { YahooClient.Candle(day: p.days[$0], date: f.date(from: p.days[$0]) ?? Date(), open: o[$0], high: h[$0], low: l[$0], close: p.closes[$0], volume: 0) }
        }
        // NSE closes only: open = the previous close, so each day still shows its move
        return s.days.indices.map { i in
            let c = s.close[i], o = i > 0 ? s.close[i - 1] : c
            return YahooClient.Candle(day: s.days[i], date: f.date(from: s.days[i]) ?? Date(), open: o, high: max(o, c), low: min(o, c), close: c, volume: 0)
        }
    }

    /// ~120 calendar days before to ~90 after `day`.
    static func window(around day: String) -> (String, String)? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        return (f.string(from: d.addingTimeInterval(-120 * 86_400)), f.string(from: d.addingTimeInterval(90 * 86_400)))
    }
}


/// Every stored NSE day for one stock, newest first, with the signal and Safety columns — exportable to CSV.
struct DeliveryDataTable: View {
    let symbol: String
    let series: DeliverySeries
    let metric: DeliveryMetric
    let length: Int
    let full: Bool
    let onlyRises: Bool
    var calendar: [String] = []
    var lastDay = ""

    struct Row: Identifiable {
        var id: String { day }
        let day: String, close: Double, qty: Double, per: Double, value: Double
        let highest: Double?, signal: Bool, safety: Double?, overSafety: Bool?, pctRank: Double?
        var missing = false        // a trading day with no NSE row for this stock
    }

    private var rows: [Row] {
        let m = series.metric(metric)
        let h = DeliverySignal.highest(m, length: length, full: full)
        let sig = Set(DeliverySignal.signals(m, length: length, full: full, onlyRises: onlyRises))
        var out: [Row] = []
        var sum = 0.0
        for i in series.days.indices {
            sum += series.qty[i]
            if i >= 100 { sum -= series.qty[i - 100] }
            let safety: Double? = i >= 99 ? sum / 100 * 0.05 : nil
            out.append(Row(day: series.days[i], close: series.close[i], qty: series.qty[i], per: series.per[i],
                           value: series.qty[i] * series.close[i], highest: h[i], signal: sig.contains(i),
                           safety: safety, overSafety: safety.map { series.qty[i] > $0 },
                           pctRank: DeliveryColumns.percentRank(series.qty, length: 300, at: i)))
        }
        // Trading days (NSE calendar) with no row for this stock, shown in place so dates line up with reality
        if let first = series.days.first {
            let have = Set(series.days)
            for d in calendar where d >= first && d <= max(lastDay, series.days.last ?? "") && !have.contains(d) {
                out.append(Row(day: d, close: 0, qty: 0, per: 0, value: 0, highest: nil, signal: false, safety: nil, overSafety: nil, pctRank: nil, missing: true))
            }
            out.sort { $0.day < $1.day }
        }
        return out.reversed()
    }

    var body: some View {
        let r = rows
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(r.filter { !$0.missing }.count) days with data · \(r.filter(\.missing).count) trading days without an NSE row · \(r.filter(\.signal).count) signal days").font(.caption.bold())
                Spacer()
                Button("Export CSV…") { export(r) }.controlSize(.small)
            }
            Table(r) {
                TableColumn("Date") { x in Text(x.day).monospacedDigit().foregroundStyle(x.missing ? Color.secondary : (x.signal ? Color.orange : Color.primary)) }.width(min: 80, ideal: 90)
                TableColumn("Close") { x in Text(x.missing ? "no NSE row" : String(format: "%.2f", x.close)).monospacedDigit().foregroundStyle(x.missing ? Color.orange : Color.primary) }.width(min: 55, ideal: 75)
                TableColumn("DELIV_QTY") { x in Text(DeliveryView.short(x.qty)).monospacedDigit() }.width(min: 65, ideal: 75)
                TableColumn("Deliv %") { x in Text(String(format: "%.1f", x.per)).monospacedDigit() }.width(min: 45, ideal: 55)
                TableColumn("QTY×CLOSE") { x in Text(DeliveryView.short(x.value)).monospacedDigit() }.width(min: 70, ideal: 80)
                TableColumn("Highest(\(length))") { x in Text(x.highest.map { DeliveryView.short($0) } ?? "—").monospacedDigit().foregroundStyle(.blue) }.width(min: 75, ideal: 85)
                TableColumn("Signal") { x in Text(x.signal ? "▲ DQ" : "").foregroundStyle(.orange).bold() }.width(min: 40, ideal: 50)
                TableColumn("Safety") { x in Text(x.safety.map { DeliveryView.short($0) } ?? "—").monospacedDigit() }.width(min: 55, ideal: 65)
                TableColumn("%Rank 300") { x in Text(x.pctRank.map { String(format: "%.0f", $0) } ?? "—").monospacedDigit() }.width(min: 50, ideal: 60)
                TableColumn("QTY > Safety") { x in Text(x.overSafety.map { $0 ? "yes" : "no" } ?? "—").foregroundStyle(x.overSafety == false ? Color.red : Color.secondary) }.width(min: 60, ideal: 75)
            }
        }
    }

    private func export(_ r: [Row]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(symbol)_delivery.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var s = "Date,Close,DELIV_QTY,DELIV_PER,DELIV_QTY*CLOSE,Highest_\(length),Signal,Safety,PercentRank300\n"
        for x in r.reversed() where !x.missing {
            s += "\(x.day),\(x.close),\(Int(x.qty)),\(x.per),\(Int(x.value)),\(x.highest.map { String(Int($0)) } ?? ""),\(x.signal ? 1 : 0),\(x.safety.map { String(Int($0)) } ?? ""),\(x.pctRank.map { String(format: "%.1f", $0) } ?? "")\n"
        }
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}


/// Lays its children out left to right and wraps to a new line when the width runs out
/// (so toolbars never squeeze their labels into a vertical column).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    private func rows(_ maxW: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, sz))
            x += sz.width + spacing
        }
        return rows.filter { !$0.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let rs = rows(maxW, subviews)
        let h = rs.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + lineSpacing * CGFloat(max(0, rs.count - 1))
        let w = rs.map { r in r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, r.count - 1)) }.max() ?? 0
        return CGSize(width: maxW.isFinite ? maxW : w, height: h)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = b.minY
        for r in rows(b.width, subviews) {
            let rh = r.map(\.1.height).max() ?? 0
            var x = b.minX
            for (i, sz) in r {
                subviews[i].place(at: CGPoint(x: x, y: y + (rh - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + spacing
            }
            y += rh + lineSpacing
        }
    }
}


/// "STREAK" button + popover: how the Filter's STREAK column is defined — consecutive trading days (ending on
/// the data day) where ta.percentrank(ta.sma(DELIV_QTY*CLOSE_PRICE, 22 or 66), length) passes a condition.
struct StreakButton: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("STREAK", systemImage: "flame") }
            .help("Defines the Filter's STREAK column: \(StreakDef.current.pine) — counted in consecutive trading days")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                StreakSettings().padding(14)
            }
    }
}

struct StreakSettings: View {
    @AppStorage("streak.sma") private var sma = 0          // 0 = follow the Delivery Analysis signal
    @AppStorage("streak.length") private var length = 300
    @AppStorage("streak.op") private var op = ">"
    @AppStorage("streak.value") private var value = 99.0
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STREAK column").font(.headline)
            Text("Number of consecutive trading days, ending on the Filter's data day, where:").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("ta.percentrank(\((DeliveryMetric(rawValue: metricRaw) ?? .value).avgFn)(DELIV_QTY*CLOSE_PRICE,").font(.caption.monospaced())
                Picker("", selection: $sma) {
                    Text("signal's (\(DeliveryMetric(rawValue: metricRaw)?.smaLength ?? 22))").tag(0)
                    Text("22").tag(22)
                    Text("66").tag(66)
                    Text("100").tag(100)
                    Text("300").tag(300)
                }
                .labelsHidden().fixedSize()
                .help("“signal's” follows the SMA picked in Delivery Analysis' Signal (22 unless ta.sma(…, 66) is selected)")
                Text("),").font(.caption.monospaced())
                TextField("", value: $length, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
                Text(")").font(.caption.monospaced())
                Picker("", selection: $op) { ForEach([">", "≥", "<", "≤"], id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().fixedSize()
                TextField("", value: $value, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
            }
            Text("0 = the condition fails on the data day. Blank = not enough history yet (needs SMA length − 1 + \(length) + 1 trading days of NSE data, like Pine's na). A day with no NSE row for the stock is skipped, not counted as a break.")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 470, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(StreakDef.current.pine).font(.caption.monospaced()).foregroundStyle(.orange)
                Spacer()
                Button("Reset") { sma = 0; length = 300; op = ">"; value = 99 }
            }
        }
        .onChange(of: sma) { _ in DeliveryCenter.shared.refreshColumns() }
        .onChange(of: length) { _ in DeliveryCenter.shared.refreshColumns() }
        .onChange(of: op) { _ in DeliveryCenter.shared.refreshColumns() }
        .onChange(of: value) { _ in DeliveryCenter.shared.refreshColumns() }
        .onChange(of: metricRaw) { _ in DeliveryCenter.shared.refreshColumns() }
    }
}


/// DAYS_DELSMA: which DELSMA condition the "days since" counts from.
struct DelsmaDaysSettings: View {
    @AppStorage("delsmaDays.op") private var op = ">"
    @AppStorage("delsmaDays.value") private var value = 70.0
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("DAYS_DELSMA = ta.barssince(DELSMA").font(.caption.monospaced())
                Picker("", selection: $op) { ForEach([">", "≥", "<", "≤"], id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
                TextField("", value: $value, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
                Text(")").font(.caption.monospaced())
                ForEach([50.0, 60, 70, 80, 90, 99], id: \.self) { v in
                    Button(CombiEngine.fmt(v)) { op = ">"; value = v }.controlSize(.small)
                }
            }
            Text("DELSMA = ta.percentrank(\((DeliveryMetric(rawValue: metricRaw) ?? .value).avgFn)(DELIV_QTY*CLOSE_PRICE, \(DeliveryMetric(rawValue: metricRaw)?.smaLength ?? 22)), 300). 0 = the condition holds today; 5 = it last held 5 trading days ago; blank = not within the stored NSE history.")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 470, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: op) { _ in DeliveryCenter.shared.refreshColumns() }
        .onChange(of: value) { _ in DeliveryCenter.shared.refreshColumns() }
    }
}

/// Z_PRANK_DAYS: days since Z_PRANK (ta.percentrank(z, 300)) was above the chosen level.
struct ZPrankDaysSettings: View {
    @AppStorage("zprankDays.value") private var value = 99.0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Z_PRANK_DAYS = ta.barssince(Z_PRANK >").font(.caption.monospaced())
                TextField("", value: $value, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
                Text(")").font(.caption.monospaced())
                ForEach([80.0, 90, 95, 97, 99], id: \.self) { v in Button(CombiEngine.fmt(v)) { value = v }.controlSize(.small) }
            }
            Text("Z_PRANK = ta.percentrank(z, 300), z = the Steep z of DELSMA. 0 = above the level today; 5 = last above it 5 trading days ago; blank = not within the last 300 trading days.")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 470, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: value) { _ in DeliveryCenter.shared.refreshColumns() }
    }
}

/// One button for the STREAK and delivery-T3 settings, each in a collapsible section.
struct IndicatorSettingsButton: View {
    @State private var open = false
    @AppStorage("hub.streak") private var streak = false
    @AppStorage("hub.t3") private var t3 = false
    @AppStorage("hub.delsmaDays") private var daysOpen = true
    @AppStorage("hub.zprankDays") private var zDaysOpen = true

    var body: some View {
        Button { open.toggle() } label: { Label("STREAK · T3", systemImage: "slider.horizontal.3") }
            .help("Settings of the STREAK column and the T3 line on delivery (also in Settings, ⌥⌘,)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("STREAK", isExpanded: $streak) { StreakSettings().padding(.vertical, 6) }
                    Divider()
                    DisclosureGroup("T3 on delivery", isExpanded: $t3) { T3Settings().padding(.vertical, 6) }
                    Divider()
                    DisclosureGroup("DAYS_DELSMA — days since DELSMA > …", isExpanded: $daysOpen) { DelsmaDaysSettings().padding(.vertical, 6) }
                    Divider()
                    DisclosureGroup("Z_PRANK_DAYS — days since Z_PRANK > …", isExpanded: $zDaysOpen) { ZPrankDaysSettings().padding(.vertical, 6) }
                }
                .padding(14).frame(width: 520)
            }
    }
}


/// "T3" button + popover: settings of the Tilson T3 line on the delivery charts and the Filter's t3Color column.
struct T3Button: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("T3", systemImage: "waveform.path.ecg") }
            .help("Tilson T3 of delivery: the line on the delivery charts and the Filter's t3Color column (1 = rising / green, 0 = red)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                T3Settings().padding(14)
            }
    }
}

struct T3Settings: View {
    @AppStorage("t3.length") private var length = 22
    @AppStorage("t3.factor") private var factor = 1.0
    @AppStorage("t3.useQty") private var useQty = false
    @AppStorage("t3.rev") private var rev = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("T3 (Tilson) on delivery").font(.headline)
            HStack(spacing: 6) {
                Text("src =").font(.caption.monospaced())
                Picker("", selection: $useQty) {
                    Text("DELIV_QTY*CLOSE_PRICE").tag(false)
                    Text("DELIV_QTY").tag(true)
                }
                .labelsHidden().fixedSize()
            }
            HStack(spacing: 6) {
                Text("length =").font(.caption.monospaced())
                TextField("", value: $length, format: .number).frame(width: 50).multilineTextAlignment(.trailing)
                Text("factor =").font(.caption.monospaced())
                TextField("", value: $factor, format: .number).frame(width: 50).multilineTextAlignment(.trailing)
            }
            Text("""
            gd(src, length) => ta.ema(src, length) * (1 + factor) - ta.ema(ta.ema(src, length), length) * factor
            t3 = gd(gd(gd(src, length), length), length)
            t3Color = t3 > t3[1] ? green : red      → Filter t3Color: 1 = green, 0 = red
            """)
            .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("ta.ema follows Pine: na for the first `length` bars, then seeded with their average. Six EMAs are chained, so T3 needs about 6 × length trading days (≈ \(6 * max(1, length) - 5) for length \(length)) before it has a value; t3Color is blank until then.")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 460, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Show / hide the line: Layers button on the chart").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { length = 22; factor = 1; useQty = false }
            }
        }
        .onChange(of: length) { _ in changed() }
        .onChange(of: factor) { _ in changed() }
        .onChange(of: useQty) { _ in changed() }
    }

    private func changed() {
        if length < 1 { length = 1 }
        rev &+= 1
        DeliveryCenter.shared.refreshColumns()
    }
}


/// "T3 Fast / Slow" button: length, factor and price source of the two price T3 columns (Data and Filter).
struct PriceT3Button: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("T3 Fast / Slow", systemImage: "chart.line.flattrend.xyaxis") }
            .help("T3_FAST and T3_SLOW columns on daily prices: \(PriceT3.fast.pine) · \(PriceT3.slow.pine)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                PriceT3Settings(onApply: { open = false }).padding(14)
            }
    }
}

struct PriceT3Settings: View {
    @EnvironmentObject var vm: ScreenerViewModel
    var onApply: () -> Void = {}
    @State private var fast = PriceT3.fast
    @State private var slow = PriceT3.slow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("T3 on daily prices (Yahoo)").font(.headline)
            row("T3_FAST", $fast)
            row("T3_SLOW", $slow)
            Text("gd(src, length) = ta.ema(src, length) × (1 + factor) − ta.ema(ta.ema(src, length), length) × factor;  T3 = gd(gd(gd(src))). Tilson's classic factor is 0.7. Needs about 6 × length days of prices. T3F / T3S = 1 when the line rose since the previous day, else 0.")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 460, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Defaults") { fast = PriceT3(length: 8, factor: 0.7, source: "close"); slow = PriceT3(length: 21, factor: 0.7, source: "close") }
                Spacer()
                Button("Apply") { fast.save("t3fast"); slow.save("t3slow"); vm.setTableKeepingRaw(); onApply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { fast = PriceT3.fast; slow = PriceT3.slow }
    }

    private func row(_ name: String, _ v: Binding<PriceT3>) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.callout.bold()).frame(width: 80, alignment: .leading)
            Text("source").font(.caption)
            Picker("", selection: v.source) { ForEach(PriceT3.sources, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            Text("length").font(.caption)
            TextField("", value: v.length, format: .number).frame(width: 46).textFieldStyle(.roundedBorder)
            Text("factor").font(.caption)
            TextField("", value: v.factor, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
        }
    }
}


/// "DELSMAC 0.85" for a delivery chart's title — the Filter's DELSMAC (today's % change in the Delivery Analysis
/// signal ÷ its 300-day highest % change), on the stock's latest NSE day.
struct DelsmacBadge: View {
    let series: DeliverySeries
    /// The day under the chart's crosshair (nil = the latest day).
    var day: String? = nil
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue
    var body: some View {
        let k = DeliveryMetric(rawValue: metricRaw) ?? .value
        let i = day.flatMap { d in series.days.lastIndex(where: { $0 <= d }) } ?? (series.qty.count - 1)
        let v = DeliveryColumns.delSmaC(series, at: i, metric: k)
        let when = day != nil && i < series.days.count ? " · " + series.days[i] : ""
        Text("DELSMAC " + (v.map { String(format: "%.0f", $0) } ?? "—") + when)
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(v == nil ? Color.secondary : (v! >= 90 ? Color.green : (v! < 20 ? Color.red : Color.primary)))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .help("DELSMAC = ta.percentrank(today's % change in \(k.pine), 300) — 0–100, 100 = today's rise beats all of the last 300 days. As the Filter column, on the day under the cursor (or the latest day)")
    }
}


/// Where the DELSMAC purple shading and green ▲DS marks start: presets (90, 91 … 99.5) or ± 1 steps.
/// ▲ZP level: Z_PRANK above 90 … 99, or = 100.
struct ZPLevelControl: View {
    @Binding var level: Double
    private static let presets: [Double] = [80, 85, 90, 92, 94, 95, 96, 97, 98, 99, 99.5, 100]
    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Self.presets, id: \.self) { v in
                    Button { level = v } label: { Text(v >= 100 ? "= 100 (300-day record)" : "> " + label(v)) + Text(v == level ? "  ✓" : "") }
                }
            } label: { Text("Z_PRANK " + (level >= 100 ? "= 100" : "> " + label(level))).monospacedDigit() }
            .fixedSize()
            Stepper("", value: $level, in: 50...100, step: 1).labelsHidden()
        }
        .help("▲ZP marks days Z_PRANK — ta.percentrank(z, 300) of the Steep z of DELSMA — is above this. 100 = z higher than on all previous 300 days.")
    }
    private func label(_ v: Double) -> String { v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v) }
}

struct DelsmacLevelControl: View {
    @Binding var level: Double
    private static let presets: [Double] = [80, 85, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 99.5]

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Self.presets, id: \.self) { v in
                    Button { level = v } label: { Text(label(v)) + Text(v == level ? "  ✓" : "") }
                }
            } label: {
                Text("DELSMAC > " + label(level)).monospacedDigit()
            }
            .fixedSize()
            Stepper("", value: $level, in: 50...99.5, step: 1).labelsHidden()
        }
        .help("Shading and green ▲DS start on days DELSMAC is above this (0–100). Applies to every delivery chart.")
    }

    private func label(_ v: Double) -> String { v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v) }
}


/// What Z (sustained steepness) is measured on — any delivery series, the price, or one of your Pine Filter columns.
struct SteepSourcePicker: View {
    @Binding var source: String
    @AppStorage("steep.ema") private var ema = 66
    var body: some View {
        Picker("Z measured on", selection: $source) {
            Text("DELSMA (default)").tag("delsma")
            Text("DELSMAC").tag("delsmac")
            Text("Delivery value — EMA \(ema)").tag("value")
            Text("Delivery value (raw)").tag("dvalue")
            Text("Delivery quantity").tag("qty")
            Text("Delivery %").tag("pct")
            Text("Close price").tag("close")
            if !PineColumns.shared.names.isEmpty {
                Divider()
                ForEach(PineColumns.shared.names, id: \.self) { c in Text("Pine: \(c)").tag("pine:" + c) }
            }
        }
        Picker("EMA for “Delivery value — EMA”", selection: $ema) { ForEach([10, 22, 44, 66, 100], id: \.self) { Text("\($0)").tag($0) } }
    }
}

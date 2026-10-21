import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Delivery Analysis: NSE delivery quantity history per stock (from the daily bhavdata files) and the
/// Pine-style signal "ta.highest(DELIV_QTY, 300) updated", highlighted on a Yahoo candle chart.
struct DeliveryView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var dc = DeliveryCenter.shared

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
    @ObservedObject private var dealsC = DealsCenter.shared
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
        .onAppear { dc.loadIfNeeded(); recompute() }
        .onChange(of: dc.revision) { _ in recompute(); pushChart() }
        .onChange(of: length) { _ in recompute() }
        .onChange(of: onlyRises) { _ in recompute() }
        .onChange(of: full) { _ in recompute() }
        .onChange(of: metricRaw) { _ in recompute() }
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
                    Button("Check gaps") { dc.repairGaps() }.fixedSize()
                        .help("Compares the stored days with NSE's trading calendar (NIFTY 50 trading days from Yahoo) and downloads any missing day")
                }
                Text(storedText).font(.caption).foregroundStyle(.secondary).fixedSize()
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
                StreakButton().fixedSize()
                T3Button().fixedSize()
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
                TableColumn("Symbol") { r in Text(r.symbol).bold() }.width(min: 80, ideal: 100)
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
                    if pane == "Chart" { ChartLayersButton(raw: $layersRaw, metric: metric.pine, length: length).controlSize(.small).fixedSize() }
                    Picker("", selection: $pane) { Text("Chart").tag("Chart"); Text("Data").tag("Data") }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Picker("", selection: $range) { ForEach(["6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .opacity(pane == "Chart" ? 1 : 0.4)
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
                }
                Text("Orange bands + ▲DQ = ta.highest(\(metricName), \(length)) \(onlyRises ? "made a new high" : "updated") · bars at the bottom = \(metricName) · blue = the rolling highest")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
        .onChange(of: t3Rev) { _ in pushChart() }
        .onChange(of: newsTL.revision) { _ in pushChart() }
        .onChange(of: dealsC.revision) { _ in pushChart() }
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
        lw.show(LWChartData.make(symbol: s, series: dc.book.series[s], candles: candles, metric: metric, length: max(2, length),
                                 full: full, onlyRises: onlyRises, range: range, dark: colorScheme == .dark, calendar: dc.calendar,
                                 layers: ChartLayer.decode(layersRaw), events: LWChartData.eventMarkers(s, layers: ChartLayer.decode(layersRaw))))
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
    let symbol: String
    @ObservedObject var lw: LWChartHolder
    var syncNote: String? = nil
    /// Optional day (yyyy-MM-dd) to centre the chart on, e.g. a multibagger's move — about 4 months before to 3 after.
    var focus: String? = nil
    @ObservedObject private var dc = DeliveryCenter.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("deliv.length") private var length = 300
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue
    private var metric: DeliveryMetric { DeliveryMetric(rawValue: metricRaw) ?? .value }
    @AppStorage("deliv.onlyRises") private var onlyRises = true
    @AppStorage("deliv.full") private var full = true
    @AppStorage("viewer.delivRange") private var range = "1Y"
    @AppStorage("viewer.delivLayers") private var layersRaw = ""
    @ObservedObject private var news = NewsTimeline.shared
    @ObservedObject private var deals = DealsCenter.shared
    @AppStorage("t3.rev") private var t3Rev = 0

    var body: some View {
        let s = dc.book.series[SymbolBook.clean(symbol)]
        let sig = s.map { DeliverySignal.signals($0.metric(metric), length: max(2, length), full: full, onlyRises: onlyRises) } ?? []
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Delivery").font(.caption.bold())
                Text(metric.pine).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let s, let last = sig.last {
                    let ago = dc.book.days.count - 1 - (dc.book.days.firstIndex(of: s.days[last]) ?? dc.book.days.count - 1)
                    Text("last \(length)-day high: \(s.days[last]) (\(ago == 0 ? "today" : "\(ago)d ago")) · \(sig.count) in history")
                        .font(.caption).foregroundStyle(.orange)
                } else if s == nil {
                    Text(dc.storedDays.isEmpty ? "No NSE delivery data yet — open Delivery Analysis (⌥⌘D) to download it." : "No NSE delivery data for \(symbol).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let e = lw.lastError { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(1) }
                if let n = syncNote { Text(n).font(.caption2).foregroundStyle(.secondary) }
                ChartLayersButton(raw: $layersRaw, metric: metric.pine, length: length,
                                  options: ChartLayer.allCases.filter { $0 != .candles })
                    .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.mini).fixedSize()
                Picker("", selection: $range) { ForEach(["6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            if s != nil { LWChartView(holder: lw) }
        }
        .onAppear { dc.loadIfNeeded(); push() }
        .task(id: symbol + "|" + (focus ?? "")) { push() }
        .onChange(of: dc.revision) { _ in push() }
        .onChange(of: range) { _ in push() }
        .onChange(of: metricRaw) { _ in push() }
        .onChange(of: colorScheme) { _ in push() }
        .onChange(of: layersRaw) { _ in push() }
        .onChange(of: t3Rev) { _ in push() }
        .onChange(of: news.revision) { _ in push() }
        .onChange(of: deals.revision) { _ in push() }
    }

    private func push() {
        let sym = symbol.uppercased()
        guard let s = dc.book.series[sym] else { return }
        lw.show(LWChartData.make(symbol: sym, series: s, candles: [], metric: metric, length: max(2, length),
                                 full: full, onlyRises: onlyRises, range: range, dark: colorScheme == .dark, calendar: dc.calendar,
                                 layers: ChartLayer.decode(layersRaw), events: LWChartData.eventMarkers(sym, layers: ChartLayer.decode(layersRaw))))
        if let f = focus, let w = Self.window(around: f) {
            let holder = lw
            for delay in [0.5, 1.5] {            // after the data has been drawn (first load can take a moment)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { holder.setRange(from: w.0, to: w.1) }
            }
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
    @AppStorage("streak.sma") private var sma = 0          // 0 = follow the Delivery Analysis signal
    @AppStorage("streak.length") private var length = 300
    @AppStorage("streak.op") private var op = ">"
    @AppStorage("streak.value") private var value = 99.0
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("STREAK", systemImage: "flame") }
            .help("Defines the Filter's STREAK column: \(StreakDef.current.pine) — counted in consecutive trading days")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("STREAK column").font(.headline)
                    Text("Number of consecutive trading days, ending on the Filter's data day, where:").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("ta.percentrank(ta.sma(DELIV_QTY*CLOSE_PRICE,").font(.caption.monospaced())
                        Picker("", selection: $sma) {
                            Text("signal's (\(DeliveryMetric(rawValue: metricRaw) == .sma66 ? 66 : 22))").tag(0)
                            Text("22").tag(22)
                            Text("66").tag(66)
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
                .padding(14)
                .onChange(of: sma) { _ in DeliveryCenter.shared.refreshColumns() }
                .onChange(of: length) { _ in DeliveryCenter.shared.refreshColumns() }
                .onChange(of: op) { _ in DeliveryCenter.shared.refreshColumns() }
                .onChange(of: value) { _ in DeliveryCenter.shared.refreshColumns() }
                .onChange(of: metricRaw) { _ in DeliveryCenter.shared.refreshColumns() }
            }
    }
}


/// "T3" button + popover: settings of the Tilson T3 line on the delivery charts and the Filter's t3Color column.
struct T3Button: View {
    @AppStorage("t3.length") private var length = 22
    @AppStorage("t3.factor") private var factor = 1.0
    @AppStorage("t3.useQty") private var useQty = false
    @AppStorage("t3.rev") private var rev = 0
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("T3", systemImage: "waveform.path.ecg") }
            .help("Tilson T3 of delivery: the line on the delivery charts and the Filter's t3Color column (1 = rising / green, 0 = red)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
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
                .padding(14)
                .onChange(of: length) { _ in changed() }
                .onChange(of: factor) { _ in changed() }
                .onChange(of: useQty) { _ in changed() }
            }
    }

    private func changed() {
        if length < 1 { length = 1 }
        rev &+= 1
        DeliveryCenter.shared.refreshColumns()
    }
}

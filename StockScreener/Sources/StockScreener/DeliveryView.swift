import SwiftUI
import Charts

/// Delivery Analysis: NSE delivery quantity history per stock (from the daily bhavdata files) and the
/// Pine-style signal "ta.highest(DELIV_QTY, 300) updated", highlighted on a Yahoo candle chart.
struct DeliveryView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var dc = DeliveryCenter.shared

    @AppStorage("deliv.length") private var length = 300
    @AppStorage("deliv.useValue") private var useValue = true     // DELIV_QTY × CLOSE_PRICE (else DELIV_QTY)
    @AppStorage("deliv.onlyRises") private var onlyRises = true
    @AppStorage("deliv.full") private var full = true
    @AppStorage("deliv.within") private var within = 5
    @AppStorage("deliv.scope") private var scope = "Sheet stocks"
    @AppStorage("deliv.range") private var range = "1Y"
    @AppStorage("deliv.target") private var target = 600

    @State private var search = ""
    @State private var selected: String?
    @State private var rows: [DelivRow] = []
    @State private var computing = false
    @State private var candles: [YahooClient.Candle] = []
    @State private var chartError: String?
    @State private var loadingChart = false
    @StateObject private var lw = LWChartHolder()
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
        .onChange(of: useValue) { _ in recompute() }
        .onChange(of: within) { _ in recompute() }
        .onChange(of: scope) { _ in recompute() }
        .onChange(of: selected) { s in loadCandles(s); pushChart() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if dc.isFetching {
                    ProgressView(value: Double(dc.progress.done), total: Double(max(1, dc.progress.total))).frame(width: 160)
                    Button("Stop") { dc.cancel() }
                } else {
                    Button { dc.download(target: target) } label: {
                        Label(dc.storedDays.isEmpty ? "Download \(target) days from NSE" : "Update now", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    Picker("", selection: $target) {
                        ForEach([300, 450, 600, 750], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().fixedSize().help("How many trading days of history to keep complete")
                }
                if dc.isLoading { ProgressView().controlSize(.small); Text("Reading…").font(.caption) }
                Text(storedText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let s = dc.status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            HStack(spacing: 10) {
                Text("Signal: ta.highest(").font(.caption.monospaced())
                Picker("", selection: $useValue) {
                    Text("DELIV_QTY * CLOSE_PRICE").tag(true)
                    Text("DELIV_QTY").tag(false)
                }
                .labelsHidden().fixedSize().font(.caption.monospaced())
                .help("DELIV_QTY × CLOSE_PRICE = value of shares delivered that day (₹), from NSE's own close")
                Text(",").font(.caption.monospaced())
                TextField("", value: $length, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
                Text(")").font(.caption.monospaced())
                Picker("", selection: $onlyRises) {
                    Text("makes a new high").tag(true)
                    Text("changes (any update)").tag(false)
                }
                .labelsHidden().fixedSize()
                .help("New high = the highest rises. Any update = exactly Pine's ta.change(ta.highest(...)) != 0, which also fires when an old high leaves the window.")
                Toggle("Wait for full \(length) days (like Pine's na)", isOn: $full).toggleStyle(.checkbox)
                Divider().frame(height: 16)
                Text("Within last").font(.caption)
                Stepper("\(within) day\(within == 1 ? "" : "s")", value: $within, in: 1...250).fixedSize()
                Picker("", selection: $scope) {
                    ForEach(["Sheet stocks", "My Filter", "All NSE"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button { copyPine() } label: { Label("Copy Pine Script", systemImage: "doc.on.clipboard") }
                    .help("A TradingView indicator that paints these exact signal days (orange + ▲DQ) on your TradingView charts — for the stocks in the selected scope")
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 130)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var metricName: String { useValue ? "DELIV_QTY*CLOSE_PRICE" : "DELIV_QTY" }

    private var storedText: String {
        guard let a = dc.storedDays.first, let b = dc.storedDays.last else { return "No delivery data yet" }
        let mb = Double(DeliveryFiles.totalBytes()) / 1_048_576
        return "\(dc.storedDays.count) trading days (\(a) → \(b)) · \(dc.book.series.count) symbols · \(String(format: "%.1f", mb)) MB compressed"
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

    private var shownRows: [DelivRow] {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        return q.isEmpty ? rows : rows.filter { $0.symbol.contains(q) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(shownRows.count) stocks with a signal in the last \(within) trading day\(within == 1 ? "" : "s")").font(.caption.bold())
                if computing { ProgressView().controlSize(.mini) }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Table(shownRows, selection: $selected) {
                TableColumn("Symbol") { r in Text(r.symbol).bold() }.width(min: 80, ideal: 100)
                TableColumn("Signal day") { r in Text(r.lastSignal ?? "—").monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Ago") { r in Text(r.barsAgo.map { $0 == 0 ? "today" : "\($0)d" } ?? "—").monospacedDigit() }.width(min: 40, ideal: 48)
                TableColumn(useValue ? "Deliv value ₹" : "DELIV_QTY") { r in Text(Self.short(r.qty)).monospacedDigit() }.width(min: 70, ideal: 85)
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
                HStack {
                    Text(s).font(.title3.bold())
                    if let c = candles.last { Text(String(format: "%.2f", c.close)).font(.headline.monospacedDigit()) }
                    Text("scroll / pinch = zoom · drag = pan · double-click the date axis = reset").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $range) { ForEach(["6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button("TradingView") { vm.openChart(s, queue: shownRows.map(\.symbol), openWindow: openWindow) }.controlSize(.small)
                }
                if loadingChart { ProgressView("Yahoo prices…").controlSize(.small) }
                if let e = chartError { Text("Yahoo: \(e) — showing delivery only").font(.caption).foregroundStyle(.orange) }
                LWChartView(holder: lw)
                    .frame(minHeight: 380)
                Text("Orange bands + ▲DQ = ta.highest(\(metricName), \(length)) \(onlyRises ? "made a new high" : "updated") · bars at the bottom = \(metricName) · blue = the rolling highest")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select a stock to see its candles with delivery highs marked.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .onChange(of: candles.count) { _ in pushChart() }
        .onChange(of: range) { _ in pushChart() }
        .onChange(of: useValue) { _ in pushChart() }
        .onChange(of: length) { _ in pushChart() }
        .onChange(of: onlyRises) { _ in pushChart() }
        .onChange(of: full) { _ in pushChart() }
        .onChange(of: colorScheme) { _ in pushChart() }
    }

    private func pushChart() {
        guard let s = selected else { return }
        lw.show(LWChartData.make(symbol: s, series: dc.book.series[s], candles: candles, useValue: useValue, length: max(2, length),
                                 full: full, onlyRises: onlyRises, range: range, dark: colorScheme == .dark))
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
            let idx = DeliverySignal.signals(s.metric(value: useValue), length: len, full: full, onlyRises: onlyRises)
            if !idx.isEmpty { sigs.append((sym, idx.map { s.days[$0] })) }
        }
        let script = DeliveryPine.script(signals: sigs, metric: useValue ? "DELIV_QTY*CLOSE_PRICE" : "DELIV_QTY", length: len)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        dc.status = "Pine Script copied: \(sigs.count) stocks, \(sigs.reduce(0) { $0 + $1.days.count }) signal days (\(script.count / 1024) KB). In TradingView: Pine Editor → paste → Add to chart (on both layouts)."
    }

    private func points(_ s: DeliverySeries) -> [DelivPoint] {
        let m = s.metric(value: useValue)
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
        let len = max(2, length), fl = full, rises = onlyRises, win = within, val = useValue
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
            let out = await Task.detached(priority: .userInitiated) { () -> [DelivRow] in
                var res: [DelivRow] = []
                for (sym, s) in book.series {
                    if let allowed, !allowed.contains(sym) { continue }
                    let m = s.metric(value: val)
                    let sig = DeliverySignal.signals(m, length: len, full: fl, onlyRises: rises)
                    guard let last = sig.last, let di = dayIndex[s.days[last]] else { continue }
                    let ago = lastIndex - di
                    guard ago < win else { continue }
                    let lo = max(0, last - len + 1)
                    let window = m[lo...last]
                    let avg = window.reduce(0, +) / Double(window.count)
                    res.append(DelivRow(symbol: sym, lastSignal: s.days[last], barsAgo: ago, qty: m[last], per: s.per[last],
                                        xAvg: avg > 0 ? m[last] / avg : nil, signals: sig.count, latestQty: m.last ?? 0))
                }
                return res.sorted { ($0.barsAgo ?? 999, -($0.xAvg ?? 0)) < ($1.barsAgo ?? 999, -($1.xAvg ?? 0)) }
            }.value
            rows = out
            computing = false
            if selected == nil || !out.contains(where: { $0.symbol == selected }) { selected = out.first?.symbol }
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
    @ObservedObject private var dc = DeliveryCenter.shared
    @StateObject private var lw = LWChartHolder()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("deliv.length") private var length = 300
    @AppStorage("deliv.useValue") private var useValue = true
    @AppStorage("deliv.onlyRises") private var onlyRises = true
    @AppStorage("deliv.full") private var full = true
    @AppStorage("viewer.delivRange") private var range = "1Y"

    var body: some View {
        let s = dc.book.series[symbol.uppercased()]
        let sig = s.map { DeliverySignal.signals($0.metric(value: useValue), length: max(2, length), full: full, onlyRises: onlyRises) } ?? []
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Delivery").font(.caption.bold())
                Text(useValue ? "DELIV_QTY × CLOSE" : "DELIV_QTY").font(.caption.monospaced()).foregroundStyle(.secondary)
                if let s, let last = sig.last {
                    let ago = dc.book.days.count - 1 - (dc.book.days.firstIndex(of: s.days[last]) ?? dc.book.days.count - 1)
                    Text("last \(length)-day high: \(s.days[last]) (\(ago == 0 ? "today" : "\(ago)d ago")) · \(sig.count) in history")
                        .font(.caption).foregroundStyle(.orange)
                } else if s == nil {
                    Text(dc.storedDays.isEmpty ? "No NSE delivery data yet — open Delivery Analysis (⌥⌘D) to download it." : "No NSE delivery data for \(symbol).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $range) { ForEach(["6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            if s != nil { LWChartView(holder: lw) }
        }
        .onAppear { dc.loadIfNeeded(); push() }
        .onChange(of: symbol) { _ in push() }
        .onChange(of: dc.revision) { _ in push() }
        .onChange(of: range) { _ in push() }
        .onChange(of: useValue) { _ in push() }
        .onChange(of: colorScheme) { _ in push() }
    }

    private func push() {
        let sym = symbol.uppercased()
        guard let s = dc.book.series[sym] else { return }
        lw.show(LWChartData.make(symbol: sym, series: s, candles: [], useValue: useValue, length: max(2, length),
                                 full: full, onlyRises: onlyRises, range: range, dark: colorScheme == .dark))
    }
}

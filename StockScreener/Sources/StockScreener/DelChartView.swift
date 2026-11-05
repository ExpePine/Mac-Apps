import SwiftUI
import Charts
import WebKit

// MARK: - DEL chart: the whole market's delivered value per day
//
// Σ DELIV_QTY × CLOSE over every stock in the stored NSE delivery data (₹ crore), day by day.
// Toggle: Σ VOLUME × CLOSE (traded value; volume = DELIV_QTY ÷ delivery % — both from the same NSE file),
// the market's delivery % (delivered ÷ traded) and Nifty 50, to see how the market is doing.

struct DelMarketDay: Identifiable {
    let day: String
    let date: Date
    let del: Double          // ₹ Cr
    let vol: Double          // ₹ Cr
    let stocks: Int
    var id: String { day }
    var delPct: Double? { vol > 0 ? del / vol * 100 : nil }
}

enum DelMarket {
    static func build(_ book: DeliveryBook, only: Set<String>?) -> [DelMarketDay] {
        var del: [String: Double] = [:], vol: [String: Double] = [:], n: [String: Int] = [:]
        for (sym, s) in book.series {
            if let only, !only.contains(sym) { continue }
            let c = min(s.days.count, s.qty.count, s.close.count)
            for i in 0..<c {
                let v = s.qty[i] * s.close[i]
                guard v.isFinite, v > 0 else { continue }
                let d = s.days[i]
                del[d, default: 0] += v
                if i < s.per.count, s.per[i] > 0 { vol[d, default: 0] += v * 100 / s.per[i] }
                n[d, default: 0] += 1
            }
        }
        return del.keys.sorted().map { d in
            DelMarketDay(day: d, date: WatchCurve.date(d), del: del[d]! / 1e7, vol: (vol[d] ?? 0) / 1e7, stocks: n[d] ?? 0)
        }
    }

    static func sma(_ x: [Double], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count), sum = 0.0
        for i in x.indices {
            sum += x[i]
            if i >= n { sum -= x[i - n] }
            if i >= n - 1 { out[i] = sum / Double(n) }
        }
        return out
    }
}

struct DelChartView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var dc = DeliveryCenter.shared
    @AppStorage("delchart.vol") private var showVol = true
    @AppStorage("delchart.pct") private var showPct = true
    @AppStorage("delchart.nifty") private var showNifty = true
    @AppStorage("delchart.sma") private var showSMA = true
    @AppStorage("delchart.range") private var range = "6M"
    @AppStorage("delchart.scope") private var scope = "All NSE stocks"
    @State private var data: [DelMarketDay] = []
    @State private var busy = false
    @State private var hover: String?
    @AppStorage("delchart.tv") private var showTV = true
    @AppStorage("delchart.sync") private var sync = true
    @StateObject private var pool = ReelPool()
    @State private var tvRange: (from: Date, to: Date)?
    @State private var pushedAt = Date.distantPast
    @State private var syncNote: String?
    private let syncTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    /// The NIFTY 50 chart in your own TradingView layout (Chart 1's link with ?symbol=NSE%3ANIFTY).
    private var niftyURL: URL? {
        guard let any = vm.allSymbols.first, let u = vm.chartURL(any, column: 0)?.absoluteString else { return nil }
        var base = u.components(separatedBy: "?").first ?? u
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + "?symbol=NSE%3ANIFTY")
    }
    private func tvWeb() -> WKWebView? { niftyURL.map { pool.view(for: $0, slot: 0) } }

    /// TradingView → these charts: follow its visible dates.
    private func pollTV() {
        guard showTV, sync, Date().timeIntervalSince(pushedAt) > 1.2, let w = tvWeb(), OnScreen.visible(w), !w.isLoading else { return }
        TVRange.run(w, TVRange.getBody) { r in
            let p = r.split(separator: ",").compactMap { Int($0) }
            guard p.count >= 2, p[1] > p[0] else { syncNote = r.hasPrefix("noapi") ? "TradingView doesn't expose its chart here — the range buttons still move it" : nil; return }
            syncNote = nil
            let f = Date(timeIntervalSince1970: Double(p[0])), t = Date(timeIntervalSince1970: Double(p[1]))
            if tvRange.map({ abs($0.from.timeIntervalSince(f)) > 3600 || abs($0.to.timeIntervalSince(t)) > 3600 }) ?? true { tvRange = (f, t) }
        }
    }

    /// These charts' range buttons → TradingView.
    private func pushRange() {
        guard showTV, sync, let w = tvWeb(), let a = rangeDays.first, let b = rangeDays.last else { return }
        pushedAt = Date()
        tvRange = nil
        TVRange.run(w, TVRange.setBody(from: Int(a.date.timeIntervalSince1970), to: Int(b.date.timeIntervalSince1970) + 86_399)) { _ in }
    }

    private struct P: Identifiable { let id: String; let date: Date; let v: Double; let series: String }

    /// What's drawn: TradingView's visible dates when synced, else the range buttons.
    private var shown: [DelMarketDay] {
        if sync, showTV, let r = tvRange {
            let f = r.from.addingTimeInterval(-86_400), t = r.to.addingTimeInterval(86_400)
            let s = data.filter { $0.date >= f && $0.date <= t }
            if s.count >= 2 { return s }
        }
        return rangeDays
    }

    private var rangeDays: [DelMarketDay] {
        let n: Int
        switch range { case "1M": n = 22; case "3M": n = 66; case "6M": n = 132; case "1Y": n = 250; case "2Y": n = 500; default: n = .max }
        return n == .max ? data : Array(data.suffix(n))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 10, lineSpacing: 6) {
                Text("DEL chart").font(.title2.bold())
                Picker("", selection: $range) { ForEach(["1M", "3M", "6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: $scope) { ForEach(["All NSE stocks", "Sheet stocks", "My Filter"], id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().fixedSize()
                Toggle("VOL × CLOSE", isOn: $showVol).toggleStyle(.button)
                Toggle("Delivery %", isOn: $showPct).toggleStyle(.button)
                Toggle("Nifty 50", isOn: $showNifty).toggleStyle(.button)
                Toggle("22-day average", isOn: $showSMA).toggleStyle(.button)
                Toggle("NIFTY chart (TradingView)", isOn: $showTV).toggleStyle(.button)
                if showTV {
                    Toggle(isOn: $sync) { Image(systemName: "link") }.toggleStyle(.button)
                        .help("Keep these charts on TradingView's dates (pan / zoom TradingView; the range buttons move it too)")
                }
                if let n = syncNote { Text(n).font(.caption2).foregroundStyle(.orange).lineLimit(1) }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(dc.storedDays.count) NSE days stored").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            if data.isEmpty {
                VStack(spacing: 8) {
                    Text(dc.storedDays.isEmpty ? "No NSE delivery data yet — download it in Delivery Analysis." : (busy ? "Adding up…" : "No days in this range."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showTV, let u = niftyURL {
                VSplitView {
                    ReelWebView(web: pool.view(for: u, slot: 0)).frame(minHeight: 220, idealHeight: 340)
                    ScrollView { content.padding(12) }.frame(minHeight: 200)
                }
            } else {
                ScrollView { content.padding(12) }
            }
        }
        .onReceive(syncTimer) { _ in pollTV() }
        .onChange(of: range) { _ in pushRange() }
        .onChange(of: sync) { on in if on { pushRange() } else { tvRange = nil } }
        .onDisappear { pool.releaseAll() }
        .task(id: "\(dc.revision)|\(scope)|\(vm.filterVersion)") { await recompute() }
        .onAppear { dc.loadIfNeeded() }
    }

    private func recompute() async {
        busy = true
        let book = dc.book
        var only: Set<String>?
        if scope == "Sheet stocks" { only = Set(vm.allSymbols.map { $0.uppercased() }) }
        if scope == "My Filter" { only = Set(vm.filterRows.map { vm.rowKey($0).uppercased() }) }
        let o = only
        data = await Task.detached(priority: .userInitiated) { DelMarket.build(book, only: o) }.value
        busy = false
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let s = shown
        let all = data
        let delAvg = DelMarket.sma(all.map(\.del), 22), volAvg = DelMarket.sma(all.map(\.vol), 22)
        let off = all.count - s.count
        VStack(alignment: .leading, spacing: 14) {
            tiles(s, delAvg: delAvg, volAvg: volAvg)

            GroupBox("Delivered value — Σ DELIV_QTY × CLOSE (₹ Cr)" + (showVol ? " · traded value Σ VOL × CLOSE" : "")) {
                let pts: [P] = s.enumerated().flatMap { k, d -> [P] in
                    var p = [P(id: d.day + "d", date: d.date, v: d.del, series: "Delivered (DEL × CLOSE)")]
                    if showVol, d.vol > 0 { p.append(P(id: d.day + "v", date: d.date, v: d.vol, series: "Traded (VOL × CLOSE)")) }
                    if showSMA, let a = delAvg[off + k] { p.append(P(id: d.day + "da", date: d.date, v: a, series: "Delivered, 22-day avg")) }
                    if showSMA, showVol, let a = volAvg[off + k], a > 0 { p.append(P(id: d.day + "va", date: d.date, v: a, series: "Traded, 22-day avg")) }
                    return p
                }
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Day", p.date), y: .value("₹ Cr", p.v), series: .value("Series", p.series))
                            .foregroundStyle(by: .value("Series", p.series))
                            .lineStyle(StrokeStyle(lineWidth: p.series.contains("avg") ? 1 : 1.8, dash: p.series.contains("avg") ? [4, 3] : []))
                    }
                    if let h = hover, let d = s.first(where: { $0.day == h }) { RuleMark(x: .value("Day", d.date)).foregroundStyle(Color.gray.opacity(0.5)) }
                }
                .chartForegroundStyleScale(["Delivered (DEL × CLOSE)": Color.blue, "Traded (VOL × CLOSE)": Color.orange,
                                            "Delivered, 22-day avg": Color.blue.opacity(0.5), "Traded, 22-day avg": Color.orange.opacity(0.5)])
                .chartOverlay { proxy in hoverLayer(proxy, s) }
                .chartXScale(domain: xDomain(s))
                .frame(height: 260)
            }

            if showPct {
                GroupBox("Market delivery % — delivered ÷ traded") {
                    Chart(s.filter { $0.delPct != nil }) { d in
                        LineMark(x: .value("Day", d.date), y: .value("%", d.delPct!)).foregroundStyle(Color.purple)
                        if let h = hover, h == d.day { PointMark(x: .value("Day", d.date), y: .value("%", d.delPct!)).foregroundStyle(Color.purple) }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartOverlay { proxy in hoverLayer(proxy, s) }
                    .chartXScale(domain: xDomain(s))
                    .frame(height: 130)
                }
            }

            if showNifty, let n = vm.priceBook.series(for: ScreenerViewModel.benchmarkSymbol) {
                let set = Set(s.map(\.day))
                let np = n.days.indices.filter { set.contains(n.days[$0]) }.map { P(id: n.days[$0], date: WatchCurve.date(n.days[$0]), v: n.closes[$0], series: "Nifty 50") }
                if !np.isEmpty {
                    GroupBox("Nifty 50") {
                        Chart(np) { p in LineMark(x: .value("Day", p.date), y: .value("Nifty", p.v)).foregroundStyle(Color.green) }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .chartOverlay { proxy in hoverLayer(proxy, s) }
                            .chartXScale(domain: xDomain(s))
                            .frame(height: 130)
                    }
                }
            }

            Text("From NSE's daily delivery files stored by the app (Delivery Analysis): every stock's DELIV_QTY × CLOSE_PRICE added up per day; traded value uses the same file's volume (DELIV_QTY ÷ DELIV_PER). Days with missing files show as dips — use Check gaps in Delivery Analysis.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func tiles(_ s: [DelMarketDay], delAvg: [Double?], volAvg: [Double?]) -> some View {
        let d = hover.flatMap { h in s.first { $0.day == h } } ?? s.last
        let idx = d.flatMap { x in data.firstIndex { $0.day == x.day } }
        let da = idx.flatMap { delAvg[$0] }, va = idx.flatMap { volAvg[$0] }
        func cr(_ v: Double) -> String { v >= 1e5 ? String(format: "₹%.2f L Cr", v / 1e5) : String(format: "₹%.0f Cr", v) }
        func vs(_ a: Double, _ b: Double?) -> String { b.map { String(format: "%+.0f%% vs 22-day avg", (a / $0 - 1) * 100) } ?? "" }
        return FlowLayout(spacing: 24, lineSpacing: 6) {
            if let d {
                tile(hover == nil ? "Latest day" : "Day", d.day, .primary, "\(d.stocks) stocks")
                tile("Delivered value", cr(d.del), .blue, vs(d.del, da))
                if d.vol > 0 { tile("Traded value", cr(d.vol), .orange, vs(d.vol, va)) }
                if let p = d.delPct { tile("Delivery %", String(format: "%.1f%%", p), .purple) }
                if let n = vm.priceBook.series(for: ScreenerViewModel.benchmarkSymbol), let c = n.dailyChange(on: d.day) {
                    tile("Nifty 50 that day", String(format: "%+.2f%%", c), c >= 0 ? .green : .red)
                }
            }
        }
    }

    /// Same dates on every panel (TradingView's when synced) so they line up.
    private func xDomain(_ s: [DelMarketDay]) -> ClosedRange<Date> {
        if sync, showTV, let r = tvRange, r.to > r.from { return r.from...r.to }
        let a = s.first?.date ?? Date(), b = s.last?.date ?? Date()
        return a...(b > a ? b : a.addingTimeInterval(86_400))
    }

    private func hoverLayer(_ proxy: ChartProxy, _ s: [DelMarketDay]) -> some View {
        GeometryReader { g in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let x = p.x - g[proxy.plotAreaFrame].origin.x
                        if let date: Date = proxy.value(atX: x) {
                            hover = s.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.day
                        }
                    case .ended: hover = nil
                    }
                }
        }
    }

    private func tile(_ t: String, _ v: String, _ c: Color, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.title3.bold().monospacedDigit()).foregroundStyle(c)
            if let note, !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Market totals for every NSE stock, worked out once per NSE update (shared by the DEL chart and Daily Gainers)

@MainActor final class DelMarketCenter: ObservableObject {
    static let shared = DelMarketCenter()
    @Published private(set) var days: [DelMarketDay] = []
    private var rev = -1
    private var working = false

    /// Recomputes in the background when the stored NSE data changed.
    func refreshIfNeeded() {
        let dc = DeliveryCenter.shared
        guard !working, dc.revision != rev, !dc.book.series.isEmpty else { return }
        working = true
        let book = dc.book, r = dc.revision
        Task {
            let d = await Task.detached(priority: .utility) { DelMarket.build(book, only: nil) }.value
            days = d; rev = r; working = false
        }
    }
}

/// Two chips for the markets strip: the whole NSE's delivered value (Σ DELIV_QTY × CLOSE) and traded value (Σ VOL × CLOSE)
/// on the latest stored NSE day, vs the day before, with a 22-day sparkline. Click = DEL chart.
struct DelMarketChips: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var c = DelMarketCenter.shared
    @ObservedObject private var dc = DeliveryCenter.shared

    var body: some View {
        Group {
            if c.days.count >= 2 {
                chip("NSE DEL × CLOSE", c.days.map(\.del), color: .blue)
                if c.days.last!.vol > 0 { chip("NSE VOL × CLOSE", c.days.map(\.vol), color: .orange) }
            }
        }
        .onAppear { dc.loadIfNeeded(); c.refreshIfNeeded() }
        .onChange(of: dc.revision) { _ in c.refreshIfNeeded() }
    }

    private func chip(_ name: String, _ v: [Double], color: Color) -> some View {
        let last = v[v.count - 1], prev = v[v.count - 2]
        let ch = prev > 0 ? (last / prev - 1) * 100 : nil
        let avg = v.suffix(22).reduce(0, +) / Double(min(22, v.count))
        let vsAvg = avg > 0 ? (last / avg - 1) * 100 : nil
        let up = (ch ?? 0) >= 0
        let tint: Color = ch == nil ? .secondary : (up ? .green : .red)
        let spark = Array(v.suffix(22))
        let day = c.days.last?.day ?? ""
        return Button { openWindow(id: "delchart") } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.caption2.bold()).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(last >= 1e5 ? String(format: "₹%.2fL Cr", last / 1e5) : String(format: "₹%.0f Cr", last)).font(.caption.monospacedDigit().bold())
                        if let ch { Text(String(format: "%+.1f%%", ch)).font(.caption2.monospacedDigit().bold()).foregroundStyle(tint) }
                    }
                }
                Chart {
                    ForEach(Array(spark.enumerated()), id: \.offset) { p in
                        LineMark(x: .value("t", p.offset), y: .value("v", p.element)).foregroundStyle(color)
                    }
                    RuleMark(y: .value("avg", avg)).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 46, height: 22)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help("\(name) for all NSE stocks on \(day): vs the previous NSE day " + (ch.map { String(format: "%+.1f%%", $0) } ?? "—")
              + (vsAvg.map { String(format: ", vs its 22-day average %+.1f%%", $0) } ?? "") + ". Click for the DEL chart.")
    }
}

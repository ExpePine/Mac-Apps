import SwiftUI

// MARK: - Study: ta.barssince(ta.percentrank(DELIV_QTY * CLOSE, 300) == 100) and the returns after it
//
// On each stock's NSE days (its own bars, like a Pine daily chart):
//   v = DELIV_QTY × CLOSE_PRICE
//   ta.percentrank(v, 300) == 100  ⇔  v is ≥ every one of the previous 300 values (Pine counts "≤", ties included)
//   barssince = bars since the last such day (0 on the day itself, na before the first one)
// Returns use NSE's CLOSE_PRICE from the same files: close[i + h] / close[i] − 1, h = 5 and 22 bars by default.

enum BarsSinceStudy {
    struct Event: Identifiable, Hashable {
        var id: String { sym + "|" + day }
        let sym: String
        let day: String
        let value: Double              // delivered value that day (₹)
        let fwd: [Double?]             // per horizon
    }

    struct Now: Identifiable, Hashable {
        var id: String { sym }
        let sym: String
        let barsSince: Int
        let lastDay: String
        let sinceReturn: Double?       // close now / close on that day − 1
        let fwd: [Double?]             // of the last event
    }

    struct Bucket: Identifiable {
        var id: String { label }
        let label: String
        var n = [Int](), sum = [Double](), wins = [Int]()
        func avg(_ h: Int) -> Double? { n.indices.contains(h) && n[h] > 0 ? sum[h] / Double(n[h]) : nil }
        func win(_ h: Int) -> Double? { n.indices.contains(h) && n[h] > 0 ? Double(wins[h]) / Double(n[h]) : nil }
    }

    struct Result {
        var events: [Event] = []
        var now: [Now] = []
        var buckets: [Bucket] = []
        var baseline: Bucket = Bucket(label: "Any day")
        var stocks = 0
        var horizons: [Int] = [5, 22]
        var length = 300
    }

    static let bucketEdges: [(String, ClosedRange<Int>)] = [
        ("0 (the day itself)", 0...0), ("1–5", 1...5), ("6–22", 6...22), ("23–66", 23...66), ("67–150", 67...150), ("151+", 151...Int.max),
    ]

    /// Indices where v is ≥ the max of the previous `length` values (sliding-window max, O(n)).
    static func hits(_ v: [Double], length: Int) -> [Int] {
        guard length > 0, v.count > length else { return [] }
        var out: [Int] = []
        var dq: [Int] = []          // indices of a decreasing window of the previous `length` values
        var head = 0
        for i in 0..<v.count {
            if i >= length {
                while head < dq.count && dq[head] < i - length { head += 1 }
                if head < dq.count, v[i] >= v[dq[head]] { out.append(i) }
            }
            while dq.count > head && v[dq[dq.count - 1]] <= v[i] { dq.removeLast() }
            dq.append(i)
            if head > 4096 { dq.removeFirst(head); head = 0 }
        }
        return out
    }

    static func run(_ series: [String: DeliverySeries], symbols: [String]?, length: Int, horizons: [Int]) -> Result {
        assemble(series, symbols: symbols, length: length, horizons: horizons) { _, s in
            let v = s.metric(value: true)
            return v.count > length ? (hits(v, length: length), length) : nil
        }
    }

    /// Shared by every study: `events(sym, series)` gives the event bars and the first bar the condition can be judged.
    static func assemble(_ series: [String: DeliverySeries], symbols: [String]?, length: Int, horizons: [Int],
                         events: (String, DeliverySeries) -> (hits: [Int], start: Int)?) -> Result {
        var res = Result(horizons: horizons, length: length)
        let H = horizons.count
        func newBucket(_ l: String) -> Bucket { Bucket(label: l, n: .init(repeating: 0, count: H), sum: .init(repeating: 0, count: H), wins: .init(repeating: 0, count: H)) }
        var buckets = bucketEdges.map { newBucket($0.0) }
        var base = newBucket("Any day")
        let syms = symbols.map { Set($0) }
        for (sym, s) in series {
            if let syms, !syms.contains(sym) { continue }
            let v = s.metric(value: true)
            let c = s.close
            guard let ev = events(sym, s) else { continue }
            res.stocks += 1
            let hs = ev.hits
            func fwd(_ i: Int) -> [Double?] {
                horizons.map { h in i + h < c.count && c[i] > 0 ? c[i + h] / c[i] - 1 : nil }
            }
            for i in hs { res.events.append(Event(sym: sym, day: s.days[i], value: v[i], fwd: fwd(i))) }
            if let last = hs.last {
                let n = v.count - 1
                res.now.append(Now(sym: sym, barsSince: n - last, lastDay: s.days[last],
                                   sinceReturn: c[last] > 0 ? c[n] / c[last] - 1 : nil, fwd: fwd(last)))
            }
            // every day: forward return by barssince bucket, and for all days (baseline)
            var k = 0, lastHit: Int? = nil
            for i in max(0, ev.start)..<v.count {
                while k < hs.count && hs[k] <= i { lastHit = hs[k]; k += 1 }
                let f = fwd(i)
                for (h, r) in f.enumerated() {
                    guard let r else { continue }
                    base.n[h] += 1; base.sum[h] += r; if r > 0 { base.wins[h] += 1 }
                    if let lh = lastHit, let b = bucketEdges.firstIndex(where: { $0.1.contains(i - lh) }) {
                        buckets[b].n[h] += 1; buckets[b].sum[h] += r; if r > 0 { buckets[b].wins[h] += 1 }
                    }
                }
            }
        }
        res.events.sort { ($0.day, $0.sym) > ($1.day, $1.sym) }
        res.now.sort { ($0.barsSince, $0.sym) < ($1.barsSince, $1.sym) }
        res.buckets = buckets
        res.baseline = base
        return res
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

// MARK: - View (Performance → Studies)

struct StudiesView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var dc = DeliveryCenter.shared
    @AppStorage("study.bs.length") private var length = 300
    @AppStorage("study.bs.h1") private var h1 = 5
    @AppStorage("study.bs.h2") private var h2 = 22
    @AppStorage("study.bs.scope") private var scope = "Sheet stocks"
    @AppStorage("study.bs.tab") private var tab = 0
    @AppStorage("study.kind") private var kind = 0                   // 0 = bars since delivery top, 1 = T3F + T3S + T3 × HI
    @AppStorage("study.x.fast") private var needFast = true
    @AppStorage("study.x.slow") private var needSlow = true
    @AppStorage("study.x.sma") private var hiSma = 0                  // 0 = follow the Delivery signal (22 unless 66)
    private var ev1: String { kind == 0 ? "==100 day" : "signal day" }
    @AppStorage("study.bs.recent") private var recentDays = 0          // 0 = all events
    @State private var result: BarsSinceStudy.Result?
    @State private var running = false
    @State private var selEvents = Set<String>()
    @State private var selNow = Set<String>()

    private var horizons: [Int] { [max(1, h1), max(1, h2)] }

    private func pct(_ v: Double?) -> String { v.map { String(format: "%+.2f%%", $0 * 100) } ?? "—" }
    private func color(_ v: Double?) -> Color { (v ?? 0) > 0 ? .green : ((v ?? 0) < 0 ? .red : .secondary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            if dc.book.series.isEmpty {
                VStack(spacing: 8) {
                    Text("Needs NSE delivery data").font(.title3.bold())
                    Text("Download it in Delivery Analysis — this study uses DELIV_QTY and CLOSE_PRICE from those files.").foregroundStyle(.secondary)
                    Button("Open Delivery Analysis") { openWindow(id: "delivery") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let r = result {
                summary(r)
                Divider()
                Picker("", selection: $tab) {
                    Text("Now — bars since, per stock (\(r.now.count))").tag(0)
                    Text("Every \(ev1) (\(r.events.count))").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 460).padding(8)
                if tab == 0 { nowTable(r) } else { eventsTable(r) }
            } else {
                Text(running ? "Working…" : "Press Run.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { dc.loadIfNeeded(); if result == nil { run() } }
        .onChange(of: dc.revision) { _ in run() }
        .onChange(of: scope) { _ in run() }
        .onChange(of: kind) { _ in result = nil; run() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $kind) {
                Text("Bars since delivery top").tag(0)
                Text("T3F + T3S + T3 crosses HI").tag(1)
            }
            .labelsHidden().fixedSize()
            if kind == 0 {
                Text("ta.barssince(ta.percentrank(DELIV_QTY*CLOSE,").font(.callout.monospaced())
                TextField("", value: $length, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
                Text(") == 100)").font(.callout.monospaced())
            } else {
                Toggle("T3F = 1", isOn: $needFast).toggleStyle(.checkbox)
                    .help("T3_FAST > T3_FAST[1] on that day (Yahoo daily prices; set in Settings → T3 Fast / Slow)")
                Toggle("T3S = 1", isOn: $needSlow).toggleStyle(.checkbox)
                    .help("T3_SLOW > T3_SLOW[1] on that day")
                Text("and ta.crossover(T3, HI)").font(.callout.monospaced())
                    .help("T3 = Tilson T3 of delivery (Settings → T3 on delivery). HI = ta.highest(ta.sma(DELIV_QTY*CLOSE, n), 300)")
                Picker("", selection: $hiSma) {
                    Text("HI sma: signal's").tag(0); Text("HI sma 22").tag(22); Text("HI sma 66").tag(66)
                }
                .labelsHidden().fixedSize()
            }
            Divider().frame(height: 16)
            Text("returns after").font(.caption)
            TextField("", value: $h1, format: .number).frame(width: 34).multilineTextAlignment(.trailing)
            Text("and").font(.caption)
            TextField("", value: $h2, format: .number).frame(width: 34).multilineTextAlignment(.trailing)
            Text("days").font(.caption)
            Picker("", selection: $scope) { ForEach(["Sheet stocks", "My Filter", "All NSE"], id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if running { ProgressView().controlSize(.small) }
            Button { run() } label: { Label("Run", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(running)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func summary(_ r: BarsSinceStudy.Result) -> some View {
        let ev = recentDays > 0 ? Array(r.events.filter { $0.day >= cutoff(recentDays) }) : r.events
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach(0..<r.horizons.count, id: \.self) { h in
                    let vals = ev.compactMap { $0.fwd[h] }
                    let avg = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
                    let win = vals.isEmpty ? nil : Double(vals.filter { $0 > 0 }.count) / Double(vals.count)
                    let base = r.baseline.avg(h)
                    GroupBox("\(r.horizons[h]) days after a \(ev1)") {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text("Average").frame(width: 70, alignment: .leading); Text(pct(avg)).monospacedDigit().foregroundStyle(color(avg)) }
                            HStack { Text("Median").frame(width: 70, alignment: .leading); Text(pct(BarsSinceStudy.median(vals))).monospacedDigit() }
                            HStack { Text("Up").frame(width: 70, alignment: .leading); Text(win.map { String(format: "%.0f%% of %d", $0 * 100, vals.count) } ?? "—").monospacedDigit() }
                            HStack { Text("Any day").frame(width: 70, alignment: .leading); Text(pct(base)).monospacedDigit().foregroundStyle(.secondary) }
                            if let a = avg, let b = base {
                                HStack { Text("Edge").frame(width: 70, alignment: .leading); Text(pct(a - b)).monospacedDigit().bold().foregroundStyle(color(a - b)) }
                            }
                        }
                        .font(.callout).frame(width: 200, alignment: .leading)
                    }
                }
                GroupBox("Average return by bars since") {
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                        GridRow {
                            Text("bars since").gridColumnAlignment(.leading)
                            ForEach(r.horizons, id: \.self) { Text("\($0)d avg"); Text("\($0)d up") }
                            Text("days")
                        }
                        .font(.caption.bold())
                        ForEach(r.buckets) { b in
                            GridRow {
                                Text(b.label).gridColumnAlignment(.leading)
                                ForEach(0..<r.horizons.count, id: \.self) { h in
                                    Text(pct(b.avg(h))).foregroundStyle(color(b.avg(h)))
                                    Text(b.win(h).map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                                }
                                Text("\(b.n.first ?? 0)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("\(r.stocks) stocks · \(ev.count) \(ev1)s").font(.caption).foregroundStyle(.secondary)
                Picker("Events from", selection: $recentDays) {
                    Text("all stored days").tag(0); Text("last 22 days").tag(22); Text("last 66 days").tag(66); Text("last 250 days").tag(250)
                }
                .fixedSize().controlSize(.small)
                Text("Any day = average return over every stock-day, for comparison. Returns use NSE closes on the stock's next trading days; a recent day has no \(r.horizons.last ?? 22)-day return yet.")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12)
    }

    private func cutoff(_ days: Int) -> String {
        let d = dc.book.days
        return d.count > days ? d[d.count - days] : (d.first ?? "")
    }

    private func nowTable(_ r: BarsSinceStudy.Result) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bars since the last \(ev1), newest first").font(.caption.bold())
                Spacer()
                Button { reel(r.now.filter { selNow.isEmpty || selNow.contains($0.id) }.map { ($0.sym, "BS \($0.barsSince) · \(pct($0.sinceReturn)) since", $0.lastDay) }) } label: {
                    Label(selNow.isEmpty ? "Chart Reel of all" : "Chart Reel of \(selNow.count)", systemImage: "film.stack")
                }
                .help("Chart 1 + delivery chart for each, centred on its last \(ev1)")
            }
            .controlSize(.small).padding(.horizontal, 10).padding(.vertical, 5)
            Table(r.now, selection: $selNow) {
                TableColumn("Symbol") { n in SymbolWithDots(symbol: n.sym) }.width(min: 100, ideal: 120)
                TableColumn("Bars since") { n in Text("\(n.barsSince)").monospacedDigit().bold() }.width(70)
                TableColumn("Last \(ev1)") { n in Text(n.lastDay).monospacedDigit() }.width(95)
                TableColumn("Since then") { n in Text(pct(n.sinceReturn)).monospacedDigit().foregroundStyle(color(n.sinceReturn)) }.width(80)
                TableColumn("\(r.horizons[0])d after") { n in Text(pct(n.fwd[0])).monospacedDigit().foregroundStyle(color(n.fwd[0])) }.width(75)
                TableColumn("\(r.horizons[1])d after") { n in Text(pct(n.fwd[1])).monospacedDigit().foregroundStyle(color(n.fwd[1])) }.width(75)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let n = r.now.first(where: { $0.id == id }) {
                    Button("Chart at \(n.lastDay)") { vm.openChart(n.sym, goTo: n.lastDay, openWindow: openWindow) }
                    Button("Chart Reel from \(n.sym)") { reel(r.now.map { ($0.sym, "BS \($0.barsSince)", $0.lastDay) }, start: n.sym) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let n = r.now.first(where: { $0.id == id }) { vm.openChart(n.sym, goTo: n.lastDay, openWindow: openWindow) }
            }
        }
    }

    private func eventsTable(_ r: BarsSinceStudy.Result) -> some View {
        let ev = recentDays > 0 ? r.events.filter { $0.day >= cutoff(recentDays) } : r.events
        return VStack(spacing: 0) {
            HStack {
                Text("Every day the delivered value topped its previous \(r.length) days").font(.caption.bold())
                Spacer()
                Button { reel(ev.filter { selEvents.isEmpty || selEvents.contains($0.id) }.map { ($0.sym, "\(r.horizons[0])d \(pct($0.fwd[0])) · \(r.horizons[1])d \(pct($0.fwd[1]))", $0.day) }) } label: {
                    Label(selEvents.isEmpty ? "Chart Reel of all" : "Chart Reel of \(selEvents.count)", systemImage: "film.stack")
                }
                .help("Chart 1 + delivery chart for each, centred on that day")
            }
            .controlSize(.small).padding(.horizontal, 10).padding(.vertical, 5)
            Table(ev, selection: $selEvents) {
                TableColumn("Symbol") { e in SymbolWithDots(symbol: e.sym) }.width(min: 100, ideal: 120)
                TableColumn("Day") { e in Text(e.day).monospacedDigit() }.width(95)
                TableColumn("Delivered ₹ Cr") { e in Text(String(format: "%.2f", e.value / 1e7)).monospacedDigit() }.width(90)
                TableColumn("\(r.horizons[0])d after") { e in Text(pct(e.fwd[0])).monospacedDigit().foregroundStyle(color(e.fwd[0])) }.width(75)
                TableColumn("\(r.horizons[1])d after") { e in Text(pct(e.fwd[1])).monospacedDigit().foregroundStyle(color(e.fwd[1])) }.width(75)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let e = ev.first(where: { $0.id == id }) {
                    Button("Chart at \(e.day)") { vm.openChart(e.sym, goTo: e.day, openWindow: openWindow) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let e = ev.first(where: { $0.id == id }) { vm.openChart(e.sym, goTo: e.day, openWindow: openWindow) }
            }
        }
    }

    /// Chart Reel (Chart 1 + delivery chart), each centred on its day.
    private func reel(_ items: [(String, String, String)], start: String? = nil) {
        guard !items.isEmpty else { return }
        ScanCenter.shared.reel = items.map { (symbol: $0.0, note: $0.1, day: $0.2) }
        let d = UserDefaults.standard
        d.set(ReelSource.scan.rawValue, forKey: "reel.source")
        let l = ReelLayout(rawValue: d.string(forKey: "reel.layout") ?? "") ?? .chart1
        if l == .chart1 || l == .chart2 { d.set(ReelLayout.withDelivery.rawValue, forKey: "reel.layout") }
        let key = start.flatMap { s in items.first { $0.0 == s }.map { "\($0.0)|\($0.2)" } } ?? ""
        d.set(key, forKey: "reel.mbStart")
        d.set(UUID().uuidString + "|" + key, forKey: "reel.jump")
        openWindow(id: "reel")
    }

    private func run() {
        guard !running, !dc.book.series.isEmpty else { return }
        running = true
        let series = dc.book.series, len = max(2, length), hz = horizons, k = kind
        // the longer of the two Yahoo price histories, per stock, for T3F / T3S
        var prices = vm.priceBook.series
        if k == 1 {
            for (sym, s) in MultibaggerCenter.shared.book.series where s.days.count > (prices[sym]?.days.count ?? 0) { prices[sym] = s }
        }
        var params = CrossStudy.Params()
        params.hiSma = hiSma == 0 ? DeliveryColumns.hiSma : hiSma
        params.needFast = needFast; params.needSlow = needSlow
        var syms: [String]? = nil
        if scope == "Sheet stocks" { syms = vm.allSymbols.map { $0.uppercased() } }
        if scope == "My Filter", let l = vm.labelIndex { syms = vm.filterRows.map { $0.text(l).trimmingCharacters(in: .whitespaces).uppercased() } }
        Task {
            let r: BarsSinceStudy.Result
            if k == 0 {
                r = await Task.detached(priority: .userInitiated) { BarsSinceStudy.run(series, symbols: syms, length: len, horizons: hz) }.value
            } else {
                r = await Task.detached(priority: .userInitiated) { CrossStudy.run(series, prices: prices, symbols: syms, horizons: hz, p: params) }.value
            }
            result = r; running = false
        }
    }
}


// MARK: - Study 2: T3F = 1 and T3S = 1 and delivery T3 crosses over HI

/// Event day: ta.crossover(T3, HI) on the delivery series, where
///   T3 = Tilson T3 of DELIV_QTY*CLOSE (Settings → STREAK · T3 → T3 on delivery)
///   HI = ta.highest(ta.sma(DELIV_QTY*CLOSE, 22 or 66), 300)   (the same HI as the Filter's HI/T3 column)
/// and on that same day the price T3 lines are rising: T3F = 1 (T3_FAST > T3_FAST[1]) and T3S = 1 (T3_SLOW > T3_SLOW[1]),
/// from Yahoo daily prices. A day without a Yahoo price can't be judged and is skipped.
enum CrossStudy {
    struct Params {
        var hiSma = 22
        var hiLength = 300
        var t3 = T3Def.current
        var fast = PriceT3.fast
        var slow = PriceT3.slow
        var needFast = true
        var needSlow = true
    }

    /// Bars where T3 crosses over HI.
    static func crossovers(t3: [Double?], hi: [Double?]) -> [Int] {
        var out: [Int] = []
        guard t3.count == hi.count, t3.count > 1 else { return out }
        for i in 1..<t3.count {
            if let a = t3[i], let b = hi[i], let a0 = t3[i - 1], let b0 = hi[i - 1], a > b, a0 <= b0 { out.append(i) }
        }
        return out
    }

    /// ta.highest(ta.sma(x, n), length) per bar (nil until n − 1 + length bars).
    static func highestSMA(_ x: [Double], n: Int, length: Int) -> [Double?] {
        let sm = DeliverySignal.sma(x, n)
        var out = [Double?](repeating: nil, count: x.count)
        let first = n - 1 + length - 1
        guard x.count > first else { return out }
        var dq: [Int] = [], head = 0
        for i in (n - 1)..<x.count {
            while head < dq.count && dq[head] <= i - length { head += 1 }
            while dq.count > head && sm[dq[dq.count - 1]] <= sm[i] { dq.removeLast() }
            dq.append(i)
            if i >= first { out[i] = sm[dq[head]] }
        }
        return out
    }

    /// Day → rising (1) / not (0) for a price T3 line.
    static func rising(_ p: PriceT3, _ s: PriceSeries) -> [String: Int] {
        let t = T3Def(length: max(1, p.length), factor: p.factor, useQty: false).t3(p.series(s))
        var out: [String: Int] = [:]
        for i in 1..<max(1, t.count) { if let a = t[i], let b = t[i - 1] { out[s.days[i]] = a > b ? 1 : 0 } }
        return out
    }

    static func run(_ series: [String: DeliverySeries], prices: [String: PriceSeries], symbols: [String]?,
                    horizons: [Int], p: Params) -> BarsSinceStudy.Result {
        BarsSinceStudy.assemble(series, symbols: symbols, length: p.hiLength, horizons: horizons) { sym, s in
            let x = s.metric(value: true)
            let hi = highestSMA(x, n: p.hiSma, length: p.hiLength)
            let t3 = p.t3.t3(p.t3.source(s))
            guard let first = zip(t3, hi).firstIndex(where: { $0 != nil && $1 != nil }) else { return nil }
            var hits = crossovers(t3: t3, hi: hi)
            if p.needFast || p.needSlow {
                guard let ps = prices[sym] else { return nil }
                let f = p.needFast ? rising(p.fast, ps) : [:], sl = p.needSlow ? rising(p.slow, ps) : [:]
                hits = hits.filter { i in
                    let d = s.days[i]
                    return (!p.needFast || f[d] == 1) && (!p.needSlow || sl[d] == 1)
                }
            }
            return (hits, first)
        }
    }
}

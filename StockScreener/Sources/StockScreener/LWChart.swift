import SwiftUI
import WebKit

// MARK: - TradingView-style interactive chart (TradingView's open-source Lightweight Charts™ library)
//
// Wheel / pinch to zoom, drag to pan, crosshair with values, double-click the time axis to reset.
// Candles (Yahoo) + delivery bars + the rolling ta.highest line on an overlay scale + orange background
// bands and arrows on signal days. The library is loaded from the jsDelivr CDN (pinned versions).

/// The things that can be drawn on the delivery charts — each one can be switched on / off.
enum ChartLayer: String, CaseIterable, Identifiable {
    case candles, deliv, high, bands, markers, prank, sma22, sma66, per, t3, del2c, hit3, shade, dsmark, news, deals, steep, zpmark, fmark
    var id: String { rawValue }
    func label(_ metric: String, _ length: Int) -> String {
        switch self {
        case .candles: return "Price candles (Yahoo)"
        case .deliv: return "Delivery bars — \(metric)"
        case .high: return "ta.highest(\(metric), \(length)) line"
        case .bands: return "Orange bands on signal days"
        case .markers: return "▲DQ markers on signal days"
        case .prank: return "ta.percentrank(\(metric), \(length))"
        case .sma22: return "ta.sma(delivery, 22) line"
        case .sma66: return "ta.sma(delivery, 66) line"
        case .per: return "Delivery % (DELIV_PER)"
        case .t3: return "T3 line (green rising / red falling) — \(T3Def.current.pine)"
        case .del2c: return "DEL2C line — close on the last DEL2 = 100 day (ta.highest \(Del2.length))"
        case .hit3: return "HI/T3 line — ta.highest(ta.sma(delivery, \(DeliveryColumns.hiSma)), 300) / T3 (dashed line at 1.00)"
        case .shade: return "Shade candles where DELSMAC (percentrank) > \(String(format: "%g", DelsmacShade.level))"
        case .dsmark: return "Green ▲DS under the bar on days DELSMAC > \(String(format: "%g", DelsmacShade.level))"
        case .news: return "News (3–4 word labels, blue ●)"
        case .deals: return "Bulk / block deals — total buy (green) / sell (red) ₹ Cr per day, strip at the top"
        case .fmark: return "Formula marks — days your formulas were true (1F11 = formula 1, true for 11 other stocks); choose which formulas next to the Formula button"
        case .zpmark: return "▲ZP — days Z_PRANK (ta.percentrank of the Steep z, 300) is \(ZPLevel.text)"
        case .steep: return "Sustained steepness — steep when \(Steep.source == "delsma" ? "DELSMA" : "EMA\(Steep.ema)(delivery value)") rose \(Steep.span)-day faster than \(Steep.trig)σ above its \(Steep.norm)-day normal — z, run and energy in the legend (not drawn)"
        }
    }
    var color: Color? {
        switch self {
        case .high: return Color(red: 0.16, green: 0.38, blue: 1)
        case .prank: return Color(red: 0.67, green: 0.28, blue: 0.74)
        case .sma22: return Color(red: 0, green: 0.74, blue: 0.83)
        case .sma66: return Color(red: 0.91, green: 0.12, blue: 0.39)
        case .per: return Color(red: 0.55, green: 0.76, blue: 0.29)
        case .t3: return .green
        case .del2c: return Color(red: 1, green: 0.77, blue: 0)
        case .shade: return Color(red: 0.7, green: 0.4, blue: 1)
        case .dsmark: return Color(red: 0, green: 0.9, blue: 0.46)
        case .hit3: return Color(red: 1, green: 0.54, blue: 0.4)
        case .news: return .blue
        case .deals: return .purple
        case .steep: return Color(red: 0.6, green: 1, blue: 0.2)
        case .zpmark: return Color(red: 0.78, green: 1, blue: 0)
        case .fmark: return Color(red: 0.88, green: 0.25, blue: 0.98)
        case .bands, .markers: return .orange
        default: return nil
        }
    }
    static let defaults: Set<ChartLayer> = [.candles, .deliv, .high, .bands, .markers, .prank, .t3, .del2c, .hit3, .shade, .dsmark]
    /// Stored as "a,b,c" in UserDefaults; "" = the defaults, "none" = nothing.
    static func decode(_ s: String) -> Set<ChartLayer> {
        if s.isEmpty { return defaults }
        var out = Set(s.split(separator: ",").compactMap { ChartLayer(rawValue: String($0)) })
        // saved before T3 existed (no "v2" marker): show T3 too
        if !s.contains("v2") && s != "none" { out.insert(.t3) }
        // saved before DEL2C existed (no "v3"): show it too
        if !s.contains("v3") && s != "none" { out.insert(.del2c) }
        if !s.contains("v4") && s != "none" { out.insert(.shade); out.insert(.candles) }
        if !s.contains("v5") && s != "none" { out.insert(.hit3) }
        if !s.contains("v6") && s != "none" { out.insert(.dsmark) }
        return out
    }
    static func encode(_ set: Set<ChartLayer>) -> String {
        set.isEmpty ? "none" : (allCases.filter(set.contains).map(\.rawValue) + ["v2", "v3", "v4", "v5", "v6"]).joined(separator: ",")
    }
}

/// "Layers" button: a popover of checkboxes choosing what the chart draws (stays open while you tick).
struct ChartLayersButton: View {
    @Binding var raw: String
    var metric: String
    var length: Int
    var options: [ChartLayer] = ChartLayer.allCases
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("Layers", systemImage: "square.3.layers.3d") }
            .help("Choose what the chart shows")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show on chart").font(.headline)
                    ForEach(options) { l in
                        Toggle(isOn: Binding(get: { ChartLayer.decode(raw).contains(l) },
                                             set: { on in var s = ChartLayer.decode(raw); if on { s.insert(l) } else { s.remove(l) }; raw = ChartLayer.encode(s) })) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(l.color ?? .gray).frame(width: 12, height: 3)
                                    .opacity(l.color == nil ? 0.5 : 1)
                                Text(l.label(metric, length))
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    Divider()
                    HStack {
                        Button("All") { raw = ChartLayer.encode(Set(options)) }
                        Button("Default") { raw = "" }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .fixedSize()
            }
    }
}

struct LWChartData: Encodable {
    struct Candle: Encodable {
        let time: String; let open, high, low, close: Double
        var color: String? = nil, borderColor: String? = nil, wickColor: String? = nil     // shaded days (DELSMAC)
    }
    struct Point: Encodable { let time: String; let value: Double?; var color: String? = nil }   // value nil = empty day (gap)
    struct Marker: Encodable {
        let time: String
        var position = "belowBar"
        var color = "#FF9800"
        var shape = "arrowUp"
        let text: String
        var info: String? = nil           // shown on the chart while the crosshair is on this day
        var full: [String]? = nil         // shown under the chart (headlines + source / deal details)
        var id: String? = nil             // clickable markers: "zp" / "deal" (opens the Z / DEALSIZE list)
        init(time: String, text: String, position: String = "belowBar", color: String = "#FF9800", shape: String = "arrowUp",
             info: String? = nil, full: [String]? = nil, id: String? = nil) {
            self.id = id
            self.time = time; self.text = text; self.position = position; self.color = color; self.shape = shape
            self.info = info; self.full = full
        }
    }
    var candles: [Candle] = []
    var deliv: [Point] = []
    var high: [Point] = []
    var bands: [Point] = []
    var markers: [Marker] = []
    /// Your Pine scripts' plots (PineCenter): drawn on a pane and / or shown as a legend number.
    struct PineJS: Encodable {
        let key: String, title: String, color: String
        let pane: String                  // none (legend only) · price · deliv · own
        let style: String                 // line · hist · step
        let width: Double
        let legend: Bool
        let points: [Point]
    }
    var pine: [PineJS] = []
    var fpills: [Marker] = []         // formula pills (1F11 …): drawn as badges in their own lane above the delivery pane
    var prank: [Point] = []           // ta.percentrank(metric, length), 0–100
    var dealBuy: [Point] = []         // bulk + block deal buys per day, ₹ Cr (green bars, top strip)
    var dealSell: [Point] = []
    var dealGold: [String] = []
    var dealsOn = false
    var dprank: [Point] = []          // DEAL_PRANK = ta.percentrank(DEALSIZE = buy + sell ₹ Cr, 300): cyan line
    var filledBand: [Point] = []      // grey band: delivery filled by the app (BE/BZ trade-for-trade)
    var dsmac: [Point] = []           // DELSMAC per day (legend)
    var seriesCodes: [String: String] = [:]   // day → NSE SERIES (EQ / BE / BZ …), for the legend
    var sma22: [Point] = []
    var sma66: [Point] = []
    var per: [Point] = []             // DELIV_PER, 0–100
    var t3: [Point] = []              // T3 with green / red per point
    var hit3: [Point] = []            // HI/T3 ratio, own scale in the delivery pane
    var steepBand: [Point] = []       // lime background on steep days
    var steepEnergy: [Point] = []     // "steep energy": Σ z while steep, 0 otherwise
    var steepZ: [String: Double] = [:]    // day → z (legend)
    var steepRun: [String: Int] = [:]     // day → bars steep (legend)
    var zpDays: [String] = []             // days with a ▲ZP mark (click → Z list)
    var steepZPR: [String: Double] = [:]  // day → ta.percentrank(z, 300) (legend)
    var del2c: [Point] = []           // DEL2C step line (Chart 3: on the price scale; delivery chart: its own scale)
    var d2cOwn = false
    var style = ChartStyle.current      // your look: colours, line width, price / delivery split, grid
    var t3Own = false                 // T3's source differs from the bars → its own scale
    var t3Name = ""
    var title = ""
    var metric = ""
    var range = "1Y"          // 6M / 1Y / 2Y / All
    var dark = true

    /// Builds the chart data for one stock from its delivery series and (optional) Yahoo candles.
    static func make(symbol: String, series: DeliverySeries?, candles: [YahooClient.Candle], metric: DeliveryMetric,
                     length: Int, full: Bool, onlyRises: Bool, range: String, dark: Bool, calendar: [String] = [],
                     layers: Set<ChartLayer> = ChartLayer.defaults, events: [Marker] = [],
                     deals: (buy: [Point], sell: [Point], from: String) = ([], [], "")) -> LWChartData {
        var d = LWChartData()
        let dealsOn = layers.contains(.deals)            // bars, B / S, shade; DEAL_PRANK shows in the legend always
        if dealsOn { d.dealBuy = deals.buy; d.dealSell = deals.sell }
        d.dealsOn = dealsOn
        d.title = symbol
        d.metric = metric.smaLength == nil ? metric.pine : "smooth QTY"
        d.range = range
        d.dark = dark
        var seen = Set<String>()
        d.candles = candles.compactMap { c in
            seen.insert(c.day).inserted ? Candle(time: c.day, open: c.open, high: c.high, low: c.low, close: c.close) : nil
        }
        if !layers.contains(.candles) { d.candles = [] }
        // candles shaded on days DELSMAC is above the level
        if layers.contains(.shade), !d.candles.isEmpty, let s = series {
            let hot = DelsmacShade.days(s)
            if !hot.isEmpty {
                d.candles = d.candles.map { c in
                    guard hot.contains(c.time) else { return c }
                    var x = c
                    let st = ChartStyle.current
                    let col = c.close >= c.open ? st.shadeUp : st.shadeDown
                    x.color = col; x.borderColor = col; x.wickColor = col
                    return x
                }
            }
        }
        if let s = series {
            let m = s.metric(metric)
            if layers.contains(.prank) {
                for i in s.days.indices { if let pr = DeliveryColumns.percentRank(m, length: length, at: i) { d.prank.append(Point(time: s.days[i], value: pr)) } }
            }
            // SMA lines of the raw delivery (₹ value, or shares when the signal uses DELIV_QTY), on the bars' scale
            let base = metric == .qty ? s.qty : s.metric(value: true)
            for (n, l) in [(22, ChartLayer.sma22), (66, .sma66)] where layers.contains(l) {
                let sm = DeliverySignal.sma(base, n)
                let pts = s.days.indices.filter { $0 >= n - 1 }.map { Point(time: s.days[$0], value: sm[$0]) }
                if n == 22 { d.sma22 = pts } else { d.sma66 = pts }
            }
            if layers.contains(.t3) {
                let def = T3Def.current
                let t = def.t3(def.source(s))
                for i in s.days.indices { if let v = t[i] {
                    let up = i > 0 && t[i - 1] != nil && v > t[i - 1]!
                    d.t3.append(Point(time: s.days[i], value: v, color: up ? "#26a69a" : "#ef5350"))
                } }
                d.t3Own = def.useQty != (metric == .qty)
                d.t3Name = "T3(\(def.length))"
            }
            if layers.contains(.hit3) {
                let r = DeliveryColumns.hiT3Series(s)
                for i in s.days.indices where i < r.count { if let v = r[i] { d.hit3.append(Point(time: s.days[i], value: v)) } }
            }
            if layers.contains(.steep) || layers.contains(.zpmark) {
                let r = Steep.series(s)
                let zpr = Steep.zPRank(r.z)
                if layers.contains(.zpmark) {
                    for i in s.days.indices where i < zpr.count { if let v = zpr[i], ZPLevel.hit(v) { d.zpDays.append(s.days[i]) } }
                    for i in s.days.indices where i < zpr.count {
                        if let v = zpr[i], ZPLevel.hit(v) {
                            // golden when z is the highest of the last 300 days (Z_PRANK = 100)
                            d.markers.append(Marker(time: s.days[i], text: "ZP", position: "belowBar", color: v >= 100 ? "#FFD700" : "#C6FF00", shape: "arrowUp", id: "zp"))
                        }
                    }
                }
                for i in s.days.indices where layers.contains(.steep) {
                    if i < zpr.count, let v = zpr[i] { d.steepZPR[s.days[i]] = (v * 10).rounded() / 10 }
                    let day = s.days[i]
                    if let z = r.z[i] { d.steepZ[day] = (z * 100).rounded() / 100 }
                    d.steepRun[day] = r.run[i]
                    d.steepEnergy.append(Point(time: day, value: r.energy[i]))
                    if r.steep[i] { d.steepBand.append(Point(time: day, value: 1, color: "rgba(0,255,0,0.15)")) }
                }
            }
            if layers.contains(.per) { d.per = s.days.indices.map { Point(time: s.days[$0], value: s.per[$0]) } }
            if layers.contains(.del2c) {
                let r = Del2.series(s, full: full)
                for i in s.days.indices where i < r.del2c.count { if let v = r.del2c[i] { d.del2c.append(Point(time: s.days[i], value: v)) } }
                d.d2cOwn = d.candles.isEmpty
            }
            let h = DeliverySignal.highest(m, length: length, full: full)
            let sig = Set(DeliverySignal.signals(m, length: length, full: full, onlyRises: onlyRises))
            for i in s.days.indices {
                let isSig = sig.contains(i)
                d.deliv.append(Point(time: s.days[i], value: m[i], color: isSig ? "rgba(255,152,0,0.95)" : "rgba(128,128,128,0.45)"))
                if let v = h[i] { d.high.append(Point(time: s.days[i], value: v)) }
                if isSig {
                    if layers.contains(.bands) { d.bands.append(Point(time: s.days[i], value: 1, color: "rgba(255,152,0,0.22)")) }
                    if layers.contains(.markers) { d.markers.append(Marker(time: s.days[i], text: "DQ")) }
                }
            }
            if !layers.contains(.high) { d.high = [] }
            // NSE SERIES: legend on every day, a small grey label where it changes (e.g. EQ → BE)
            var prevCode: String?
            for i in s.days.indices where i < s.seriesCode.count {
                let code = s.seriesCode[i]
                d.seriesCodes[s.days[i]] = code
                if let p = prevCode, p != code {
                    d.markers.append(Marker(time: s.days[i], text: code, position: "aboveBar", color: "#9E9E9E", shape: "square"))
                }
                prevCode = code
            }
            for i in s.days.indices where i < s.filled.count && s.filled[i] {
                d.filledBand.append(Point(time: s.days[i], value: 1, color: "rgba(158,158,158,0.28)"))
            }
            let ds = DeliveryColumns.delSmaCSeries(s, metric: DeliveryMetric(rawValue: UserDefaults.standard.string(forKey: "deliv.metric") ?? "") ?? .value)
            for i in s.days.indices where i < ds.count { if let v = ds[i] { d.dsmac.append(Point(time: s.days[i], value: v)) } }
            // Trading days with no NSE row for this stock: keep their place on the date axis (empty bar)
            if let first = s.days.first, let last = s.days.last {
                let have = Set(s.days)
                let empty = calendar.filter { $0 > first && $0 < last && !have.contains($0) }
                if !empty.isEmpty {
                    d.deliv = (d.deliv + empty.map { Point(time: $0, value: nil) }).sorted { $0.time < $1.time }
                }
            }
            if !layers.contains(.deliv) {
                // keep the dates on the axis, draw nothing
                d.deliv = d.deliv.map { Point(time: $0.time, value: nil) }
            }
        }
        d.markers += events.filter { $0.id != "fpill" }
        d.fpills = events.filter { $0.id == "fpill" }
        // Deals: one letter at the candle — B (green, below) on net-buying days, S (red, above) on net-selling days.
        // Golden when that day's total buy (or sell) is the highest of the last 300 trading days (ta.highest(B, 300)).
        let axis: [String] = series?.days ?? []
        func goldDays(_ pts: [Point]) -> Set<String> {
            var v: [String: Double] = [:]
            for p in pts { v[p.time, default: 0] += abs(p.value ?? 0) }
            let ds = v.keys.sorted()
            var out = Set<String>()
            for (k, day) in ds.enumerated() {
                guard let x = v[day], x > 0 else { continue }
                var lo = 0, hi = axis.count                    // first axis day ≥ deal day
                while lo < hi { let m = (lo + hi) / 2; if axis[m] < day { lo = m + 1 } else { hi = m } }
                // the 300-trading-day window's first day (before the NSE days in memory: ~300 weekdays back)
                let start: String
                if lo >= 299 && lo < axis.count { start = axis[lo - 299] }
                else { start = Self.weekdaysBack(day, 299) }
                // golden only when deals are known for the whole window
                guard !deals.from.isEmpty, deals.from != "?", start >= deals.from else { continue }
                var best = 0.0
                for j in stride(from: k - 1, through: 0, by: -1) {
                    if ds[j] < start { break }
                    best = max(best, v[ds[j]] ?? 0)
                }
                if x >= best { out.insert(day) }
            }
            return out
        }
        let goldB = dealsOn ? goldDays(deals.buy) : [], goldS = dealsOn ? goldDays(deals.sell) : []
        if !deals.from.isEmpty || !(deals.buy.isEmpty && deals.sell.isEmpty), !axis.isEmpty {
            var sv: [String: Double] = [:]
            for p in deals.buy { sv[p.time, default: 0] += p.value ?? 0 }
            for p in deals.sell { sv[p.time, default: 0] += abs(p.value ?? 0) }
            for (i, v) in DealsCenter.dealPRank(sv, axis: axis).enumerated() { if let v { d.dprank.append(Point(time: axis[i], value: v)) } }
        }
        d.dealGold = Array(goldB.union(goldS)).sorted()
        let goldBar = "rgba(255,215,0,0.95)"
        d.dealBuy = d.dealBuy.map { goldB.contains($0.time) ? Point(time: $0.time, value: $0.value, color: goldBar) : $0 }
        d.dealSell = d.dealSell.map { goldS.contains($0.time) ? Point(time: $0.time, value: $0.value, color: goldBar) : $0 }
        var buyV: [String: Double] = [:], sellV: [String: Double] = [:]
        for p in deals.buy { buyV[p.time, default: 0] += p.value ?? 0 }
        for p in deals.sell { sellV[p.time, default: 0] += abs(p.value ?? 0) }
        for day in dealsOn ? Set(buyV.keys).union(sellV.keys) : [] {
            let b = buyV[day] ?? 0, sl = sellV[day] ?? 0
            if b > 0 {
                d.markers.append(Marker(time: day, text: "B", position: "belowBar",
                                        color: goldB.contains(day) ? "#FFD700" : "#26a69a", shape: "arrowUp", id: "deal"))
            }
            if sl > 0 {
                d.markers.append(Marker(time: day, text: "S", position: "aboveBar",
                                        color: goldS.contains(day) ? "#FFD700" : "#ef5350", shape: "arrowDown", id: "deal"))
            }
        }
        // green ▲DS on days DELSMAC is above the level
        if layers.contains(.dsmark), let s = series {
            for day in DelsmacShade.days(s).sorted() {
                d.markers.append(Marker(time: day, text: "DS", position: "belowBar", color: "#00E676", shape: "arrowUp"))
            }
        }
        return d
    }

    /// Chart 3: Yahoo candles (else NSE closes) + the DEL2C step line; DEL2 as bars at the bottom (100 = orange, a new
    /// L-day delivery high) with ▲D2 markers on those days.
    static func chart3(symbol: String, series s: DeliverySeries, prices: PriceSeries?, length L: Int, full: Bool,
                       range: String, dark: Bool) -> LWChartData {
        var d = LWChartData()
        d.title = symbol
        d.metric = "DEL2 (\(L))"
        d.range = range
        d.dark = dark
        if let p = prices, let o = p.opens, let h = p.highs, let l = p.lows, o.count == p.closes.count, h.count == p.closes.count, l.count == p.closes.count {
            d.candles = p.days.indices.map { Candle(time: p.days[$0], open: o[$0], high: h[$0], low: l[$0], close: p.closes[$0]) }
        } else {
            d.candles = s.days.indices.map { Candle(time: s.days[$0], open: s.close[$0], high: s.close[$0], low: s.close[$0], close: s.close[$0]) }
        }
        let r = Del2.series(s, length: L, full: full)
        for i in s.days.indices where i < r.del2.count {
            if let v = r.del2c[i] { d.del2c.append(Point(time: s.days[i], value: v)) }
            if let v = r.del2[i] {
                let top = v >= 100
                d.deliv.append(Point(time: s.days[i], value: v, color: top ? "rgba(255,152,0,0.95)" : "rgba(128,128,128,0.45)"))
                if top { d.markers.append(Marker(time: s.days[i], text: "D2", position: "belowBar", color: "#FFC400", shape: "arrowUp")) }
            }
        }
        return d
    }

    var json: String {
        var d = self
        d.markers.sort { $0.time < $1.time }          // the chart library wants markers in time order
        return (try? String(data: JSONEncoder().encode(d), encoding: .utf8)) ?? "{}"
    }

    /// The day `n` weekdays before `day` (yyyy-MM-dd) — trading days approximated where NSE days aren't loaded.
    nonisolated static func weekdaysBack(_ day: String, _ n: Int) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"
        guard var d = f.date(from: day) else { return day }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = f.timeZone
        var k = 0
        while k < n {
            d = cal.date(byAdding: .day, value: -1, to: d)!
            let w = cal.component(.weekday, from: d)
            if w != 1 && w != 7 { k += 1 }
        }
        return f.string(from: d)
    }

    /// Bulk + block deals of one stock as total buy / sell ₹ Cr per day (no client names).
    @MainActor static func dealBars(_ symbol: String, layers: Set<ChartLayer>, from: String = "") -> (buy: [Point], sell: [Point], from: String) {
        DealsCenter.shared.loadIfNeeded()
        let byDay = Dictionary(grouping: DealsCenter.shared.bySymbol[symbol.uppercased()] ?? [], by: \.day)
        var buy: [Point] = [], sell: [Point] = []
        for day in byDay.keys.sorted() where day >= from {
            let ds = byDay[day]!
            let b = ds.filter(\.isBuy).reduce(0) { $0 + $1.valueCr }, sl = ds.filter { !$0.isBuy }.reduce(0) { $0 + $1.valueCr }
            if b > 0 { buy.append(Point(time: day, value: b)) }
            if sl > 0 { sell.append(Point(time: day, value: -sl)) }
        }
        let dc = DealsCenter.shared
        // "?" = some deals downloaded but no complete history (no golden marks, pranks still shown)
        return (buy, sell, dc.coveredFrom.isEmpty ? (dc.deals.isEmpty ? "" : "?") : dc.coveredFrom)
    }

    
/// News and bulk / block deal markers for one stock (shared by every delivery / news chart).
    @MainActor static func eventMarkers(_ symbol: String, layers: Set<ChartLayer>, from: String = "") -> [Marker] {
        var out: [Marker] = []
        let sym = symbol.uppercased()
        if layers.contains(.fmark) { out += FormulaMarks.shared.markers(sym, from: from) }
        out += DayNoteStore.shared.markers(sym).filter { $0.time >= from }
        if layers.contains(.news) {
            let codes = EventCodes.all
            let minImpact = NewsImpact.minimum
            for nd in NewsTimeline.shared.days(sym) where nd.day >= from {
                guard let l = nd.label, l != "Not company news", (nd.impact ?? 0) >= minImpact else { continue }
                let code = EventCodes.code(for: nd.category, in: codes)
                out.append(Marker(time: nd.day, text: code, position: "aboveBar", color: "#2962FF", shape: "circle",
                                  info: "\(code) · \(l) · \(NewsImpact.dots(nd.impact))" + (nd.impactOn.map { " \($0)" } ?? ""),
                                  full: nd.headlines.prefix(6).map { h in
                                      "\(nd.day) · \(h.title)" + (h.source.isEmpty ? "" : " — \(h.source)")
                                  }))
            }
        }
        return out
    }
}

final class LWChartHolder: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private var ready = false
    private var pending: String?
    @Published var failed = false
    @Published var lastError: String?
    /// Lines for the day under the crosshair (news headlines / deals) — shown under the chart.
    @Published var hoverLines: [String] = []
    /// Day under the crosshair ("yyyy-MM-dd"), nil when it leaves the chart.
    @Published var crossDay: String?
    /// A deal day the user clicked on the chart (opens the DEALSIZE ranking).
    @Published var dealDay: String?
    /// A ▲ZP day the user clicked (opens the stock's z values ranked).
    @Published var zpDay: String?
    /// An F mark the user clicked (opens Quick with the other stocks the formula was true for that day).
    @Published var fmDay: String?
    /// Called when YOU pan / zoom this chart: first and last visible day ("yyyy-MM-dd").
    var onUserRange: ((String, String) -> Void)?

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ t: WKScriptMessageHandler) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        view = WKWebView(frame: .zero, configuration: cfg)
        PageCounter.track(view)
        super.init()
        ucc.add(WeakHandler(self), name: "range")
        ucc.add(WeakHandler(self), name: "hover")
        ucc.add(WeakHandler(self), name: "cross")
        ucc.add(WeakHandler(self), name: "deal")
        ucc.add(WeakHandler(self), name: "zp")
        ucc.add(WeakHandler(self), name: "fm")
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.html, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    @MainActor func show(_ data: LWChartData) {
        var data = data
        if !data.title.isEmpty, !PineCenter.shared.scripts.isEmpty {
            let o = PineCenter.shared.chartOutputs(data.title)
            data.pine = o.plots
            data.markers += o.marks
        }
        let js = "window.setData(\(data.json))"
        if ready { view.evaluateJavaScript(js) { [weak self] r, e in self?.handle(r, e) } } else { pending = js }
    }

    private func handle(_ r: Any?, _ e: Error?) {
        let s = (r as? String) ?? e?.localizedDescription ?? ""
        failed = s == "nolib"
        lastError = s.hasPrefix("err:") || e != nil ? "Chart: \(s)" : nil
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "deal" { if let d = m.body as? String, !d.isEmpty { dealDay = d }; return }
        if m.name == "zp" { if let d = m.body as? String, !d.isEmpty { zpDay = d }; return }
        if m.name == "fm" { if let d = m.body as? String, !d.isEmpty { fmDay = d }; return }
        if m.name == "cross" { let d = m.body as? String; let v = (d?.isEmpty ?? true) ? nil : d; if v != crossDay { crossDay = v }; return }
        if m.name == "hover" { let l = (m.body as? [String]) ?? []; if l != hoverLines { hoverLines = l }; return }
        guard let a = m.body as? [String], a.count == 2 else { return }
        onUserRange?(a[0], a[1])
    }

    /// Shows the days `from`…`to` (moved by the other chart; doesn't echo back).
    /// plotLeft / plotWidth: where TradingView's price pane sits in its page (px) — the delivery chart then maps
    /// the same dates to the same screen positions. offset = extra bars to shift (manual fine-tune).
    func setRange(from: String, to: String, plotLeft: Double? = nil, plotWidth: Double? = nil) {
        guard ready else { return }
        let off = UserDefaults.standard.integer(forKey: "sync.offsetBars")
        let geo = plotLeft.flatMap { l in plotWidth.map { ",\(l),\($0)" } } ?? ",null,null"
        view.evaluateJavaScript("window.setRange && window.setRange('\(from)','\(to)'\(geo),\(off))", completionHandler: nil)
    }

    /// From TVRange.getBody's "from,to[,left,width,page]" text.
    private var lastFollow: String?
    func refollow() { if let r = lastFollow { _ = follow(tvResult: r) } }

    func follow(tvResult r: String) -> Bool {
        lastFollow = r
        let p = r.split(separator: ",").compactMap { Double($0) }
        guard p.count >= 2 else { return false }
        setRange(from: TVRange.day(Int(p[0])), to: TVRange.day(Int(p[1])),
                 plotLeft: p.count >= 4 ? p[2] : nil, plotWidth: p.count >= 4 ? p[3] : nil)
        return true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let p = pending { pending = nil; webView.evaluateJavaScript(p) { [weak self] r, e in self?.handle(r, e) } }
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html,body{margin:0;height:100%;overflow:hidden;background:transparent;font:12px -apple-system,Helvetica,sans-serif}
      #c{position:absolute;inset:0}
      #legend{position:absolute;left:8px;top:6px;z-index:5;pointer-events:none;line-height:1.5}
      #legend b{font-size:13px}
      #tip{position:absolute;z-index:6;pointer-events:none;display:none;padding:3px 7px;border-radius:5px;font-size:12px;font-weight:600;
           background:rgba(41,98,255,0.92);color:#fff;white-space:nowrap;box-shadow:0 1px 4px rgba(0,0,0,0.3)}
      #fl{position:absolute;inset:0;z-index:4;pointer-events:none;overflow:hidden}
      .fp{position:absolute;transform:translateX(-50%);padding:1px 6px;border-radius:9px;font:700 10.5px -apple-system,Helvetica,sans-serif;
          white-space:nowrap;pointer-events:auto;cursor:pointer;box-shadow:0 0 0 1px rgba(0,0,0,0.45),0 1px 3px rgba(0,0,0,0.4);line-height:14px}
      .fp:hover{transform:translateX(-50%) scale(1.15);z-index:9}
      .fv{position:absolute;width:0;border-left:1px dashed;pointer-events:none;opacity:0.5}
      #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#888}
    </style>
    <script src="https://cdn.jsdelivr.net/npm/lightweight-charts@4.2.0/dist/lightweight-charts.standalone.production.js"
            onerror="var s=document.createElement('script');s.src='https://unpkg.com/lightweight-charts@4.1.3/dist/lightweight-charts.standalone.production.js';document.head.appendChild(s);"></script>
    </head><body><div id="c"></div><div id="legend"></div><div id="tip"></div><div id="fl"></div><div id="err">Chart library couldn't load (needs internet once).</div>
    <script>
    var chart=null, sband, sen, dpr, dbuy, dsell, dshade, fband, candle, hist, high, bands, prank, sma22, sma66, per, t3s, d2c, ht3, ht3Line=null, last=null, dark=null;
    function fmt(v){ if(v==null) return ''; var a=Math.abs(v);
      if(a>=1e7) return (v/1e7).toFixed(2)+' Cr'; if(a>=1e5) return (v/1e5).toFixed(2)+' L';
      if(a>=1e3) return (v/1e3).toFixed(1)+' K'; return v.toFixed(2); }
    function build(isDark){
      var L=window.LightweightCharts; if(!L) return false;
      if(chart){ chart.remove(); chart=null; }
      dark=isDark;
      var fg=isDark?'#d1d4dc':'#131722', grid=isDark?'rgba(255,255,255,0.06)':'rgba(0,0,0,0.06)';
      chart=L.createChart(document.getElementById('c'),{autoSize:true,
        layout:{background:{type:'solid',color:'rgba(0,0,0,0)'},textColor:fg},
        grid:{vertLines:{color:grid},horzLines:{color:grid}},
        rightPriceScale:{scaleMargins:{top:0.06,bottom:0.32}},
        timeScale:{rightOffset:6,borderVisible:false},
        crosshair:{mode:0}});
      bands=chart.addHistogramSeries({priceScaleId:'bands',lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'price'}});
      chart.priceScale('bands').applyOptions({scaleMargins:{top:0,bottom:0},visible:false});
      sband=chart.addHistogramSeries({priceScaleId:'bands',lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'custom',formatter:function(){return '';}}});
      dshade=chart.addHistogramSeries({priceScaleId:'dshade',lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'custom',formatter:function(){return '';}}});
      chart.priceScale('dshade').applyOptions({scaleMargins:{top:0,bottom:0},visible:false});
      candle=chart.addCandlestickSeries({upColor:'#26a69a',downColor:'#ef5350',borderVisible:false,wickUpColor:'#26a69a',wickDownColor:'#ef5350'});
      hist=chart.addHistogramSeries({priceScaleId:'deliv',lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      var crf={type:'custom',formatter:function(v){ return '₹'+Math.abs(v).toFixed(1)+' Cr'; }};
      dbuy=chart.addHistogramSeries({priceScaleId:'deals',color:'rgba(38,166,154,0.85)',lastValueVisible:false,priceLineVisible:false,priceFormat:crf});
      dsell=chart.addHistogramSeries({priceScaleId:'deals',color:'rgba(239,83,80,0.85)',lastValueVisible:false,priceLineVisible:false,priceFormat:crf});
      chart.priceScale('deals').applyOptions({scaleMargins:{top:0.02,bottom:0.84},visible:false});
      fband=chart.addHistogramSeries({priceScaleId:'fband',lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'custom',formatter:function(){return '';}}});
      chart.priceScale('fband').applyOptions({scaleMargins:{top:0,bottom:0},visible:false});
      dpr=chart.addLineSeries({priceScaleId:'prank',color:'#4DD0E1',lineWidth:1,lastValueVisible:true,priceLineVisible:false,crosshairMarkerVisible:false,title:'DEAL_PRANK'});
      prank=chart.addLineSeries({priceScaleId:'prank',color:'#90CAF9',lineWidth:1,lastValueVisible:true,priceLineVisible:false,crosshairMarkerVisible:false,
        title:'%rank',autoscaleInfoProvider:function(){ return {priceRange:{minValue:0,maxValue:100}}; }});
      per=chart.addLineSeries({priceScaleId:'per',color:'#8BC34A',lineWidth:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,
        autoscaleInfoProvider:function(){ return {priceRange:{minValue:0,maxValue:100}}; }});
      sma66=chart.addLineSeries({priceScaleId:'deliv',color:'#E91E63',lineWidth:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      sma22=chart.addLineSeries({priceScaleId:'deliv',color:'#00BCD4',lineWidth:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      t3s=chart.addLineSeries({priceScaleId:'deliv',color:'#26a69a',lineWidth:2,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      high=chart.addLineSeries({priceScaleId:'deliv',color:'#2962FF',lineWidth:2,lineType:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      d2c=chart.addLineSeries({priceScaleId:'right',color:'#FFC400',lineWidth:2,lineType:1,lastValueVisible:true,priceLineVisible:false,crosshairMarkerVisible:false,title:'DEL2C'});
      sen=chart.addLineSeries({priceScaleId:'steep',color:'#B2FF59',lineWidth:2,lastValueVisible:true,priceLineVisible:false,crosshairMarkerVisible:false,title:'energy',
        priceFormat:{type:'price',precision:1,minMove:0.1}});
      chart.priceScale('steep').applyOptions({scaleMargins:{top:0.62,bottom:0.02},visible:false});
      ht3=chart.addLineSeries({priceScaleId:'hit3',color:'#FF8A65',lineWidth:2,lastValueVisible:true,priceLineVisible:false,crosshairMarkerVisible:false,title:'HI/T3',
        priceFormat:{type:'price',precision:2,minMove:0.01}});
      // only YOUR pans / zooms move TradingView — not the chart's own data loads, fits or range buttons
      window._userAt=0;
      var mark=function(e){ if(e.type!=='mousemove' || e.buttons) window._userAt=Date.now(); };
      ['pointerdown','mousedown','wheel','touchstart','touchmove','mousemove'].forEach(function(t){ document.addEventListener(t, mark, {capture:true, passive:true}); });
      chart.timeScale().subscribeVisibleLogicalRangeChange(function(){ requestAnimationFrame(drawPills); });
      chart.timeScale().subscribeVisibleTimeRangeChange(function(r){
        if(!r || window._quiet) return;
        if(Date.now()-window._userAt > 1500) return;
        clearTimeout(window._rt);
        window._rt=setTimeout(function(){
          if(!(window.webkit && window.webkit.messageHandlers.range)) return;
          var g=window._tvGeo, lr=chart.timeScale().getVisibleLogicalRange();
          if(g && lr){
            // the range TradingView must show so its plot area lines up with this chart
            var W=chart.timeScale().width()||document.body.clientWidth, bpp=(lr.to-lr.from)/W;
            var a=lr.from-window._off+g.L*bpp, b=a+g.Wp*bpp;
            window.webkit.messageHandlers.range.postMessage([dayAt(a), dayAt(b)]);
          } else window.webkit.messageHandlers.range.postMessage([day(r.from), day(r.to)]);
        },120);
      });
      // click on a deal day → the app opens that stock's deal days ranked by DEALSIZE
      chart.subscribeClick(function(p){
        if(!p||!p.time||!window.webkit) return; var k=day(p.time), h=window.webkit.messageHandlers;
        var oid=p.hoveredObjectId?String(p.hoveredObjectId):'';
        var isDeal=(window._db&&window._db[k])||(window._dsl&&window._dsl[k]), isZP=window._zp&&window._zp[k];
        if(oid.indexOf('zp|')===0 && h.zp) { h.zp.postMessage(oid.slice(3)); return; }
        if(oid.indexOf('fm|')===0 && h.fm) { h.fm.postMessage(oid.slice(3)); return; }
        if(oid.indexOf('deal|')===0 && h.deal) { h.deal.postMessage(oid.slice(5)); return; }
        if(isDeal && h.deal) h.deal.postMessage(k);
        else if(isZP && h.zp) h.zp.postMessage(k);
      });
      chart.subscribeCrosshairMove(function(p){
        if(!last) return;
        hover(p);
        if(!p || !p.time || !p.seriesData){ legendLast(); return; }
        var g=function(s){ return p.seriesData.get(s)||null; };
        legend(g(candle),g(hist),g(high),p.time,g(prank),g(sma22),g(sma66),g(per),g(t3s),g(d2c),g(ht3));
      });
      return true;
    }
    // Crosshair over a news / deal day: short text on the chart, full lines to the app (shown under the chart)
    var lastHover='', lastCross=null;
    function hover(p){
      var tip=document.getElementById('tip');
      var key=(p&&p.time)?day(p.time):'';
      if(key!==lastCross){ lastCross=key; if(window.webkit&&window.webkit.messageHandlers.cross) window.webkit.messageHandlers.cross.postMessage(key); }
      var h=key&&window._hover?window._hover[key]:null;
      if(!h || !p.point){ tip.style.display='none'; if(lastHover!==''){ lastHover=''; post([]); } return; }
      tip.innerHTML=h.map(function(x){ return '<div style="color:'+(x.color==='#2962FF'?'#fff':'#fff')+'">'+x.info+'</div>'; }).join('');
      tip.style.background=h[0].color==='#2962FF'?'rgba(41,98,255,0.92)':(h[0].color==='#26a69a'?'rgba(38,166,154,0.92)':'rgba(239,83,80,0.92)');
      tip.style.display='block';
      var w=document.body.clientWidth, x=p.point.x+14; if(x+tip.offsetWidth>w-70) x=p.point.x-14-tip.offsetWidth;
      tip.style.left=Math.max(4,x)+'px'; tip.style.top=Math.max(40,p.point.y-36)+'px';
      if(key!==lastHover){ lastHover=key; post([].concat.apply([],h.map(function(x){ return x.full||[]; }))); }
    }
    function post(lines){ if(window.webkit&&window.webkit.messageHandlers.hover) window.webkit.messageHandlers.hover.postMessage(lines); }
    function day(t){ if(typeof t==='string') return t; if(typeof t==='number'){ var d=new Date(t*1000); return d.toISOString().slice(0,10); }
      return t.year+'-'+String(t.month).padStart(2,'0')+'-'+String(t.day).padStart(2,'0'); }
    // Shows days f…t even when they run past the data (TradingView often shows empty days on the right):
    // converts dates to bar positions (extrapolating weekdays beyond the first / last bar).
    function wd(a,b){ var d1=new Date(a+'T00:00:00Z'), d2=new Date(b+'T00:00:00Z'), n=0, s=d1<d2?1:-1;
      for(var d=new Date(d1); s>0 ? d<d2 : d>d2; d.setUTCDate(d.getUTCDate()+s)){ var w=d.getUTCDay(); if(w!==0&&w!==6) n+=s; } return n; }
    function pos(day){
      var t=window._times||[]; if(!t.length) return 0;
      if(day<=t[0]) return -wd(day,t[0]);
      if(day>=t[t.length-1]) return (t.length-1)+wd(t[t.length-1],day);
      var lo=0,hi=t.length-1; while(lo<hi){ var m=(lo+hi)>>1; if(t[m]<day) lo=m+1; else hi=m; } return lo;
    }
    // index → day (extrapolating weekdays before / after the data)
    function dayAt(idx){
      var t=window._times||[]; if(!t.length) return '';
      var i=Math.round(idx);
      function addWd(d,n){ var x=new Date(d+'T00:00:00Z'), s=n>0?1:-1, k=Math.abs(n);
        while(k>0){ x.setUTCDate(x.getUTCDate()+s); var w=x.getUTCDay(); if(w!==0&&w!==6) k--; } return x.toISOString().slice(0,10); }
      if(i<0) return addWd(t[0],i); if(i>=t.length) return addWd(t[t.length-1],i-(t.length-1)); return t[i];
    }
    window._tvGeo=null; window._off=0;
    window.setRange=function(f,t,L,Wp,off){ if(!chart) return; window._quiet=true;
      try{
        var pf=pos(f), pt=pos(t);
        window._off=off||0;
        if(L!=null && Wp>50){
          window._tvGeo={L:L,Wp:Wp};
          var bpp=(pt-pf)/Wp, W=chart.timeScale().width()||document.body.clientWidth;
          pf=pf-L*bpp; pt=pf+W*bpp;
        }
        chart.timeScale().setVisibleLogicalRange({from:pf+window._off,to:pt+window._off});
      }catch(e){}
      clearTimeout(window._qt); window._qt=setTimeout(function(){ window._quiet=false; },350); };
    function lastOf(a){ return a&&a.length?a[a.length-1]:null; }
    function legendLast(){ var d=last; legend(lastOf(d.candles),lastOf(d.deliv),lastOf(d.high),null,lastOf(d.prank),lastOf(d.sma22),lastOf(d.sma66),lastOf(d.per),lastOf(d.t3),lastOf(d.del2c),lastOf(d.hit3)); }
    function legend(c,h,x,t,pr,s22,s66,pc,t3v,d2v,hv){
      var s='<b>'+last.title+'</b> ';
      if(t) s+=(typeof t==='string'?t:(t.year+'-'+String(t.month).padStart(2,'0')+'-'+String(t.day).padStart(2,'0')))+' ';
      if(c) s+='O '+c.open.toFixed(2)+' H '+c.high.toFixed(2)+' L '+c.low.toFixed(2)+' C <b>'+c.close.toFixed(2)+'</b>';
      s+='<br>';
      var S=last.style||{}, LC=S.legendColors||{};
      function col(k,def){ return LC[k]||def; }
      function sp(k,def,txt){ return '<span style="color:'+col(k,def)+'">'+txt+'</span>'; }
      var P={};
      if(h&&h.value!=null) P.metric=sp('metric','#FF9800',last.metric+' '+fmt(h.value));
      if(x&&x.value!=null) P.highest=sp('highest','#2962FF','highest '+fmt(x.value));
      if(s22&&s22.value!=null) P.sma22=sp('sma22','#00BCD4','sma22 '+fmt(s22.value));
      if(s66&&s66.value!=null) P.sma66=sp('sma66','#E91E63','sma66 '+fmt(s66.value));
      if(pr&&pr.value!=null) P.percentrank=sp('percentrank','#90CAF9','percentrank '+pr.value.toFixed(1));
      var tk=t?(typeof t==='string'?t:(t.year+'-'+String(t.month).padStart(2,'0')+'-'+String(t.day).padStart(2,'0'))):(lastOf(last.dsmac)||{}).time;
      var dv=tk&&window._ds?window._ds[tk]:null;
      if(dv!=null) P.delsmac=sp('delsmac','#00E676','DELSMAC '+dv.toFixed(1));
      var sc=tk&&window._sc?window._sc[tk]:null;
      if(sc) P.series=sp('series',(sc==='EQ'?'#9E9E9E':'#FFB74D'),sc);
      var bb=tk&&window._db?window._db[tk]:null, ss=tk&&window._dsl?window._dsl[tk]:null;
      var hasP=last&&last.dprank&&last.dprank.length;
      var dpv=tk&&window._dp?window._dp[tk]:null;
      if(dpv==null && !t && last && last.dprank && last.dprank.length) dpv=last.dprank[last.dprank.length-1].value;
      if(dpv!=null||hasP) P.dealprank=sp('dealprank','#4DD0E1','DEAL_PRANK '+(dpv!=null?dpv.toFixed(1):'—'));
      var szk=tk||((last&&last.steepEnergy&&last.steepEnergy.length)?last.steepEnergy[last.steepEnergy.length-1].time:null);
      if(szk&&window._sz&&window._sz[szk]!=null) P.z=sp('z','#B2FF59','z '+window._sz[szk].toFixed(2)+(window._szp&&window._szp[szk]!=null?' · Z_PRANK '+window._szp[szk].toFixed(1):''));
      if(bb||ss) P.dealsize=sp('dealsize','#4DD0E1','DEALSIZE ₹'+((bb||0)+(ss||0)).toFixed(1)+' Cr <span style="opacity:.6">(click for ranking)</span>');
      if(bb||ss) P.deals='<span style="color:#9E9E9E">deals</span>'+(bb?' <span style="color:#26a69a">buy ₹'+bb.toFixed(1)+' Cr</span>':'')+(ss?' <span style="color:#ef5350">sell ₹'+ss.toFixed(1)+' Cr</span>':'')+(bb&&ss?' <span style="color:'+(bb>=ss?'#26a69a':'#ef5350')+'">net '+(bb>=ss?'+':'−')+'₹'+Math.abs(bb-ss).toFixed(1)+' Cr</span>':'');
      if(tk&&window._fb&&window._fb[tk]) P.filled='<span style="color:#9E9E9E">· delivery filled (BE/BZ = traded qty)</span>';
      if(pc&&pc.value!=null) P.deliv=sp('deliv','#8BC34A','deliv '+pc.value.toFixed(0)+'%');
      if(d2v&&d2v.value!=null) P.del2c=sp('del2c',(S.d2c||'#FFC400'),'DEL2C '+d2v.value.toFixed(2)+(c&&c.close?' · C/DL2C '+(c.close/d2v.value).toFixed(3):''));
      if(hv&&hv.value!=null) P.hit3=sp('hit3','#FF8A65','HI/T3 '+hv.value.toFixed(2));
      if(t3v&&t3v.value!=null){ var tc=t3v.color||'#26a69a'; P.t3='<span style="color:'+tc+'">'+(last.t3Name||'T3')+' '+fmt(t3v.value)+(tc==='#26a69a'?' ▲':' ▼')+'</span>'; }
      (last.pine||[]).forEach(function(p){
        if(!p.legend) return;
        var m=window._pv?window._pv[p.key]:null; if(!m) return;
        var k=tk||(p.points.length?p.points[p.points.length-1].time:null), v=k!=null?m[k]:null;
        if(v==null && !t && p.points.length){ for(var i=p.points.length-1;i>=0;i--){ if(p.points[i].value!=null){ v=p.points[i].value; break; } } }
        if(v!=null) P['pine:'+p.key]=sp('pine:'+p.key,p.color,p.title+' '+(Math.abs(v)>=1000?v.toFixed(0):(Math.abs(v)>=10?v.toFixed(2):v.toFixed(3))));
      });
      var order=(S.legendOrder&&S.legendOrder.length)?S.legendOrder.slice():[];
      ['metric','highest','sma22','sma66','percentrank','delsmac','series','dealprank','z','dealsize','deals','filled','deliv','del2c','hit3','t3'].forEach(function(k){ if(order.indexOf(k)<0) order.push(k); });
      Object.keys(P).forEach(function(k){ if(k.indexOf('pine:')===0 && order.indexOf(k)<0) order.push(k); });
      var hidden={}; (S.legendHidden||[]).forEach(function(k){ hidden[k]=1; });
      var lines=S.legendLines||1, shown=order.filter(function(k){ return P[k] && !hidden[k]; }).map(function(k){ return P[k]; });
      if(lines>1){ var per=Math.ceil(shown.length/lines), out=[]; for(var i=0;i<shown.length;i+=per) out.push(shown.slice(i,i+per).join(' &nbsp;')); s+=out.join('<br>'); }
      else s+=shown.join(' &nbsp;');
      var L=document.getElementById('legend');
      L.style.fontSize=(S.legendSize||12)+'px';
      L.style.left=''; L.style.right=''; L.style.top=''; L.style.bottom=''; L.style.textAlign='left';
      var pos=S.legendPos||'tl';
      if(pos==='tr'){ L.style.right='70px'; L.style.top='6px'; L.style.textAlign='right'; }
      else if(pos==='bl'){ L.style.left='8px'; L.style.bottom='34px'; }
      else { L.style.left='8px'; L.style.top='6px'; }
      document.getElementById('legend').innerHTML=s;
      document.getElementById('legend').style.color=dark?'#d1d4dc':'#131722';
    }
    // Formula pills: one badge per formula day in a clear lane just above the delivery pane, plus a faint guide up to the candle.
    // Badges that would overlap go to the next row (up to 3); the rest stay hidden until you zoom in.
    function drawPills(){
      var el=document.getElementById('fl'); el.innerHTML='';
      var P=window._fp||[]; if(!chart||!P.length||!last) return;
      var H=el.clientHeight, W=chart.timeScale().width()||el.clientWidth;
      var split=((last.style||{}).split||72)/100;
      var base=last.candles.length?H*split-20:H-40;
      var rows=[-1e9,-1e9,-1e9], hidden=0;
      P.forEach(function(p){
        var x=chart.timeScale().timeToCoordinate(p.time);
        if(x==null||x<0||x>W) return;
        var w=p.text.length*6.6+14, r=0;
        while(r<rows.length && x-w/2<rows[r]+3) r++;
        if(r>=rows.length){ hidden++; return; }
        rows[r]=x+w/2;
        var y=base-r*17, multi=p.color!=='#E040FB';
        var v=document.createElement('div'); v.className='fv';
        v.style.left=x+'px'; v.style.top='0px'; v.style.height=Math.max(0,y)+'px'; v.style.borderColor=p.color;
        el.appendChild(v);
        var b=document.createElement('div'); b.className='fp'; b.textContent=p.text; b.title=p.info||'';
        b.style.left=x+'px'; b.style.top=y+'px'; b.style.background=p.color; b.style.color=multi?'#1a1a1a':'#fff';
        b.onclick=function(){ if(window.webkit&&window.webkit.messageHandlers.fm) window.webkit.messageHandlers.fm.postMessage(p.time); };
        el.appendChild(b);
      });
      if(hidden){ var h=document.createElement('div'); h.className='fp'; h.textContent='+'+hidden+' (zoom in)';
        h.style.left=(W-50)+'px'; h.style.top=base+'px'; h.style.background='rgba(120,120,120,0.85)'; h.style.color='#fff'; el.appendChild(h); }
    }
    window.addEventListener('resize', function(){ requestAnimationFrame(drawPills); });
    window.setData=function(d){
      try { return window._setData(d); }
      catch(e) {
        try { d.deliv=d.deliv.filter(function(x){ return x.value!=null; }); window._setData(d); return 'ok-retry:'+e.message; }
        catch(e2) { return 'err:'+e2.message; }
      }
    };
    window._setData=function(d){
      if(!window.LightweightCharts){ document.getElementById('err').style.display='flex'; setTimeout(function(){ window.setData(d); },1500); return 'nolib'; }
      document.getElementById('err').style.display='none';
      if(!chart || dark!==d.dark) build(d.dark);
      last=d;
      var hasCandles=d.candles.length>0;
      var S=d.style||{}, split=(S.split||72)/100;
      var LCs=S.legendColors||{};
      [['highest',high],['sma22',sma22],['sma66',sma66],['percentrank',prank],['deliv',per],['hit3',ht3],['dealprank',dpr]].forEach(function(p){ if(LCs[p[0]]&&p[1]) p[1].applyOptions({color:LCs[p[0]]}); });                  // where the delivery pane starts (fraction of height)
      var low=hasCandles?{top:split,bottom:0}:{top:0.08,bottom:0};
      chart.priceScale('deliv').applyOptions({scaleMargins:low});
      chart.priceScale('prank').applyOptions({scaleMargins:low, visible:false});
      chart.priceScale('per').applyOptions({scaleMargins:low, visible:false});
      chart.applyOptions({rightPriceScale:{visible:hasCandles && S.priceScale!==false, scaleMargins:{top:0.06,bottom:Math.max(0.05,1-split+0.03)+((d.fpills||[]).length?0.08:0)}},
                          leftPriceScale:{visible:false},
                          grid:{vertLines:{visible:S.grid!==false},horzLines:{visible:S.grid!==false}}});
      candle.applyOptions({upColor:S.up||'#26a69a', downColor:S.down||'#ef5350', wickUpColor:S.up||'#26a69a', wickDownColor:S.down||'#ef5350',
                           wickVisible:S.wicks!==false, borderVisible:S.borders===true, borderUpColor:S.up||'#26a69a', borderDownColor:S.down||'#ef5350'});
      d2c.applyOptions({color:S.d2c||'#FFC400', lineWidth:S.d2cWidth||2});
      fband.setData(d.filledBand||[]);
      dbuy.setData(d.dealBuy||[]); dsell.setData(d.dealSell||[]);
      // full-height background shade on deal days: green = net buying, red = net selling
      var net={}; (d.dealBuy||[]).forEach(function(x){ net[x.time]=(net[x.time]||0)+x.value; }); (d.dealSell||[]).forEach(function(x){ net[x.time]=(net[x.time]||0)+x.value; });
      dshade.setData(Object.keys(net).sort().map(function(t){ return {time:t,value:1,color:net[t]>=0?'rgba(38,166,154,0.16)':'rgba(239,83,80,0.16)'}; }));
      function cr(v){ v=Math.abs(v); return v>=10?v.toFixed(0):v.toFixed(1); }
      // top strip: one number per deal day (net ₹ Cr) — green above the bar = net buy, red below = net sell
      var nb=[], ns=[];
      var gold={}; (d.dealGold||[]).forEach(function(t){ gold[t]=1; });
      Object.keys(net).sort().forEach(function(t){ var v=net[t], m={time:t,shape:'circle',size:0,text:cr(v)};
        if(v>=0){ m.position='aboveBar'; m.color=gold[t]?'#FFD700':'#26a69a'; nb.push(m); } else { m.position='belowBar'; m.color=gold[t]?'#FFD700':'#ef5350'; ns.push(m); } });
      dbuy.setMarkers(nb); dsell.setMarkers(ns);
      window._db={}; (d.dealBuy||[]).forEach(function(x){ window._db[x.time]=x.value; });
      window._dsl={}; (d.dealSell||[]).forEach(function(x){ window._dsl[x.time]=-x.value; });
      window._fb={}; (d.filledBand||[]).forEach(function(x){ window._fb[x.time]=1; });
      window._sc=d.seriesCodes||{};
      window._ds={}; (d.dsmac||[]).forEach(function(x){ window._ds[x.time]=x.value; });
      candle.setData(d.candles); hist.setData(d.deliv); high.setData(d.high); bands.setData(d.bands); prank.setData(d.prank||[]);
      dpr.setData(d.dealsOn?(d.dprank||[]):[]);
      window._dp={}; (d.dprank||[]).forEach(function(x){ window._dp[x.time]=x.value; });
      sma22.setData(d.sma22||[]); sma66.setData(d.sma66||[]); per.setData(d.per||[]);
      t3s.applyOptions({priceScaleId:d.t3Own?'t3':'deliv'});
      if(d.t3Own) chart.priceScale('t3').applyOptions({scaleMargins:low, visible:false});
      t3s.setData(d.t3||[]);
      d2c.applyOptions({priceScaleId:d.d2cOwn?'d2c':'right'});
      if(d.d2cOwn) chart.priceScale('d2c').applyOptions({scaleMargins:{top:0.08,bottom:0.08}, visible:false});
      d2c.setData(d.del2c||[]);
      chart.priceScale('hit3').applyOptions({scaleMargins:low, visible:false});
      ht3.setData(d.hit3||[]);
      sband.setData([]); sen.setData([]);          // steepness: numbers in the legend only, nothing drawn
      window._zp={}; (d.zpDays||[]).forEach(function(t){ window._zp[t]=1; });
      window._sz=d.steepZ||{}; window._szp=d.steepZPR||{}; window._sr=d.steepRun||{}; window._se={}; (d.steepEnergy||[]).forEach(function(x){ window._se[x.time]=x.value; });
      if(ht3Line){ ht3.removePriceLine(ht3Line); ht3Line=null; }
      if((d.hit3||[]).length) ht3Line=ht3.createPriceLine({price:1,color:'rgba(255,138,101,0.6)',lineWidth:1,lineStyle:2,axisLabelVisible:false,title:'1.00'});
      var ts={}; d.candles.forEach(function(x){ ts[x.time]=1; }); d.deliv.forEach(function(x){ ts[x.time]=1; });
      window._times=Object.keys(ts).sort();
      var hasBars=d.deliv.some(function(x){ return x.value!=null; });
      var mk=hasCandles?candle:(hasBars?hist:(d.high.length?high:hist));
      [candle,hist,high].forEach(function(s){ if(s!==mk) s.setMarkers([]); });
      // markers must sit on a bar of their series: move weekend / holiday news to the next trading day
      var st=(mk===candle?d.candles:(mk===hist?d.deliv:d.high)).filter(function(x){ return x.close!=null || x.value!=null; }).map(function(x){ return x.time; });
      var snapped=d.markers.map(function(m){
        if(!st.length) return m;
        var lo=0,hi=st.length-1; if(m.time>st[hi]) return null;
        while(lo<hi){ var md=(lo+hi)>>1; if(st[md]<m.time) lo=md+1; else hi=md; }
        var c=Object.assign({},m); c.time=st[lo]; return c;
      }).filter(function(m){ return m; });
      snapped.sort(function(a,b){ return a.time<b.time?-1:(a.time>b.time?1:0); });
      window._hover={};
      snapped.forEach(function(m){ if(m.info){ (window._hover[m.time]=window._hover[m.time]||[]).push({info:m.info,full:m.full,color:m.color}); } });
      mk.setMarkers(snapped.map(function(m){ var o={time:m.time,position:m.position,color:m.color,shape:m.shape,text:m.text}; if(m.id) o.id=m.id+'|'+m.time; return o; }));
      var n={'6M':126,'1Y':252,'2Y':504}[d.range];
      var len=Math.max(d.candles.length,d.deliv.length);
      window._quiet=true;
      if(n && len>n) chart.timeScale().setVisibleLogicalRange({from:len-n,to:len+4}); else chart.timeScale().fitContent();
      clearTimeout(window._qt); window._qt=setTimeout(function(){ window._quiet=false; },350);
      // your Pine plots: a series per drawn plot; every plot's values kept for the legend
      (window._pineS||[]).forEach(function(x){ try{ chart.removeSeries(x); }catch(e){} }); window._pineS=[]; window._pv={};
      (d.pine||[]).forEach(function(p){
        var m={}; p.points.forEach(function(x){ if(x.value!=null) m[x.time]=x.value; }); window._pv[p.key]=m;
        if(p.pane==='none') return;
        if(p.style==='barcolor'){          // colour the candles
          var cm={}; p.points.forEach(function(x){ cm[x.time]=x.color; });
          candle.setData((d.candles||[]).map(function(c){ var k=cm[c.time]; return k?Object.assign({},c,{color:k,wickColor:k,borderColor:k}):c; }));
          return;
        }
        if(p.style==='bg'){                // shade the whole height behind those days
          var bs=chart.addHistogramSeries({priceScaleId:'pinebg_'+p.key,lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'custom',formatter:function(){return '';}}});
          chart.priceScale('pinebg_'+p.key).applyOptions({scaleMargins:{top:0,bottom:0},visible:false});
          bs.setData(p.points.map(function(x){ return {time:x.time,value:1,color:x.color}; }));
          window._pineS.push(bs);
          return;
        }
        var sid=p.pane==='price'?'right':(p.pane==='deliv'?'deliv':'pine_'+p.key);
        var opt={priceScaleId:sid,color:p.color,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false};
        var se=p.style==='hist'?chart.addHistogramSeries(opt):chart.addLineSeries(Object.assign(opt,{lineWidth:Math.max(1,Math.min(4,p.width||1)),lineType:p.style==='step'?1:0}));
        if(p.pane==='own') chart.priceScale(sid).applyOptions({scaleMargins:low, visible:false});
        se.setData(p.points.filter(function(x){ return x.value!=null; }).map(function(x){ var o={time:x.time,value:x.value}; if(x.color) o.color=x.color; return o; }));
        window._pineS.push(se);
      });
      window._fp=d.fpills||[]; setTimeout(drawPills,30);
      legendLast();
      return 'ok';
    };
    </script></body></html>
    """
}

struct LWChartView: NSViewRepresentable {
    @ObservedObject var holder: LWChartHolder
    func makeNSView(context: Context) -> NSView { let v = NSView(); embed(v); return v }
    func updateNSView(_ v: NSView, context: Context) { if holder.view.superview !== v { embed(v) } }
    private func embed(_ v: NSView) {
        let w = holder.view
        w.removeFromSuperview()
        w.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(w)
        NSLayoutConstraint.activate([w.leadingAnchor.constraint(equalTo: v.leadingAnchor), w.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     w.topAnchor.constraint(equalTo: v.topAnchor), w.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
    }
}

// MARK: - Pine Script that draws the same delivery signals on your TradingView charts

enum DeliveryPine {
    /// Builds a Pine v5 indicator holding "SYMBOL@yyyy-MM-dd;" keys for every signal day, split into
    /// short strings; on each bar it checks the chart's own symbol + date and paints the bar.
    static func script(signals: [(symbol: String, days: [String])], metric: String, length: Int) -> String {
        var keys = ""
        for s in signals.sorted(by: { $0.symbol < $1.symbol }) { for d in s.days { keys += "\(s.symbol)@\(d);" } }
        var chunks: [String] = []
        var cur = ""
        for k in keys.split(separator: ";") {
            if cur.count + k.count + 1 > 3000 { chunks.append(cur); cur = "" }
            cur += k + ";"
        }
        if !cur.isEmpty { chunks.append(cur) }
        let stamp = HistoryStore.dayKey(Date())
        var out = """
        //@version=5
        // Generated by Stock Screener on \(stamp): days where ta.highest(\(metric), \(length)) updated (NSE delivery data).
        // Re-copy from the app after new days to include new signals.
        indicator("Delivery highs (\(metric), \(length))", overlay = true, max_labels_count = 500)
        key = syminfo.ticker + "@" + str.format_time(time, "yyyy-MM-dd", "Asia/Kolkata") + ";"
        hit = false

        """
        for (i, c) in chunks.enumerated() {
            out += "s\(i) = \"\(c)\"\nhit := hit or str.contains(s\(i), key)\n"
        }
        out += """

        bgcolor(hit ? color.new(color.orange, 78) : na, title = "Delivery high day")
        plotshape(hit, title = "Delivery high", style = shape.triangleup, location = location.belowbar, color = color.orange, size = size.small, text = "DQ", textcolor = color.orange)

        """
        return out
    }
}


// MARK: - Keeping the TradingView page and the delivery chart on the same dates

/// Reads / sets the visible date range of the TradingView chart page through the chart API that tradingview.com
/// exposes in the page (window.TradingViewApi). Not an official, documented interface — it may be missing.
enum TVRange {
    /// Finds the chart controller in the TradingView page (several known places) — body for callAsyncJavaScript.
    static let finder = """
    function __ssChart() {
      var a = window.TradingViewApi || window.tradingViewApi;
      var tries = [];
      if (a) {
        tries.push(function(){ return a.activeChart && a.activeChart(); });
        tries.push(function(){ return a.chart && a.chart(0); });
        tries.push(function(){ return a._activeChartWidgetWV && a._activeChartWidgetWV.value(); });
      }
      for (var i = 0; i < tries.length; i++) {
        try { var c = tries[i](); if (c && typeof c.getVisibleRange === 'function') return c; } catch (e) {}
      }
      return null;
    }
    """

    /// "NSE:TCS" from a chart link's ?symbol=…
    static func symbol(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "symbol" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Switches the open chart to another symbol through TradingView's chart API ("ok"), or "noapi".
    static func setSymbolBody(_ sym: String) -> String {
        let lit = (try? String(data: JSONSerialization.data(withJSONObject: [sym]), encoding: .utf8)).flatMap { $0 }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return finder + """
        var c = __ssChart();
        if (!c || typeof c.setSymbol !== 'function') return 'noapi';
        var want = \(lit);
        await new Promise(function(res){
          var done = false, f = function(){ if (!done) { done = true; res(); } };
          try { c.setSymbol(want, f); } catch (e) { f(); }
          setTimeout(f, 5000);
        });
        try { var now = c.symbol && c.symbol(); if (now && String(now).toUpperCase().indexOf(want.split(':').pop().toUpperCase()) < 0) return 'nochange'; } catch (e) {}
        return 'ok';
        """
    }

    /// What the page is showing now: TradingView's symbol() and the window title, for checking a switch really happened.
    static let shownBody = finder + """
    var c = __ssChart(), s = '';
    try { s = (c && c.symbol) ? String(c.symbol()) : ''; } catch (e) {}
    var leg = '';
    try { var el = document.querySelector('[data-name="legend-source-title"]'); leg = el ? el.textContent : ''; } catch (e) {}
    return s + '|' + document.title + '|' + leg;
    """

    /// Returns "from,to" (unix seconds) or a short reason it couldn't.
    static let getBody = finder + """
    var c = __ssChart();
    if (!c) {
      var keys = Object.keys(window).filter(function(k){ return /tradingview|tvapi|chartapi/i.test(k); }).slice(0, 8).join('|');
      return 'noapi:' + (typeof window.TradingViewApi) + (keys ? ':' + keys : '');
    }
    var r = c.getVisibleRange();
    if (r && typeof r.then === 'function') r = await r;
    if (!r || r.from == null) return 'norange';
    // + the main price pane's position on screen (the largest canvas), so the delivery chart can line its
    //   dates up with TradingView's plot area, not just its date range
    var g = '';
    try {
      var best = null, cs = document.querySelectorAll('canvas');
      for (var i = 0; i < cs.length; i++) {
        var b = cs[i].getBoundingClientRect();
        if (b.width > 200 && b.height > 80 && (!best || b.width * b.height > best.width * best.height)) best = b;
      }
      if (best) g = ',' + Math.round(best.left) + ',' + Math.round(best.width) + ',' + Math.round(window.innerWidth);
    } catch (e) {}
    return Math.round(r.from) + ',' + Math.round(r.to) + g;
    """

    /// Subscribes once to the TradingView chart's crosshair and returns its time (unix s, "0" = none),
    /// or "noapi" when the page doesn't offer it.
    static let crossBody = finder + """
    if (!window.__ssCrossOn) {
      var c = __ssChart();
      if (!c || typeof c.crossHairMoved !== 'function') return 'noapi';
      try {
        c.crossHairMoved().subscribe(null, function(p) { window.__ssCross = (p && p.time) ? p.time : 0; });
        window.__ssCrossOn = true;
      } catch (e) { return 'noapi'; }
    }
    return String(window.__ssCross || 0);
    """

    static func setBody(from: Int, to: Int) -> String {
        finder + """
        var c = __ssChart();
        if (!c || typeof c.setVisibleRange !== 'function') return 'noapi';
        var p = c.setVisibleRange({from: \(from), to: \(to)});
        if (p && typeof p.then === 'function') await p;
        return 'ok';
        """
    }

    /// Centres the chart on `day` (unix s, noon) keeping the current zoom: "ok", "clamped:<centre>" when TradingView
    /// wouldn't scroll that far (e.g. into the empty space right of the last bar), or "noapi".
    static func centreBody(_ t: Int) -> String {
        finder + """
        var c = __ssChart();
        if (!c || typeof c.getVisibleRange !== 'function' || typeof c.setVisibleRange !== 'function') return 'noapi';
        var r = c.getVisibleRange();
        if (r && typeof r.then === 'function') r = await r;
        if (!r || r.from == null) return 'norange';
        var w = Math.max(86400 * 20, r.to - r.from);
        var p = c.setVisibleRange({from: \(t) - w / 2, to: \(t) + w / 2});
        if (p && typeof p.then === 'function') await p;
        await new Promise(function(res){ setTimeout(res, 250); });
        var n = c.getVisibleRange();
        if (n && typeof n.then === 'function') n = await n;
        if (!n || n.from == null) return 'ok';
        var mid = (n.from + n.to) / 2;
        return Math.abs(mid - \(t)) <= w * 0.15 ? 'ok' : 'clamped:' + Math.round(mid);
        """
    }

    /// Runs one of the bodies above in the page and hands back its text result (or the error).
    static func run(_ web: WKWebView, _ body: String, done: @escaping (String) -> Void) {
        web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { r in
            switch r {
            case .success(let v): done((v as? String) ?? "\(v)")
            case .failure(let e): done("jserror: " + e.localizedDescription)
            }
        }
    }

    private static let f: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func day(_ unix: Int) -> String { f.string(from: Date(timeIntervalSince1970: TimeInterval(unix))) }
    static func unix(_ day: String) -> Int? { f.date(from: day).map { Int($0.timeIntervalSince1970) } }
}


/// Candle shading on the delivery charts: days whose DELSMAC (the Filter's, with the Delivery Analysis signal)
/// is above the level (0–100 percentrank; default 90, Settings key "delsmac.shade2" — the old 0–1 key isn't used).
enum DelsmacShade {
    static var level: Double {
        let v = UserDefaults.standard.double(forKey: "delsmac.shade2")
        return v > 0 ? v : 90
    }
    static func days(_ s: DeliverySeries, level: Double = DelsmacShade.level) -> Set<String> {
        let k = DeliveryMetric(rawValue: UserDefaults.standard.string(forKey: "deliv.metric") ?? "") ?? .value
        var out = Set<String>()
        let v = DeliveryColumns.delSmaCSeries(s, metric: k)
        for i in s.days.indices where i < v.count { if let x = v[i], x > level { out.insert(s.days[i]) } }
        return out
    }
}


/// How the delivery charts and Chart 3 look (the brush button on each chart). Saved for the whole app.
struct ChartStyle: Codable, Equatable {
    var up = "#26a69a"
    var down = "#ef5350"
    var shadeUp = "#B388FF"
    var shadeDown = "#7C4DFF"
    var d2c = "#FFC400"
    var d2cWidth = 2
    var split = 72              // % of the height for price; delivery bars below
    var grid = true
    var wicks = true
    var borders = false
    var priceScale = true
    // legend: order, hidden items, colours (also the line colours), position, size, lines
    var legendOrder: [String]? = nil
    var legendHidden: [String]? = nil
    var legendColors: [String: String]? = nil
    var legendPos: String? = nil          // "tl" top-left, "tr" top-right, "bl" bottom-left
    var legendSize: Int? = nil
    var legendLines: Int? = nil

    /// Legend items: key, name, default colour.
    static let legendItems: [(key: String, name: String, color: String)] = [
        ("metric", "Delivery (smooth QTY)", "#FF9800"), ("highest", "highest", "#2962FF"), ("sma22", "sma22", "#00BCD4"),
        ("sma66", "sma66", "#E91E63"), ("percentrank", "percentrank", "#90CAF9"), ("delsmac", "DELSMAC", "#00E676"),
        ("series", "NSE series (EQ / BE …)", "#9E9E9E"), ("dealprank", "DEAL_PRANK", "#4DD0E1"), ("z", "z · Z_PRANK", "#B2FF59"),
        ("dealsize", "DEALSIZE", "#4DD0E1"), ("deals", "deals buy / sell / net", "#9E9E9E"), ("filled", "delivery filled note", "#9E9E9E"),
        ("deliv", "deliv %", "#8BC34A"), ("del2c", "DEL2C · C/DL2C", "#FFC400"), ("hit3", "HI/T3", "#FF8A65"), ("t3", "T3", "#26a69a"),
    ]
    var orderedLegend: [String] {
        var o = legendOrder ?? []
        for i in Self.legendItems where !o.contains(i.key) { o.append(i.key) }
        return o.filter { k in Self.legendItems.contains { $0.key == k } }
    }

    static let key = "chart.style"
    static var current: ChartStyle {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(ChartStyle.self, from: $0) } ?? ChartStyle()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// Price candles for the delivery charts: real Yahoo OHLC, fetched once per stock and kept for the last few stocks.
@MainActor final class CandleCache: ObservableObject {
    static let shared = CandleCache()
    @Published private(set) var revision = 0
    private var store: [String: [YahooClient.Candle]] = [:]
    private var order: [String] = []
    private var loading = Set<String>()

    /// Already-fetched candles only (no download).
    func peek(_ sym: String) -> [YahooClient.Candle]? { store[sym] }

    func candles(_ sym: String) -> [YahooClient.Candle]? {
        if let c = store[sym] { return c }
        guard !loading.contains(sym) else { return nil }
        loading.insert(sym)
        Task {
            // 5 years from Yahoo, kept to the last 1,000 trading days — covers the 900 NSE delivery days in memory
            if let c = try? await YahooClient.candles(sym, range: "5y"), !c.isEmpty {
                store[sym] = Array(c.suffix(1_000)); order.append(sym)
                while order.count > 24 { store[order.removeFirst()] = nil }     // a couple of reels' worth
                revision += 1
            }
            loading.remove(sym)
        }
        return nil
    }
}

import SwiftUI

/// The brush button: colours, DEL2C line, price / delivery split, grid, wicks.
struct ChartStyleButton: View {
    @State private var open = false
    @State private var st = ChartStyle.current
    @AppStorage("chart.styleRev") private var rev = 0

    var body: some View {
        Button { st = ChartStyle.current; open = true } label: { Image(systemName: "paintbrush") }
            .help("Chart settings — colours, lines, layout")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chart settings").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow { Text("Candles up / down"); HStack { colour($st.up); colour($st.down) } }
                        GridRow { Text("Shaded (DELSMAC) up / down"); HStack { colour($st.shadeUp); colour($st.shadeDown) } }
                        GridRow { Text("DEL2C line"); HStack { colour($st.d2c); Stepper("width \(st.d2cWidth)", value: $st.d2cWidth, in: 1...5).fixedSize() } }
                        GridRow {
                            Text("Price area")
                            HStack { Slider(value: Binding(get: { Double(st.split) }, set: { st.split = Int($0) }), in: 40...90, step: 2).frame(width: 160); Text("\(st.split)%").monospacedDigit() }
                        }
                    }
                    Toggle("Grid lines", isOn: $st.grid)
                    Toggle("Candle wicks", isOn: $st.wicks)
                    Toggle("Candle borders", isOn: $st.borders)
                    Toggle("Price scale on the right", isOn: $st.priceScale)
                    Divider()
                    legendSection
                    HStack {
                        Button("Reset") { st = ChartStyle() }
                        Spacer()
                        Text("Applies to every delivery chart and Chart 3").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(14).frame(width: 440)
                .onChange(of: st) { v in v.save(); rev &+= 1 }
            }
    }

    // MARK: Legend — order (drag or ↑ ↓), show / hide, colour, position, size

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Legend").font(.subheadline.bold())
                Spacer()
                Picker("", selection: Binding(get: { st.legendPos ?? "tl" }, set: { st.legendPos = $0 })) {
                    Text("Top left").tag("tl"); Text("Top right").tag("tr"); Text("Bottom left").tag("bl")
                }.labelsHidden().fixedSize().controlSize(.small)
                Stepper("\(st.legendSize ?? 12) pt", value: Binding(get: { st.legendSize ?? 12 }, set: { st.legendSize = $0 }), in: 9...18).fixedSize().controlSize(.small)
                Stepper("\(st.legendLines ?? 1) line\((st.legendLines ?? 1) == 1 ? "" : "s")", value: Binding(get: { st.legendLines ?? 1 }, set: { st.legendLines = $0 }), in: 1...4)
                    .fixedSize().controlSize(.small).help("Spread the values over more lines")
            }
            List {
                ForEach(st.orderedLegend, id: \.self) { k in
                    let item = ChartStyle.legendItems.first { $0.key == k }!
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Toggle("", isOn: Binding(get: { !(st.legendHidden ?? []).contains(k) }, set: { on in
                            var h = st.legendHidden ?? []; if on { h.removeAll { $0 == k } } else { h.append(k) }; st.legendHidden = h
                        })).labelsHidden()
                        Text(item.name).lineLimit(1)
                        Spacer()
                        if k != "deals" && k != "filled" && k != "t3" && k != "series" {
                            ColorPicker("", selection: Binding(get: { Color(hexString: st.legendColors?[k] ?? (k == "del2c" ? st.d2c : item.color)) }, set: { c in
                                var m = st.legendColors ?? [:]; m[k] = c.hexString; st.legendColors = m
                            }), supportsOpacity: false).labelsHidden()
                        }
                        Button { move(k, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { move(k, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
                .onMove { from, to in var o = st.orderedLegend; o.move(fromOffsets: from, toOffset: to); st.legendOrder = o }
            }
            .frame(height: 260)
            Text("Drag rows (or ↑ ↓) to order the legend; untick to hide; the colour also recolours that line on the chart.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func move(_ k: String, _ by: Int) {
        var o = st.orderedLegend
        guard let i = o.firstIndex(of: k), o.indices.contains(i + by) else { return }
        o.swapAt(i, i + by); st.legendOrder = o
    }

    private func colour(_ hex: Binding<String>) -> some View {
        ColorPicker("", selection: Binding(get: { Color(hexString: hex.wrappedValue) }, set: { hex.wrappedValue = $0.hexString }), supportsOpacity: false)
            .labelsHidden()
    }
}

extension Color {
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// ▲ZP level: Z_PRANK above this (0–100); at 100 = Z_PRANK is 100 (z higher than all of the previous 300 days).
enum ZPLevel {
    static var level: Double { UserDefaults.standard.object(forKey: "zp.level") as? Double ?? 99 }
    static func hit(_ v: Double) -> Bool { level >= 100 ? v >= 100 : v > level }
    static var text: String { level >= 100 ? "= 100" : "> " + (level == level.rounded() ? String(format: "%.0f", level) : String(format: "%.1f", level)) }
}

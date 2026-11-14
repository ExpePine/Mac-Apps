import SwiftUI
import AppKit

// MARK: - Event Scan
//
// "How many trading days since <condition>?" for every stock — e.g. HI/T3 crossing below 1.10 and below 0.90 —
// computed on the full NSE delivery history (DELIV_QTY, close, Deliv %) like Pine's ta.barssince. Sort, filter,
// then open the Chart Reel with every chart centred on the event's date.

enum ScanMetric: String, CaseIterable, Codable, Identifiable {
    case hiT3 = "HI/T3", delSma = "DELSMA", dqPrank = "DQ_PRANK", t3 = "T3", t3Color = "t3Color",
         close = "Close", value = "DQ×close", sma22 = "SMA22", sma66 = "SMA66", per = "Deliv %"
    var id: String { rawValue }
    var help: String {
        switch self {
        case .hiT3: return "ta.highest(ta.sma(DQ*close, 22|66), 300) / T3"
        case .delSma: return "ta.percentrank(ta.sma(DQ*close, 22|66 as the Delivery signal), 300)"
        case .dqPrank: return "ta.percentrank(DELIV_QTY, 300)"
        case .t3: return "T3 of delivery (your T3 settings)"
        case .t3Color: return "1 = T3 rising, 0 = not"
        case .close: return "NSE close price"
        case .value: return "DELIV_QTY × close (₹)"
        case .sma22: return "ta.sma(DQ*close, 22)"
        case .sma66: return "ta.sma(DQ*close, 66)"
        case .per: return "Delivery % of traded quantity"
        }
    }
}

enum ScanEvent: String, CaseIterable, Codable, Identifiable {
    case crossBelow = "crosses below", crossAbove = "crosses above", lastBelow = "last day below", lastAbove = "last day above",
         becomes = "becomes", lastEqual = "last day equal to"
    var id: String { rawValue }
}

struct ScanCond: Codable, Identifiable, Equatable {
    var id = UUID()
    var metric: ScanMetric = .hiT3
    var event: ScanEvent = .crossBelow
    var value: Double = 1.10
    /// A custom series (expression) instead of a built-in metric, and its name.
    var expr: String? = nil
    var name: String? = nil
    var label: String { expr == nil ? metric.rawValue : (name?.isEmpty == false ? name! : expr!) }
    var title: String { "\(label) \(event.rawValue) \(CombiEngine.fmt(value))" }
    /// Same series → same key (shared "now" column and cache).
    var seriesKey: String { expr.map { "x:" + $0.lowercased().replacingOccurrences(of: " ", with: "") } ?? metric.rawValue }

    /// Parses quick text like "HI/T3 < 1.10", "DELSMA > 99", "close crosses above 500",
    /// a saved custom's name ("Close/SMA50 > 1.1") or any expression ("close / sma(close, 50) crosses above 1.1").
    static func parse(_ text: String, columns: [String] = []) -> ScanCond? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let low = t.lowercased()
        let words: [(String, ScanEvent)] = [("crosses below", .crossBelow), ("crosses above", .crossAbove), ("last below", .lastBelow), ("last above", .lastAbove),
                                            ("last day below", .lastBelow), ("last day above", .lastAbove),
                                            ("last day equal to", .lastEqual), ("last day equal", .lastEqual), ("last equal", .lastEqual), ("becomes", .becomes)]
        let symbols: [(String, ScanEvent)] = [("<=", .crossBelow), (">=", .crossAbove), ("==", .becomes), ("=", .becomes), ("<", .crossBelow), (">", .crossAbove)]
        let bare: [(String, ScanEvent)] = [(" below ", .crossBelow), (" above ", .crossAbove), (" is ", .becomes)]
        // the LAST event keyword splits series | number (expressions may contain other symbols)
        // word events first ("crosses above" beats its own " above "), then symbols, then bare above / below
        var best: (Range<String.Index>, ScanEvent)?
        for group in [words, symbols, bare] {
            // rightmost end wins; on a tie the longer one (">=" over "=", "==" over "=")
            for (k, e) in group { if let r = low.range(of: k, options: .backwards), best == nil || r.upperBound > best!.0.upperBound || (r.upperBound == best!.0.upperBound && r.lowerBound < best!.0.lowerBound) { best = (r, e) } }
            if best != nil { break }
        }
        guard let (r, ev) = best else { return nil }
        let left = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let v = Double(right), !left.isEmpty else { return nil }
        if let m = ScanMetric.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(left) == .orderedSame }) {
            return ScanCond(metric: m, event: ev, value: v)
        }
        if let c = ScanCustomStore.all.first(where: { $0.name.caseInsensitiveCompare(left) == .orderedSame }) {
            return ScanCond(event: ev, value: v, expr: c.expr, name: c.name)
        }
        guard (try? ScanExpr.parse(left, columns: columns)) != nil else { return nil }
        return ScanCond(event: ev, value: v, expr: left, name: nil)
    }
}

struct ScanHit { let bars: Int; let day: String; let atEvent: Double }
struct ScanRow: Identifiable {
    var id: String { symbol }
    let symbol: String
    let hits: [UUID: ScanHit]
    let now: [String: Double]          // series key → value on the latest day
}

enum ScanEngine {
    /// The metric for every bar of a stock's NSE history (nil = Pine na).
    static func series(_ m: ScanMetric, _ s: DeliverySeries) -> [Double?] {
        let v = s.metric(value: true)
        let n = v.count
        func sma(_ k: Int) -> [Double?] { let a = DeliverySignal.sma(v, k); return a.indices.map { $0 >= k - 1 ? a[$0] : nil } }
        func prank(_ x: [Double?]) -> [Double?] {
            guard let first = x.firstIndex(where: { $0 != nil }) else { return x.map { _ in nil } }
            let valid = x[first...].map { $0 ?? 0 }
            var out = [Double?](repeating: nil, count: n)
            for k in valid.indices where k >= 300 { out[first + k] = DeliveryColumns.percentRank(valid, length: 300, at: k) }
            return out
        }
        switch m {
        case .close: return s.close.map { Optional($0) }
        case .value: return v.map { Optional($0) }
        case .per: return s.per.map { Optional($0) }
        case .sma22: return sma(22)
        case .sma66: return sma(66)
        case .delSma:
            let k = DeliveryColumns.hiSma
            let a = DeliverySignal.avg(v, k, ema: DeliveryMetric.signalIsEMA)
            return prank(a.indices.map { $0 >= k - 1 ? a[$0] : nil })
        case .dqPrank: return prank(s.qty.map { Optional($0) })
        case .t3: return T3Def.current.t3(T3Def.current.source(s))
        case .t3Color:
            let t = T3Def.current.t3(T3Def.current.source(s))
            return t.indices.map { i in i > 0 && t[i] != nil && t[i - 1] != nil ? (t[i]! > t[i - 1]! ? 1 : 0) : nil }
        case .hiT3:
            let k = DeliveryColumns.hiSma
            guard n >= k - 1 + 300 else { return Array(repeating: nil, count: n) }
            let sm = DeliverySignal.avg(v, k, ema: DeliveryMetric.signalIsEMA)
            let hi = DeliverySignal.highest(Array(sm[(k - 1)...]), length: 300, full: true)
            let t3 = T3Def.current.t3(T3Def.current.source(s))
            var out = [Double?](repeating: nil, count: n)
            for i in (k - 1)..<n { if let h = hi[i - (k - 1)], let t = t3[i], t > 0 { out[i] = h / t } }
            return out
        }
    }

    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(1e-9, abs(b) * 1e-9) }

    /// Bars since the event, counted on the stock's NSE rows up to index `last`.
    static func barsSince(_ x: [Double?], _ c: ScanCond, last: Int) -> (Int, Int)? {
        guard last >= 1, last < x.count else { return nil }
        var i = last
        while i >= 1 {
            if let a = x[i] {
                let p = x[i - 1]
                let hit: Bool
                switch c.event {
                case .crossBelow: hit = a < c.value && (p.map { $0 >= c.value } ?? false)
                case .crossAbove: hit = a > c.value && (p.map { $0 <= c.value } ?? false)
                case .lastBelow: hit = a < c.value
                case .lastAbove: hit = a > c.value
                case .becomes: hit = Self.same(a, c.value) && (p.map { !Self.same($0, c.value) } ?? false)
                case .lastEqual: hit = Self.same(a, c.value)
                }
                if hit { return (last - i, i) }
            }
            i -= 1
        }
        return nil
    }

    static func run(_ book: DeliveryBook, symbols: [String]?, conds: [ScanCond], asOf: String,
                    columns: [String] = [], sheet: (current: SheetTable, label: Int, liveDay: String)? = nil) -> [ScanRow] {
        var exprs: [String: ScanExpr] = [:]
        for c in conds { if let e = c.expr, exprs[c.seriesKey] == nil { exprs[c.seriesKey] = try? ScanExpr.parse(e, columns: columns) } }
        let used = exprs.values.reduce(into: Set<String>()) { $0.formUnion($1.columnsUsed) }
        let hist = sheet.map { SheetHistory.load(columns: used, current: $0.current, label: $0.label, liveDay: $0.liveDay) } ?? [:]
        let keys = Set(conds.map(\.seriesKey))
        return (symbols ?? Array(book.series.keys)).compactMap { sym -> ScanRow? in
            guard let s = book.series[sym], let last = s.days.lastIndex(where: { $0 <= asOf }) else { return nil }
            var cache: [String: [Double?]] = [:], vars: [String: [Double?]] = [:]
            for c in used { vars["col:" + c.lowercased()] = SheetHistory.series(hist, column: c, symbol: sym, days: s.days) }
            for c in conds where cache[c.seriesKey] == nil {
                if c.expr != nil { cache[c.seriesKey] = exprs[c.seriesKey]?.eval(s, cache: &vars) ?? [] }
                else { cache[c.seriesKey] = series(c.metric, s) }
            }
            var hits: [UUID: ScanHit] = [:], now: [String: Double] = [:]
            for c in conds {
                guard let x = cache[c.seriesKey], last < x.count else { continue }
                if let h = barsSince(x, c, last: last) { hits[c.id] = ScanHit(bars: h.0, day: s.days[h.1], atEvent: x[h.1] ?? 0) }
            }
            for k in keys { if let x = cache[k], last < x.count, let v = x[last] { now[k] = v } }
            return ScanRow(symbol: sym, hits: hits, now: now)
        }
    }
}

@MainActor final class ScanCenter: ObservableObject {
    static let shared = ScanCenter()
    @Published var rows: [ScanRow] = []
    @Published var running = false
    @Published var ranAt: Date?
    /// What the Chart Reel shows for source "Event scan": symbol, note, date to centre on.
    @Published var reel: [(symbol: String, note: String, day: String)] = []
}

struct EventScanView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var sc = ScanCenter.shared
    @ObservedObject private var dc = DeliveryCenter.shared
    @AppStorage("scan.conds") private var condsData = Data()
    @AppStorage("scan.scope") private var scope = "Sheet stocks"
    @AppStorage("scan.sortBy") private var sortBy = ""           // condition id, or "symbol"
    @AppStorage("scan.asc") private var ascending = true
    @AppStorage("scan.onlyHits") private var onlyHits = true
    @AppStorage("scan.within") private var within = 0             // 0 = any time
    @State private var quick = ""
    @State private var conds: [ScanCond] = []
    @State private var centreOn: UUID?
    @State private var customs: [ScanCustom] = ScanCustomStore.all
    @State private var showCustom = false
    @State private var editingCond: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            condEditor
            Divider()
            resultsView
        }
        .navigationTitle("Event Scan")
        .onAppear {
            dc.loadIfNeeded()
            conds = (try? JSONDecoder().decode([ScanCond].self, from: condsData)) ?? []
            if conds.isEmpty { conds = [ScanCond(metric: .hiT3, event: .crossBelow, value: 1.10), ScanCond(metric: .hiT3, event: .crossBelow, value: 0.90)] }
            centreOn = centreOn ?? conds.first?.id
        }
        .onChange(of: conds) { c in condsData = (try? JSONEncoder().encode(c)) ?? Data() }
        .sheet(isPresented: $showCustom) {
            CustomSeriesEditor(start: editingCond.flatMap { id in conds.first { $0.id == id } }, columns: vm.headers) { custom in
                customs = ScanCustomStore.all
                guard let custom else { return }
                if let id = editingCond, let i = conds.firstIndex(where: { $0.id == id }) {
                    conds[i].expr = custom.expr; conds[i].name = custom.name
                } else {
                    conds.append(ScanCond(event: .crossAbove, value: 1, expr: custom.expr, name: custom.name))
                }
            }
        }
    }

    private var header: some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            Text("Event Scan").font(.title2.bold()).fixedSize()
            Picker("", selection: $scope) {
                ForEach(["Sheet stocks", "My Filter", "Timing Lab sheet", "All NSE"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { run() } label: { Label(sc.running ? "Scanning…" : "Run scan", systemImage: "magnifyingglass") }
                .buttonStyle(.borderedProminent).disabled(sc.running || conds.isEmpty || dc.book.series.isEmpty).fixedSize()
            if sc.running { ProgressView().controlSize(.small) }
            Text(dc.book.days.last.map { "NSE data up to \($0) · \(dc.book.series.count) stocks" } ?? "No NSE delivery data — open Delivery Analysis to download it")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var condEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trading days since… (counted back from the latest NSE day, like Pine ta.barssince)").font(.caption.bold())
            ForEach($conds) { $c in
                HStack(spacing: 6) {
                    Picker("", selection: seriesBinding($c)) {
                        Section("Built in") { ForEach(ScanMetric.allCases) { Text($0.rawValue).tag("b:" + $0.rawValue) } }
                        if !customs.isEmpty { Section("Custom") { ForEach(customs) { Text($0.name).tag("c:" + $0.id.uuidString) } } }
                        if let e = c.expr, !customs.contains(where: { $0.expr == e }) { Text(c.label).tag("x:" + e) }
                        Divider()
                        Text("New custom series…").tag("new")
                    }.labelsHidden().fixedSize()
                    .help(c.expr ?? c.metric.help)
                    Picker("", selection: $c.event) { ForEach(ScanEvent.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                        .help("crosses below = the day it went from ≥ value to < value (start of the move); last day below = the latest day it was < value; becomes = the day it changed to exactly this value (e.g. Trend_ratio becomes 1); last day equal to = the latest day it was exactly this value")
                    TextField("", value: $c.value, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                    Text(c.expr ?? c.metric.help).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    if c.expr != nil {
                        Button { editingCond = c.id; showCustom = true } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                            .help("Edit this custom series")
                    }
                    Button { conds.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                TextField("Add: e.g. HI/T3 < 1.10 · DELSMA > 99 · close / sma(close, 50) crosses above 1.1 · roc(close, 5) > 20", text: $quick)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 460).onSubmit(addQuick)
                Button("Add") { addQuick() }
                Button { conds.append(ScanCond()) } label: { Label("Condition", systemImage: "plus") }
                Button { editingCond = nil; showCustom = true } label: { Label("Custom series…", systemImage: "function") }
                    .help("Make your own series from close, delivery, volume … e.g. close / sma(close, 50), roc(close, 5), dq / sma(dq, 20)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Picker selection ↔ condition: "b:<metric>", "c:<custom id>", "x:<expression>", "new".
    private func seriesBinding(_ c: Binding<ScanCond>) -> Binding<String> {
        Binding(get: {
            if let e = c.wrappedValue.expr { return customs.first { $0.expr == e }.map { "c:" + $0.id.uuidString } ?? "x:" + e }
            return "b:" + c.wrappedValue.metric.rawValue
        }, set: { v in
            if v == "new" { editingCond = c.wrappedValue.id; showCustom = true; return }
            if v.hasPrefix("b:"), let m = ScanMetric(rawValue: String(v.dropFirst(2))) { c.wrappedValue.metric = m; c.wrappedValue.expr = nil; c.wrappedValue.name = nil }
            if v.hasPrefix("c:"), let k = customs.first(where: { "c:" + $0.id.uuidString == v }) { c.wrappedValue.expr = k.expr; c.wrappedValue.name = k.name }
        })
    }

    private func addQuick() {
        if let c = ScanCond.parse(quick, columns: vm.headers) { conds.append(c); quick = "" } else { NSSound.beep() }
    }

    // MARK: Results

    private var shown: [ScanRow] {
        var r = sc.rows
        let ids = conds.map(\.id)
        if onlyHits { r = r.filter { row in ids.contains { row.hits[$0] != nil } } }
        if within > 0 { r = r.filter { row in ids.contains { (row.hits[$0]?.bars ?? .max) <= within } } }
        if sortBy == "symbol" { r.sort { ascending ? $0.symbol < $1.symbol : $0.symbol > $1.symbol } }
        else if let id = UUID(uuidString: sortBy) ?? conds.first?.id {
            r.sort { a, b in
                let x = a.hits[id]?.bars ?? Int.max, y = b.hits[id]?.bars ?? Int.max
                return x != y ? (ascending ? x < y : (x == .max ? false : (y == .max ? true : x > y))) : a.symbol < b.symbol
            }
        }
        return r
    }

    private var resultsView: some View {
        let list = shown
        return VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 12, lineSpacing: 6) {
                Text("\(list.count) of \(sc.rows.count) stocks").font(.caption.bold()).fixedSize()
                HStack(spacing: 4) {
                    Text("Sort").font(.caption)
                    Picker("", selection: $sortBy) {
                        Text("Symbol").tag("symbol")
                        ForEach(conds) { Text("days since \($0.title)").tag($0.id.uuidString) }
                    }.labelsHidden().fixedSize()
                    Picker("", selection: $ascending) { Text("fewest days first").tag(true); Text("most days first").tag(false) }.labelsHidden().fixedSize()
                }.fixedSize()
                Toggle("Only stocks where it happened", isOn: $onlyHits).toggleStyle(.checkbox).fixedSize()
                HStack(spacing: 4) {
                    Text("within").font(.caption)
                    Picker("", selection: $within) { ForEach([0, 5, 10, 21, 63, 126, 252], id: \.self) { Text($0 == 0 ? "any time" : "\($0) days").tag($0) } }
                        .labelsHidden().fixedSize()
                }.fixedSize()
                Divider().frame(height: 16)
                HStack(spacing: 4) {
                    Text("Charts centred on").font(.caption)
                    Picker("", selection: $centreOn) { ForEach(conds) { Text($0.title).tag(Optional($0.id)) } }.labelsHidden().fixedSize()
                    Button { openReel(list) } label: { Label("Chart Reel", systemImage: "film.stack") }
                        .buttonStyle(.borderedProminent).disabled(list.isEmpty || centreOn == nil)
                        .help("Chart 1 + Delivery chart for each stock, in this order, both centred on the event's date")
                }.fixedSize()
                Button("Copy symbols") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(list.map(\.symbol).joined(separator: ", "), forType: .string) }.fixedSize()
                Button("Export CSV…") { export(list) }.fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            // header row
            HStack(spacing: 0) {
                Text("Symbol").frame(width: 120, alignment: .leading)
                ForEach(conds) { c in Text("since \(c.title)").frame(width: 210, alignment: .leading).lineLimit(1) }
                ForEach(nowColumns, id: \.key) { col in Text("\(col.label) now").frame(width: 110, alignment: .trailing).lineLimit(1) }
                Spacer()
            }
            .font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 4)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { r in row(r).background(list.firstIndex { $0.id == r.id }.map { $0 % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05) } ?? .clear) }
                }
            }
        }
    }

    private var nowColumns: [(key: String, label: String)] {
        var seen = Set<String>(), out: [(key: String, label: String)] = []
        for c in conds where seen.insert(c.seriesKey).inserted { out.append((c.seriesKey, c.label)) }
        return out
    }

    private func row(_ r: ScanRow) -> some View {
        HStack(spacing: 0) {
            SymbolWithDots(symbol: r.symbol).frame(width: 120, alignment: .leading)
            ForEach(conds) { c in
                Group {
                    if let h = r.hits[c.id] {
                        HStack(spacing: 6) {
                            Text("\(h.bars) d").monospacedDigit().bold().frame(width: 50, alignment: .trailing)
                            Text(h.day).monospacedDigit().foregroundStyle(.secondary)
                            Text(CombiEngine.fmt(h.atEvent)).font(.caption).foregroundStyle(.tertiary)
                        }
                    } else { Text("never").foregroundStyle(.tertiary) }
                }
                .frame(width: 210, alignment: .leading)
            }
            ForEach(nowColumns, id: \.key) { col in
                Text(r.now[col.key].map { CombiEngine.fmt($0) } ?? "—").monospacedDigit().frame(width: 110, alignment: .trailing)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let id = centreOn, let h = r.hits[id] { openReel([r], start: r.symbol, day: h.day) } else { vm.openChart(r.symbol, queue: shown.map(\.symbol), openWindow: openWindow) }
        }
        .contextMenu {
            ForEach(conds) { c in
                if let h = r.hits[c.id] { Button("Chart Reel at \(c.title) (\(h.day))") { openReel(shown, start: r.symbol, centre: c.id) } }
            }
            Button("Open in Chart viewer") { vm.openChart(r.symbol, queue: shown.map(\.symbol), openWindow: openWindow) }
            WatchlistSubmenu(symbols: [r.symbol], source: "Event scan")
            Button("Earnings summary of \(r.symbol)") { EarningsSummaryCenter.shared.request(r.symbol, model: vm.settings.groqModel); openWindow(id: "earnsum") }
            Button("Copy \(r.symbol)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.symbol, forType: .string) }
        }
    }

    private func run() {
        let book = dc.book
        let c = conds
        var syms: [String]? = nil
        if let label = vm.labelIndex {
            func sym(_ r: SheetRow) -> String { r.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
            switch scope {
            case "Sheet stocks": syms = vm.table.rows.map(sym)
            case "My Filter": syms = vm.filterRows.map(sym)
            default: break
            }
        }
        if scope == "Timing Lab sheet", let t = TimingLabCenter.shared.table, let sc = t.index(of: UserDefaults.standard.string(forKey: "tl.symbol") ?? "Symbol") {
            syms = t.rows.map { $0.text(sc).trimmingCharacters(in: .whitespaces).uppercased() }
        }
        let list = syms.map { Array(Set($0)) }
        let asOf = book.days.last ?? ""
        sc.running = true
        Task {
            let cols = vm.headers
            let sheet = vm.labelIndex.map { (current: vm.table, label: $0, liveDay: HistoryStore.dayKey(vm.dataDay(of: vm.table))) }
            let rows = await Task.detached(priority: .userInitiated) { ScanEngine.run(book, symbols: list, conds: c, asOf: asOf, columns: cols, sheet: sheet) }.value
            sc.rows = rows
            sc.running = false
            sc.ranAt = Date()
            if sortBy.isEmpty { sortBy = c.first?.id.uuidString ?? "symbol" }
        }
    }

    /// Chart Reel (Chart 1 + Delivery), in this order, each centred on the chosen event's day.
    private func openReel(_ list: [ScanRow], start: String? = nil, centre: UUID? = nil, day: String? = nil) {
        guard let cid = centre ?? centreOn, let cond = conds.first(where: { $0.id == cid }) else { return }
        sc.reel = list.compactMap { r in
            guard let h = r.hits[cid] else { return nil }
            return (r.symbol, "\(cond.title) · \(h.bars) d ago", h.day)
        }
        let d = UserDefaults.standard
        d.set(ReelSource.scan.rawValue, forKey: "reel.source")
        let l = ReelLayout(rawValue: d.string(forKey: "reel.layout") ?? "") ?? .chart1
        if l == .chart1 || l == .chart2 { d.set(ReelLayout.withDelivery.rawValue, forKey: "reel.layout") }
        let key = start.map { s in sc.reel.first { $0.symbol == s }.map { "\($0.symbol)|\($0.day)" } ?? "" } ?? ""
        d.set(key, forKey: "reel.mbStart")
        d.set(UUID().uuidString + "|" + key, forKey: "reel.jump")
        openWindow(id: "reel")
    }

    private func export(_ list: [ScanRow]) {
        let p = NSSavePanel(); p.nameFieldStringValue = "event-scan.csv"; p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        var s = "symbol," + conds.map { "\"days since \($0.title)\",\"date \($0.title)\"" }.joined(separator: ",") + "\n"
        for r in list { s += r.symbol + "," + conds.map { c in r.hits[c.id].map { "\($0.bars),\($0.day)" } ?? "," }.joined(separator: ",") + "\n" }
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}


// MARK: - Making / editing a custom series

struct CustomSeriesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dc = DeliveryCenter.shared
    let start: ScanCond?
    let columns: [String]
    let done: (ScanCustom?) -> Void
    @State private var list = ScanCustomStore.all
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var expr = ""
    @State private var sample = ""
    @State private var error: String?
    @State private var preview: [(String, Double?)] = []

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // saved customs
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved").font(.headline)
                List(selection: $editingID) {
                    ForEach(list) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).bold()
                            Text(c.expr).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(c.id)
                        .contextMenu { Button("Delete", role: .destructive) { list.removeAll { $0.id == c.id }; ScanCustomStore.all = list } }
                    }
                }
                .frame(width: 220)
                Button { editingID = nil; name = ""; expr = "" } label: { Label("New", systemImage: "plus") }
            }
            // editor
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom series").font(.title3.bold())
                TextField("Name, e.g. Close / SMA50", text: $name).textFieldStyle(.roundedBorder)
                TextField("close / sma(close, 50)", text: $expr, axis: .vertical).textFieldStyle(.roundedBorder).font(.body.monospaced()).lineLimit(2...5)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text("Try on").font(.caption)
                    TextField("symbol", text: $sample).textFieldStyle(.roundedBorder).frame(width: 120)
                    if !preview.isEmpty {
                        ForEach(preview, id: \.0) { p in
                            VStack(spacing: 0) {
                                Text(String(p.0.suffix(5))).font(.caption2).foregroundStyle(.secondary)
                                Text(p.1.map { CombiEngine.fmt($0) } ?? "na").font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Names: close · dq (delivered qty) · per (Deliv %) · value (dq×close) · vol (traded qty) · hit3 · delsma · dqprank · t3 · t3color · sma22 · sma66")
                        Text("Data-sheet columns too: count · ds · d_trigger … — names with spaces or / in quotes: \"C/DL2C\". Their history = the days the app saved the sheet (the preview here shows NSE values only).")
                        Text("Functions: sma(x,n) ema(x,n) highest(x,n) lowest(x,n) change(x,n) roc(x,n) % · prank(x,n) · abs(x) max(a,b) min(a,b)  (ta. prefix OK)")
                        Text("History: x[1] = yesterday · Operators: + - * / ( )")
                        Text("Ideas: close / sma(close, 50) · roc(close, 5) · dq / sma(dq, 20) · value / highest(value, 300) · close / highest(close, 252)[1]")
                            .foregroundStyle(.secondary)
                        Text("Two series: write the difference and compare with 0 — e.g. close - sma(close, 50) crosses above 0.").foregroundStyle(.secondary)
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                HStack {
                    if editingID != nil {
                        Button("Delete", role: .destructive) { list.removeAll { $0.id == editingID }; ScanCustomStore.all = list; editingID = nil; name = ""; expr = "" }
                    }
                    Spacer()
                    Button("Cancel") { done(nil); dismiss() }.keyboardShortcut(.cancelAction)
                    Button(start == nil ? "Save & add condition" : "Save & use") { save() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(error != nil || expr.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 820, height: 460)
        .onAppear {
            if let e = start?.expr {
                if let c = list.first(where: { $0.expr == e }) { editingID = c.id; name = c.name } else { name = start?.name ?? "" }
                expr = e
            }
            sample = dc.book.series.keys.sorted().first(where: { $0 == "RELIANCE" }) ?? dc.book.series.keys.sorted().first ?? ""
        }
        .onChange(of: editingID) { id in if let c = list.first(where: { $0.id == id }) { name = c.name; expr = c.expr } }
        .task(id: expr + "|" + sample) { check() }
    }

    private func check() {
        let t = expr.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { error = nil; preview = []; return }
        do {
            let e = try ScanExpr.parse(t, columns: columns)
            error = nil
            if let s = dc.book.series[sample.trimmingCharacters(in: .whitespaces).uppercased()] {
                var cache: [String: [Double?]] = [:]
                let v = e.eval(s, cache: &cache)
                preview = (max(0, s.days.count - 6)..<s.days.count).map { (s.days[$0], $0 < v.count ? v[$0] : nil) }
            } else { preview = [] }
        } catch { self.error = error.localizedDescription; preview = [] }
    }

    private func save() {
        let t = expr.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? t : name.trimmingCharacters(in: .whitespaces)
        var c = ScanCustom(name: n, expr: t)
        if let id = editingID, let i = list.firstIndex(where: { $0.id == id }) { c.id = id; list[i] = c } else { list.append(c) }
        ScanCustomStore.all = list
        done(c)
        dismiss()
    }
}

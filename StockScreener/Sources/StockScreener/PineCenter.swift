import SwiftUI
import AppKit

// Your Pine Script indicators inside the app: kept here, run by PineEngine on each stock, shown on the delivery chart
// (drawn, or as a legend number), as marks on candles, and as Filter columns usable in formulas.

struct PineOut: Codable, Equatable {
    /// plots: "legend" (number only) · "price" (on the candles) · "deliv" (delivery pane) · "own" (own scale over the
    /// delivery pane) · "off". Shapes / alerts: "marks" or "off".
    var show = "legend"
    var legend = true                       // also show the number in the legend when drawn
    var filter = false                      // also a Filter column (last value; 1 / 0 for shapes)
    var column = ""                         // Filter column name (blank = automatic)
    var color: String? = nil                // your colour instead of the script's
}

struct PineScript: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New indicator"
    var source = ""
    var enabled = true
    var outputs: [String: PineOut] = [:]    // by plot title
}

/// Filter-column values by stock and day, readable from anywhere (the table and Formula counts' past days).
final class PineColumns: @unchecked Sendable {
    static let shared = PineColumns()
    private let lock = NSLock()
    private var axis: [String] = []
    private var index: [String: Int] = [:]
    private var values: [String: [String: [Float]]] = [:]       // column → stock → value per axis day
    private var nameSet = Set<String>()
    private var ordered: [String] = []

    var names: [String] { lock.lock(); defer { lock.unlock() }; return ordered }
    func has(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return nameSet.contains(name) }

    func replace(axis a: [String], columns: [String], values v: [String: [String: [Float]]]) {
        lock.lock(); defer { lock.unlock() }
        axis = a
        index = Dictionary(a.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { x, _ in x })
        values = v; ordered = columns; nameSet = Set(columns)
    }

    /// The value on `day` (or the last trading day before it).
    func value(_ column: String, _ symbol: String, _ day: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let col = values[column], let arr = col[symbol], !axis.isEmpty else { return nil }
        var k = index[day] ?? -1
        if k < 0 {
            var lo = 0, hi = axis.count
            while lo < hi { let m = (lo + hi) / 2; if axis[m] <= day { lo = m + 1 } else { hi = m } }
            k = lo - 1
        }
        guard k >= 0, k < arr.count else { return nil }
        let f = arr[k]
        return f.isNaN ? nil : Double(f)
    }
}

@MainActor final class PineCenter: ObservableObject {
    static let shared = PineCenter()

    @Published var scripts: [PineScript] = [] { didSet { if scripts != oldValue { save(); changed() } } }
    @Published private(set) var revision = 0
    @Published private(set) var columnsRunning = false
    @Published private(set) var columnsProgress = 0.0
    @Published private(set) var columnsStatus = ""
    weak var vm: ScreenerViewModel?
    var autoStarted = false

    private var programs: [String: PineProgram] = [:]
    private var chartCache: [String: ChartOut] = [:]
    private var chartOrder: [String] = []
    private var computing = Set<String>()
    private var columnsTask: Task<Void, Never>?
    private var sheetCache: [String: [String: [String: Double]]] = [:]     // column → day → stock → value

    struct ChartOut { var plots: [LWChartData.PineJS] = []; var marks: [LWChartData.Marker] = [] }

    static let storeKey = "pine.scripts"
    var filterBars: Int { let v = UserDefaults.standard.integer(forKey: "pine.filterBars"); return v > 0 ? v : 600 }

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.storeKey), let s = try? JSONDecoder().decode([PineScript].self, from: d) { scripts = s }
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(scripts), forKey: Self.storeKey) }

    private func changed() {
        chartCache = [:]; chartOrder = []
        revision += 1
    }

    func program(_ s: PineScript) -> PineProgram {
        if let p = programs[s.source] { return p }
        let p = PineParser.parse(s.source)
        if programs.count > 40 { programs = [:] }
        programs[s.source] = p
        return p
    }

    // MARK: inputs

    /// One stock's daily data for a script: the NSE delivery days are the bars.
    func input(_ symbol: String, bars: Int? = nil, sheetColumns: [String] = []) -> PineInput? {
        let sym = symbol.uppercased()
        let dc = DeliveryCenter.shared
        guard let s = dc.book.series[sym], !s.days.isEmpty else { return nil }
        let n = s.days.count
        let from = bars.map { max(0, n - $0) } ?? 0
        let days = Array(s.days[from...])
        var inp = PineInput()
        inp.symbol = sym; inp.days = days
        // candles: Yahoo when the chart has fetched them, else the app's daily prices, else NSE closes
        let cs: [YahooClient.Candle] = CandleCache.shared.peek(sym)
            ?? DeliveryMiniChart.candles(vm?.priceBook.series(for: sym), nse: s)
        var byDay: [String: YahooClient.Candle] = [:]
        for c in cs { byDay[c.day] = c }
        var o: [Double] = [], h: [Double] = [], l: [Double] = [], c: [Double] = [], v: [Double] = []
        o.reserveCapacity(days.count); h.reserveCapacity(days.count); l.reserveCapacity(days.count); c.reserveCapacity(days.count); v.reserveCapacity(days.count)
        for (k, d) in days.enumerated() {
            let i = from + k
            if let x = byDay[d] {
                o.append(x.open); h.append(x.high); l.append(x.low); c.append(x.close); v.append(x.volume > 0 ? x.volume : .nan)
            } else {
                let cl = i < s.close.count ? s.close[i] : .nan
                o.append(cl); h.append(cl); l.append(cl); c.append(cl); v.append(.nan)
            }
        }
        inp.series["open"] = o; inp.series["high"] = h; inp.series["low"] = l; inp.series["close"] = c; inp.series["volume"] = v
        func slice(_ a: [Double]) -> [Double] { (from..<n).map { $0 < a.count ? a[$0] : .nan } }
        inp.series["deliv_qty"] = slice(s.qty)
        inp.series["deliv_pct"] = slice(s.per)
        inp.series["nse_close"] = slice(s.close)
        inp.series["deliv_value"] = slice(zip(s.qty, s.close).map { $0 * $1 })
        let ds = DeliveryColumns.delSmaCSeries(s)
        inp.series["delsmac"] = (from..<n).map { $0 < ds.count ? (ds[$0] ?? .nan) : .nan }
        let dl = DealsCenter.shared
        if !dl.deals.isEmpty {
            let size = dl.sizeByDay(sym), buy = dl.buyByDay(sym)
            inp.series["dealsize"] = days.map { size[$0] ?? 0 }
            inp.series["dealbuy"] = days.map { buy[$0] ?? 0 }
            inp.series["dealsell"] = days.map { max(0, (size[$0] ?? 0) - (buy[$0] ?? 0)) }
        }
        for col in sheetColumns {
            let m = sheetCache[col] ?? [:]
            inp.sheet[col] = days.map { m[$0]?[sym] ?? .nan }
        }
        return inp
    }

    /// sheet("COL"): that column on every day the app stored your sheet (and today's sheet), for all stocks.
    func loadSheetColumns(_ cols: [String]) async {
        guard let vm, let label = vm.labelIndex else { return }
        let need = cols.filter { sheetCache[$0] == nil }
        guard !need.isEmpty else { return }
        let current = vm.table
        let liveDay = HistoryStore.dayKey(vm.dataDay(of: current))
        var out: [String: [String: [String: Double]]] = [:]
        for d in HistoryStore.days() where d < liveDay {
            let t: SheetTable? = await Task.detached(priority: .utility) {
                HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) }
            }.value
            guard let t else { continue }
            for col in need {
                guard let j = t.index(of: col) else { continue }
                var m: [String: Double] = [:]
                for r in t.rows { if let v = r.number(j) { m[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] = v } }
                out[col, default: [:]][d] = m
            }
        }
        for col in need {
            guard let j = current.index(of: col) else { continue }
            var m: [String: Double] = [:]
            for r in current.rows { if let v = r.number(j) { m[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] = v } }
            out[col, default: [:]][liveDay] = m
        }
        for col in need { sheetCache[col] = out[col] ?? [:] }
    }

    /// Other stocks a script reads with request.security("NSE:XYZ", …).
    func others(_ p: PineProgram, except symbol: String) -> [String: PineInput] {
        var o: [String: PineInput] = [:]
        for sym in p.securitySymbols where sym != symbol.uppercased() {
            if let i = input(sym, sheetColumns: p.sheetColumns) { o[sym] = i }
        }
        return o
    }

    /// Runs one script on one stock (the editor's Check button).
    func runOne(_ s: PineScript, symbol: String) async -> (PineProgram, PineResult?, PineInput?) {
        let p = program(s)
        await loadSheetColumns(p.sheetColumns)
        guard var inp = input(symbol, sheetColumns: p.sheetColumns) else { return (p, nil, nil) }
        inp.others = others(p, except: symbol)
        let r = await Task.detached(priority: .userInitiated) { PineRun(p, inp).run() }.value
        return (p, r, inp)
    }

    // MARK: chart

    /// What the delivery chart draws for a stock (computed in the background the first time; the chart then redraws).
    func chartOutputs(_ symbol: String) -> ChartOut {
        let sym = symbol.uppercased()
        guard scripts.contains(where: { $0.enabled }) else { return ChartOut() }
        if let c = chartCache[sym] { return c }
        if !computing.contains(sym) {
            computing.insert(sym)
            Task { @MainActor in
                let out = await computeChart(sym)
                computing.remove(sym)
                chartCache[sym] = out; chartOrder.append(sym)
                while chartOrder.count > 30 { chartCache[chartOrder.removeFirst()] = nil }
                revision += 1
            }
        }
        return ChartOut()
    }

    private func computeChart(_ sym: String) async -> ChartOut {
        var out = ChartOut()
        for s in scripts where s.enabled {
            let (p, r, inp) = await runOne(s, symbol: sym)
            guard let r, let inp else { continue }
            _ = p
            for (k, pl) in r.plots.enumerated() {
                let o = s.outputs[pl.title] ?? Self.defaultOut(pl)
                let color = o.color ?? Self.solid(pl.color)
                let key = "\(s.id.uuidString.prefix(6))_\(k)"
                if pl.kind == "bg" || pl.kind == "barcolor" {
                    guard o.show != "off" else { continue }
                    var pts: [LWChartData.Point] = []
                    for (i, c) in pl.colors.enumerated() where i < inp.days.count {
                        if let c { pts.append(LWChartData.Point(time: inp.days[i], value: 1, color: c)) }
                    }
                    out.plots.append(LWChartData.PineJS(key: key, title: pl.title, color: color, pane: pl.kind, style: pl.kind,
                                                        width: 1, legend: false, points: pts))
                    continue
                }
                if pl.kind == "shape" || pl.kind == "alert" || pl.kind == "label" {
                    guard o.show != "off" else { continue }
                    for (i, v) in pl.values.enumerated() where !v.isNaN && i < inp.days.count {
                        let lt = i < pl.texts.count ? (pl.texts[i] ?? "") : ""
                        let text = !lt.isEmpty ? lt : (pl.text.isEmpty ? String(pl.title.prefix(4)) : pl.text)
                        let below = pl.location.contains("below") || pl.location.contains("bottom")
                        out.marks.append(LWChartData.Marker(time: inp.days[i], text: text, position: below ? "belowBar" : "aboveBar",
                                                            color: pl.colors[i].map(Self.solid) ?? color,
                                                            shape: Self.markerShape(pl.shape, below: below),
                                                            info: "Pine · \(s.name) · \(pl.title)"))
                    }
                    continue
                }
                guard o.show != "off" else { continue }
                var pts: [LWChartData.Point] = []
                pts.reserveCapacity(inp.days.count)
                let varied = Set(pl.colors.compactMap { $0 }).count > 1
                for (i, v) in pl.values.enumerated() where i < inp.days.count {
                    pts.append(LWChartData.Point(time: inp.days[i], value: v.isNaN || v.isInfinite ? nil : v,
                                                 color: pl.kind == "hist" || varied ? pl.colors[i].map(Self.solid) : nil))
                }
                let pane = o.show == "legend" ? "none" : o.show
                let style = pl.kind == "hline" ? "line" : pl.kind
                out.plots.append(LWChartData.PineJS(key: key, title: pl.title, color: color, pane: pane, style: style,
                                                    width: pl.width, legend: o.show == "legend" || o.legend, points: pts))
            }
        }
        return out
    }

    static func defaultOut(_ p: PinePlot) -> PineOut {
        var o = PineOut()
        if p.kind == "shape" || p.kind == "alert" || p.kind == "label" { o.show = "marks" }
        if p.kind == "bg" || p.kind == "barcolor" { o.show = "chart"; o.legend = false }
        return o
    }

    /// The chart needs solid colours for lines; Pine's transparency becomes a lighter rgba.
    static func solid(_ c: String) -> String { c.isEmpty ? "#2962FF" : c }

    static func markerShape(_ s: String, below: Bool) -> String {
        if s.contains("triangleup") || s.contains("arrowup") || s.contains("labelup") { return "arrowUp" }
        if s.contains("triangledown") || s.contains("arrowdown") || s.contains("labeldown") { return "arrowDown" }
        if s.contains("square") || s.contains("diamond") { return "square" }
        if s.contains("circle") || s.contains("xcross") || s.contains("cross") || s.contains("flag") { return "circle" }
        return below ? "arrowUp" : "arrowDown"
    }

    // MARK: Filter columns

    static func columnName(_ s: PineScript, _ title: String, _ o: PineOut) -> String {
        if !o.column.trimmingCharacters(in: .whitespaces).isEmpty { return o.column.trimmingCharacters(in: .whitespaces) }
        func clean(_ x: String) -> String {
            String(x.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }).replacingOccurrences(of: "__", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        return "P_" + String(clean(s.name).prefix(10)) + "_" + String(clean(title).prefix(10))
    }

    /// Runs every script with Filter outputs on every stock in your sheet (last `filterBars` days), then the table refreshes.
    func computeColumns() {
        guard let vm, let label = vm.labelIndex else { return }
        columnsTask?.cancel()
        let jobs: [(PineScript, PineProgram)] = scripts.filter { s in s.enabled && s.outputs.values.contains { $0.filter } }.map { ($0, program($0)) }
        guard !jobs.isEmpty else {
            if !PineColumns.shared.names.isEmpty { PineColumns.shared.replace(axis: [], columns: [], values: [:]); vm.setTableKeepingRaw() }
            columnsStatus = ""
            return
        }
        let syms = Array(Set(vm.table.rows.map { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() })).sorted()
        let bars = filterBars
        let axis = Array(DeliveryCenter.shared.book.days.suffix(bars))
        columnsRunning = true; columnsProgress = 0
        columnsTask = Task { @MainActor in
            var vals: [String: [String: [Float]]] = [:]
            var names: [String] = []
            for (s, p) in jobs {
                for (t, o) in s.outputs where o.filter { let nm = Self.columnName(s, t, o); if !names.contains(nm) { names.append(nm) } }
                await loadSheetColumns(p.sheetColumns)
            }
            let total = Double(max(1, syms.count * jobs.count))
            var done = 0.0
            for (s, p) in jobs {
                var k = 0
                while k < syms.count {
                    if Task.isCancelled { columnsRunning = false; return }
                    let chunk = Array(syms[k..<min(syms.count, k + 40)])
                    k += 40
                    let shared = others(p, except: "")
                    let inputs: [PineInput] = chunk.compactMap { sym -> PineInput? in
                        guard var i = input(sym, bars: bars, sheetColumns: p.sheetColumns) else { return nil }
                        i.others = shared
                        return i
                    }
                    let results: [(String, [String], PineResult)] = await Task.detached(priority: .utility) {
                        inputs.map { ($0.symbol, $0.days, PineRun(p, $0).run()) }
                    }.value
                    for (sym, days, r) in results {
                        let pos = Dictionary(days.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
                        for pl in r.plots {
                            guard let o = s.outputs[pl.title], o.filter else { continue }
                            let nm = Self.columnName(s, pl.title, o)
                            var arr = [Float](repeating: .nan, count: axis.count)
                            for (j, d) in axis.enumerated() {
                                guard let i = pos[d], i < pl.values.count else { continue }
                                let v = pl.values[i]
                                if pl.kind == "shape" || pl.kind == "alert" { arr[j] = v.isNaN ? 0 : 1 } else if !v.isNaN { arr[j] = Float(v) }
                            }
                            vals[nm, default: [:]][sym] = arr
                        }
                    }
                    done += Double(chunk.count)
                    columnsProgress = done / total
                    columnsStatus = "Filter columns \(Int(columnsProgress * 100))%"
                }
            }
            PineColumns.shared.replace(axis: axis, columns: names, values: vals)
            columnsRunning = false
            columnsStatus = names.isEmpty ? "" : "\(names.count) Filter column\(names.count == 1 ? "" : "s") ready (\(syms.count) stocks, last \(bars) days)"
            vm.setTableKeepingRaw()
            MemoryRelief.giveBack()
        }
    }

    // MARK: Groq

    static let groqSystem = """
    You rewrite TradingView Pine Script so that a small interpreter can run it. Keep the indicator's logic and outputs.
    The interpreter supports: variables (x = …, var x = …, x := …, +=, -=), if / else if / else blocks, for i = a to b \
    [by s] loops, single-line and indented functions f(a, b) => …, ternary ?:, and / or / not, history x[n], tuple \
    results [a, b, c] = ta.macd(…), input.*(defval, …), color.* constants, color.new, color.rgb, na, nz, fixnan, \
    the series open high low close volume hl2 hlc3 ohlc4 bar_index, and these extra daily series: deliv_qty, deliv_pct, \
    deliv_value, nse_close, delsmac, dealsize, dealbuy, dealsell, and sheet("COLUMN") for a column of the user's sheet. \
    Functions: ta.sma ema rma wma vwma stdev variance dev median linreg highest lowest highestbars lowestbars change mom \
    roc rsi crossover crossunder cross percentrank barssince valuewhen cum tr atr macd bb rising falling cci mfi swma; \
    math.abs max min avg round floor ceil sqrt log log10 exp pow sign sum; str.tostring. Outputs: plot, plotshape, \
    plotchar, hline, alertcondition (title = … named argument).
    Also supported: switch (statement and value), x = if …, while, break, continue, arrays (array.new_*, push, pop, get, \
    set, size, sum, avg, max, min, sort …, and a.push(x) method calls), bgcolor, barcolor, label.new(x, y, text), \
    request.security(symbol, timeframe, expr) for NSE stocks with timeframes D, W, M, 3M, 12M.
    NOT supported (rewrite them away): intraday timeframes, other request.* calls, matrices, maps, lines, boxes, \
    tables, strategy.*, user-defined types and methods, imports, libraries, fill. The data is daily NSE.
    Reply with ONLY the complete rewritten script — no explanations, no markdown fences.
    """

    func groqRewrite(_ source: String, issues: [String]) async throws -> String {
        let model = vm?.settings.groqModel ?? ""
        guard !model.isEmpty else { throw GroqClient.Failure(message: "Pick a Groq model in Settings first") }
        let user = "Problems the interpreter found:\n" + issues.map { "- " + $0 }.joined(separator: "\n") + "\n\nScript:\n" + source
        var text = try await GroqClient.chat(model: model, system: Self.groqSystem, user: user, json: false, maxTokens: 4000)
        if let a = text.range(of: "```") {
            text = String(text[a.upperBound...])
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            if let b = text.range(of: "```", options: .backwards) { text = String(text[..<b.lowerBound]) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The Pine window

struct PineView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var pc = PineCenter.shared
    @ObservedObject private var fm = FormulaMarks.shared
    @AppStorage("pine.filterBars") private var filterBars = 600
    @State private var selected: UUID?
    @State private var draft = PineScript()
    @State private var symbol = ""
    @State private var checking = false
    @State private var program: PineProgram?
    @State private var result: PineResult?
    @State private var lastDay = ""
    @State private var groqBusy = false
    @State private var groqText: String?
    @State private var groqError: String?
    @State private var showHelp = false

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
            editor.frame(minWidth: 620)
        }
        .onAppear {
            pc.vm = vm
            if symbol.isEmpty { symbol = fm.chartSymbol }
            if selected == nil, let f = pc.scripts.first { select(f) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pine scripts").font(.headline)
                Spacer()
                Button { newScript() } label: { Image(systemName: "plus") }.help("New script (paste a Pine indicator)")
            }
            List(selection: $selected) {
                ForEach(pc.scripts) { s in
                    HStack {
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { v in update(s.id) { $0.enabled = v } })).labelsHidden().toggleStyle(.checkbox)
                        Text(s.name).lineLimit(1)
                    }
                    .tag(s.id)
                }
            }
            .onChange(of: selected) { id in if let id, let s = pc.scripts.first(where: { $0.id == id }) { select(s) } }
            Divider()
            Stepper("Filter columns: last \(filterBars) days", value: $filterBars, in: 300...1500, step: 100).font(.caption)
            HStack {
                if pc.columnsRunning { ProgressView(value: pc.columnsProgress).frame(width: 80) }
                Text(pc.columnsStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Recompute Filter columns") { pc.computeColumns() }.disabled(pc.columnsRunning).controlSize(.small)
        }
        .padding(8)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                TextField("Stock", text: $symbol).textFieldStyle(.roundedBorder).frame(width: 110)
                    .help("The stock to check the script on (follows the delivery chart)")
                Button { Task { await check() } } label: { Label("Check", systemImage: "play.fill") }.disabled(checking || draft.source.isEmpty)
                Button { Task { await fixWithGroq() } } label: { Label("Fix with Groq", systemImage: "wand.and.stars") }
                    .disabled(groqBusy || draft.source.isEmpty)
                    .help("Groq rewrites the parts the app can't run (request.security, arrays, labels …) — you review it before it's used")
                Button("Save & install") { install() }.keyboardShortcut("s", modifiers: .command).disabled(draft.source.isEmpty)
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .popover(isPresented: $showHelp) { help }
            }
            TextEditor(text: $draft.source)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 220)
                .border(Color.secondary.opacity(0.3))
            if let g = groqText { groqPanel(g) }
            if let e = groqError { Text(e).font(.caption).foregroundStyle(.red) }
            status
            outputs
            HStack {
                Spacer()
                if selected != nil { Button("Delete script", role: .destructive) { deleteSelected() } }
            }
        }
        .padding(10)
    }

    @ViewBuilder private var status: some View {
        if checking { HStack { ProgressView().controlSize(.small); Text("Running on \(symbol.uppercased())…").font(.caption) } }
        if let p = program, !p.issues.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't run yet (\(p.issues.count)):").font(.caption.bold()).foregroundStyle(.orange)
                ForEach(p.issues.prefix(8), id: \.self) { Text("• " + $0).font(.caption2.monospaced()) }
            }
        }
        if let r = result, !r.errors.isEmpty {
            ForEach(r.errors.prefix(5), id: \.self) { Text($0).font(.caption2).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var outputs: some View {
        if let r = result {
            VStack(alignment: .leading, spacing: 4) {
                Text("Outputs on \(symbol.uppercased()) · last day \(lastDay)").font(.caption.bold())
                if r.plots.isEmpty { Text("No plot / plotshape / alertcondition found").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(r.plots.enumerated()), id: \.offset) { _, pl in outputRow(pl) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func outputRow(_ pl: PinePlot) -> some View {
        let isShape = pl.kind == "shape" || pl.kind == "alert" || pl.kind == "label"
        let isColour = pl.kind == "bg" || pl.kind == "barcolor"
        let o = draft.outputs[pl.title] ?? PineCenter.defaultOut(pl)
        let lastV = pl.values.last(where: { !$0.isNaN })
        let hits = pl.values.filter { !$0.isNaN }.count
        return HStack(spacing: 8) {
            Circle().fill(Color(pine: o.color ?? pl.color) ?? .blue).frame(width: 9, height: 9)
            Text(pl.title).font(.caption.monospaced()).frame(width: 160, alignment: .leading).lineLimit(1)
            Text(isShape || isColour ? "\(hits) days" : (lastV.map { String(format: abs($0) >= 1000 ? "%.0f" : "%.3f", $0) } ?? "na"))
                .font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
            Picker("", selection: binding(pl.title, pl, \.show)) {
                if isShape {
                    Text("Marks on candles").tag("marks"); Text("Off").tag("off")
                } else if isColour {
                    Text(pl.kind == "bg" ? "Shade the chart" : "Colour the candles").tag("chart"); Text("Off").tag("off")
                } else {
                    Text("Legend number only").tag("legend")
                    Text("Price pane").tag("price")
                    Text("Delivery pane").tag("deliv")
                    Text("Own scale (delivery pane)").tag("own")
                    Text("Off").tag("off")
                }
            }
            .labelsHidden().frame(width: 190)
            if !isShape && !isColour && o.show != "legend" && o.show != "off" {
                Toggle("legend", isOn: binding(pl.title, pl, \.legend)).toggleStyle(.checkbox).font(.caption)
            }
            Toggle("Filter column", isOn: binding(pl.title, pl, \.filter)).toggleStyle(.checkbox).font(.caption)
            if o.filter {
                TextField(PineCenter.columnName(draft, pl.title, PineOut()), text: binding(pl.title, pl, \.column))
                    .textFieldStyle(.roundedBorder).font(.caption.monospaced()).frame(width: 150)
            }
            Spacer()
        }
    }

    private func binding<T>(_ title: String, _ pl: PinePlot, _ kp: WritableKeyPath<PineOut, T>) -> Binding<T> {
        Binding(get: { (draft.outputs[title] ?? PineCenter.defaultOut(pl))[keyPath: kp] },
                set: { v in var o = draft.outputs[title] ?? PineCenter.defaultOut(pl); o[keyPath: kp] = v; draft.outputs[title] = o })
    }

    private func groqPanel(_ g: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Groq's rewrite — review before using it").font(.caption.bold())
                Spacer()
                Button("Use it") { draft.source = g; groqText = nil; Task { await check() } }
                Button("Discard") { groqText = nil }
            }
            ScrollView { Text(g).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 160)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What scripts can use").font(.headline)
            Text("Bars are NSE trading days (daily). Series: open high low close volume hl2 hlc3 ohlc4 bar_index · deliv_qty deliv_pct deliv_value nse_close · delsmac (DELSMAC) · dealsize dealbuy dealsell (₹ Cr) · sheet(\"COLUMN\") = a column of your sheet on days the app stored it.")
            Text("Runs: variables, var, :=, if / else, for, functions (=>), ternary, x[n], ta.* (sma ema rma wma vwma stdev highest lowest change roc rsi crossover crossunder percentrank barssince valuewhen atr macd bb cci mfi …), math.*, input.*, plot, plotshape, plotchar, hline, alertcondition.")
            Text("Also: if / switch as values (x = if …), switch, while, break / continue, arrays (array.* and a.push(…)), bgcolor (shades the chart), barcolor (colours candles), label.new (marks), request.security — other NSE stocks (\"NSE:XYZ\") and W / M / 3M / 12M bars built from the daily ones.")
            Text("Not run: intraday timeframes, other exchanges / indices not in NSE delivery data, lines / boxes / tables (skipped), strategy.*, matrices, maps. Fix with Groq can rewrite those.")
            Text("Each output: legend number, drawn on the price or delivery pane, marks on candles, and/or a Filter column (usable in formulas and Formula counts).")
        }
        .font(.caption)
        .padding(12)
        .frame(width: 440)
    }

    // MARK: actions

    private func select(_ s: PineScript) {
        selected = s.id; draft = s; program = nil; result = nil; groqText = nil; groqError = nil
    }

    private func newScript() {
        var s = PineScript()
        s.name = "Indicator \(pc.scripts.count + 1)"
        s.source = "//@version=5\nindicator(\"My indicator\")\nplot(ta.sma(close, 20), title = \"SMA 20\")\n"
        pc.scripts.append(s)
        select(s)
    }

    private func update(_ id: UUID, _ f: (inout PineScript) -> Void) {
        guard let i = pc.scripts.firstIndex(where: { $0.id == id }) else { return }
        var s = pc.scripts[i]; f(&s); pc.scripts[i] = s
        if draft.id == id { draft.enabled = s.enabled }
    }

    private func install() {
        if let i = pc.scripts.firstIndex(where: { $0.id == draft.id }) { pc.scripts[i] = draft } else { pc.scripts.append(draft) }
        selected = draft.id
        if draft.outputs.values.contains(where: { $0.filter }) || !PineColumns.shared.names.isEmpty { pc.computeColumns() }
    }

    private func deleteSelected() {
        guard let id = selected else { return }
        pc.scripts.removeAll { $0.id == id }
        selected = nil; draft = PineScript(); result = nil; program = nil
        pc.computeColumns()
    }

    private func check() async {
        let sym = symbol.isEmpty ? (vm.labelIndex.flatMap { l in vm.table.rows.first?.text(l) } ?? "") : symbol
        symbol = sym.uppercased()
        checking = true
        let (p, r, inp) = await pc.runOne(draft, symbol: symbol)
        program = p; result = r; lastDay = inp?.days.last ?? ""
        checking = false
        if inp == nil { groqError = "No NSE delivery data for \(symbol) — pick another stock" } else { groqError = nil }
    }

    private func fixWithGroq() async {
        groqBusy = true; groqError = nil
        let p = PineParser.parse(draft.source)
        do { groqText = try await pc.groqRewrite(draft.source, issues: p.issues.isEmpty ? ["(none found — check the logic still matches TradingView)"] : p.issues) }
        catch { groqError = error.localizedDescription }
        groqBusy = false
    }
}

extension Color {
    /// #RRGGBB / rgba(r,g,b,a) → Color.
    init?(pine: String) {
        let hex = pine
        if hex.hasPrefix("rgba(") {
            let p = hex.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count >= 3 else { return nil }
            self = Color(.sRGB, red: p[0] / 255, green: p[1] / 255, blue: p[2] / 255, opacity: p.count > 3 ? p[3] : 1)
            return
        }
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count >= 6, let v = UInt32(h.prefix(6), radix: 16) else { return nil }
        self = Color(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: 1)
    }
}

/// Opens the Pine scripts window from a chart header.
struct PineButton: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var pc = PineCenter.shared
    var body: some View {
        Button { openWindow(id: "pine") } label: {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                Text("Pine").font(.caption2)
                if pc.scripts.contains(where: { $0.enabled }) { Text("\(pc.scripts.filter { $0.enabled }.count)").font(.caption2.bold()) }
            }
        }
        .buttonStyle(.borderless).fixedSize()
        .help("Your Pine Script indicators: paste one, check it, choose where each output shows (legend, chart, marks, Filter column)")
    }
}

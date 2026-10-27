import SwiftUI
import WebKit
import Combine

/// Chart Reel: flick through charts of a list (daily gainers, D_Trigger = 0 / 1, any column value, your Filter)
/// with a slider, arrow keys or autoplay — Chart 1, Chart 2 or both side by side. Nearby charts preload so
/// stepping is quick.
struct ChartReelView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var pool = ReelPool()
    @StateObject private var deliveryLW = LWChartHolder()
    @AppStorage("reel.syncDelivery") private var syncDelivery = true
    @AppStorage("reel.jump") private var jump = ""            // "<nonce>|<item key>" from Multibaggers when the reel is already open
    @State private var syncNote: String?
    @State private var lastTV = ""
    @State private var syncFails = 0
    @State private var pushedToTVAt = Date.distantPast
    @State private var pendingGoTo: String?
    private let syncTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    @AppStorage("reel.source") private var source = ReelSource.gainers.rawValue
    @AppStorage("reel.column") private var column = ""
    @AppStorage("reel.op") private var op = "="
    @AppStorage("reel.value") private var value = "1"
    @AppStorage("reel.alsoFilter") private var alsoFilter = false
    @AppStorage("reel.layout") private var layout = ReelLayout.chart1.rawValue
    @AppStorage("reel.preload") private var preload = true
    @AppStorage("reel.seconds") private var seconds = 3.0
    @AppStorage("reel.sort") private var sortMode = "List order"
    @AppStorage("reel.seq1") private var seq1 = 3.0          // "1 → 2": seconds on Chart 1
    @AppStorage("reel.seq2") private var seq2 = 3.0          // … then on Chart 2
    @AppStorage("reel.autoZoom") private var autoZoom = true
    @AppStorage("reel.zoomDelay") private var zoomDelay = 2.5
    @AppStorage("reel.zoomSwap") private var zoomSwap = false
    @AppStorage("reel.mbMonth") private var mbMonth = ""
    @AppStorage("reel.mbScope") private var mbScope = "Sheet stocks"
    @AppStorage("mb.center") private var mbCenter = MBCenter.start.rawValue
    @ObservedObject private var mbc = MultibaggerCenter.shared
    @ObservedObject private var mbf = MBFilterCenter.shared
    @AppStorage("mb.fOn") private var fOn = false
    @State private var phase = 0                  // "1 → 2": 0 = showing Chart 1, 1 = Chart 2
    @State private var zoomTick = 0               // redraws the zoom labels

    @State private var index = 0.0                // slider position
    @State private var shown = 0                  // index whose charts are loaded
    @State private var dragging = false
    @State private var playing = false
    @State private var settle: DispatchWorkItem?
    @State private var refresh = 0

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State private var lastStep = Date()

    // MARK: Items

    private var items: [ReelItem] {
        _ = refresh
        guard let label = vm.labelIndex else { return [] }
        func sym(_ r: SheetRow) -> String { r.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
        var out: [ReelItem] = []
        switch ReelSource(rawValue: source) ?? .gainers {
        case .gainers:
            let day = vm.currentGainerDay
            out = vm.gainers(on: day).map { ReelItem(symbol: $0.symbol, note: String(format: "%+.1f%%", $0.change), row: $0.row, gainer: $0, day: day) }
        case .filter:
            out = vm.filterRows.map { ReelItem(symbol: sym($0), note: "", row: $0) }
        case .column:
            let rows = alsoFilter ? vm.filterRows : vm.table.rows
            guard let pred = columnPredicate else { return [] }
            let ci = vm.table.index(of: column)
            out = rows.filter(pred).map { r in ReelItem(symbol: sym(r), note: ci.map { "\(column) \(r.text($0))" } ?? "", row: r) }
        case .all:
            out = vm.table.rows.map { ReelItem(symbol: sym($0), note: "", row: $0) }
        case .scan:
            let rowOf = Dictionary(vm.table.rows.map { (sym($0), $0) }, uniquingKeysWith: { a, _ in a })
            out = ScanCenter.shared.reel.map { e in
                ReelItem(symbol: e.symbol, note: e.note, row: rowOf[e.symbol], goTo: e.day.isEmpty ? nil : e.day, key: "\(e.symbol)|\(e.day)")
            }
        case .multibaggers:
            var ev = mbc.events
            if !mbMonth.isEmpty { ev = ev.filter { $0.month == mbMonth } }
            if mbScope == "Sheet stocks" { let s = Set(vm.allSymbols.map { $0.uppercased() }); ev = ev.filter { s.contains($0.symbol) } }
            if mbScope == "My Filter" { let s = Set(vm.filterRows.map(sym)); ev = ev.filter { s.contains($0.symbol) } }
            if fOn, mbf.ready { ev = ev.filter { mbf.matched.contains($0.id) } }
            let center = MBCenter(rawValue: mbCenter) ?? .start
            let rowOf = Dictionary(vm.table.rows.map { (sym($0), $0) }, uniquingKeysWith: { a, _ in a })
            out = ev.map { e in
                ReelItem(symbol: e.symbol, note: String(format: "%+.0f%% · ", e.gain) + e.monthTitle, row: rowOf[e.symbol],
                         goTo: e.day(for: center), key: e.id)
            }
        }
        var seen = Set<String>()
        out = out.filter { !$0.symbol.isEmpty && seen.insert($0.key ?? $0.symbol).inserted }
        switch sortMode {
        case "A → Z": out.sort { $0.symbol < $1.symbol }
        case "Day % (high first)":
            let day = vm.currentGainerDay
            func ch(_ s: String) -> Double { vm.priceBook.series(for: s)?.dailyChange(on: day) ?? -999 }
            out.sort { ch($0.symbol) > ch($1.symbol) }
        default: break
        }
        return out
    }

    /// The multibagger move now on screen (multibaggers source).
    private var currentEvent: MBEvent? {
        let l = items
        guard l.indices.contains(shown), let k = l[shown].key else { return nil }
        return mbc.events.first { $0.id == k }
    }

    private var columnPredicate: RowPredicate? {
        guard !column.isEmpty, vm.table.index(of: column) != nil else { return nil }
        let ops: [String: RuleOperator] = ["=": .equals, "≠": .notEquals, ">": .greaterThan, "≥": .greaterOrEqual, "<": .lessThan, "≤": .lessOrEqual, "contains": .contains,
                                           "has a value": .hasValue]
        var issues: [String] = []
        return FilterCompiler.compile(FilterCondition(column: column, op: ops[op] ?? .equals, value: value), table: vm.table, issues: &issues)
    }

    // MARK: Body

    var body: some View {
        let list = items
        let current = list.indices.contains(shown) ? list[shown] : nil
        VStack(spacing: 0) {
            sourceBar
            Divider()
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                infoBar(current, count: list.count)
                Divider()
                charts(current).overlay(alignment: .center) {
                    if dragging, list.indices.contains(Int(index)) {
                        let it = list[Int(index)]
                        VStack(spacing: 4) {
                            Text(it.symbol).font(.system(size: 42, weight: .bold, design: .rounded))
                            if !it.note.isEmpty { Text(it.note).font(.title3.monospacedDigit()) }
                            Text("\(Int(index) + 1) / \(list.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                Divider()
                filmstrip(list)
                scrubber(list)
            }
        }
        .navigationTitle(current.map { "Chart Reel — \($0.symbol)" } ?? "Chart Reel")
        .onAppear {
            if column.isEmpty { column = vm.settings.triggerColumn }
            vm.refreshChartLinksIfStale()
            mbc.loadIfNeeded()
            let start = UserDefaults.standard.string(forKey: "reel.mbStart") ?? ""
            UserDefaults.standard.set("", forKey: "reel.mbStart")
            let i = start.isEmpty ? 0 : (list.firstIndex { $0.key == start } ?? 0)
            index = Double(i)
            show(i, list)
        }
        .onChange(of: source) { _ in restart() }
        .onChange(of: column) { _ in restart() }
        .onChange(of: op) { _ in restart() }
        .onChange(of: value) { _ in restart() }
        .onChange(of: alsoFilter) { _ in restart() }
        .onChange(of: sortMode) { _ in restart() }
        .onChange(of: mbMonth) { _ in restart() }
        .onChange(of: fOn) { _ in restart() }
        .onChange(of: mbf.matched) { _ in if fOn { restart() } }
        .onChange(of: mbCenter) { _ in restart() }
        .onChange(of: mbc.events.count) { _ in restart() }
        .onChange(of: vm.gainersDay) { _ in restart() }
        .onChange(of: layout) { _ in phase = 0; show(shown, items) }
        .onChange(of: shown) { _ in lastTV = ""; syncFails = 0; syncNote = nil }
        .onChange(of: jump) { j in
            // after the source / month changes above have reset the list, go to the chosen stock
            DispatchQueue.main.async {
                let key = j.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                UserDefaults.standard.set("", forKey: "reel.mbStart")
                refresh += 1
                let list = items
                let i = key.isEmpty ? 0 : (list.firstIndex { $0.key == key } ?? 0)
                phase = 0
                index = Double(i)
                show(i, list)
            }
        }
        .onReceive(syncTimer) { _ in pollTV(current) }
        .onAppear {
            // delivery chart → TradingView: when you pan / zoom the delivery chart, Chart 1 follows
            deliveryLW.onUserRange = { from, to in
                guard syncDelivery, ReelLayout(rawValue: layout) == .withDelivery,
                      let web = chart1Web(), let f = TVRange.unix(from), let t = TVRange.unix(to) else { return }
                pushedToTVAt = Date()
                TVRange.run(web, TVRange.setBody(from: f, to: t + 86_399)) { r in
                    guard r != "ok" else { return }
                    // no chart controller on this page: centre TradingView on the middle day (Go to date) instead
                    let day = TVRange.day((f + t) / 2)
                    pendingGoTo = day
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard pendingGoTo == day, let w = chart1Web() else { return }
                        pendingGoTo = nil
                        ReelPool.helper.goTo(w, date: day, tries: 2, native: true)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            guard playing, !dragging else { return }
            let isSeq = ReelLayout(rawValue: layout) == .sequence
            let wait = isSeq ? (phase == 0 ? seq1 : seq2) : seconds
            guard Date().timeIntervalSince(lastStep) >= wait else { return }
            if isSeq && phase == 0 { phase = 1; lastStep = Date(); return }
            if shown + 1 < list.count { step(1, list) } else { playing = false }
        }
        .background {
            // keyboard: ← → step, ⇧← ⇧→ jump 10, Home / End
            Group {
                Button("") { step(-1, list) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { step(1, list) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { step(-10, list) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { step(10, list) }.keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("") { playing.toggle(); lastStep = Date() }.keyboardShortcut("p", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var emptyText: String {
        switch ReelSource(rawValue: source) ?? .gainers {
        case .gainers: return "No daily gainers on \(vm.currentGainerDay) at ≥ \(CombiEngine.fmt(vm.settings.gainersThreshold))%.\nPick another day, or fetch Yahoo prices in Daily Gainers."
        case .filter: return "Your Filter shows no stocks."
        case .column: return column.isEmpty || vm.table.index(of: column) == nil ? "Pick a column." : "No stock has \(column) \(op) \(value)."
        case .all: return "No data yet — import the sheet first."
        case .scan: return "Run an Event Scan and press Chart Reel there."
        case .multibaggers: return mbc.events.isEmpty ? "No multibaggers yet — open Multibaggers and download Yahoo history." : "No multibaggers for this month / scope."
        }
    }

    // MARK: Bars

    private var sourceBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $source) {
                ForEach(ReelSource.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            switch ReelSource(rawValue: source) ?? .gainers {
            case .gainers:
                Picker("Day", selection: Binding(get: { vm.currentGainerDay }, set: { vm.gainersDay = $0 })) {
                    ForEach(vm.gainerDays, id: \.self) { d in Text(d).tag(d) }
                    if !vm.gainerDays.contains(vm.currentGainerDay) { Text(vm.currentGainerDay).tag(vm.currentGainerDay) }
                }
                .frame(width: 170)
                Text("≥ \(CombiEngine.fmt(vm.settings.gainersThreshold))%").font(.caption).foregroundStyle(.secondary)
            case .column:
                columnControls
            case .filter:
                Button("Edit Filter…") { openWindow(id: "filter") }
            case .all:
                EmptyView()
            case .scan:
                Button("Event Scan…") { openWindow(id: "eventscan") }
            case .multibaggers:
                Picker("", selection: $mbMonth) {
                    Text("All months").tag("")
                    ForEach(mbc.months, id: \.self) { Text(MBEngine.monthTitle($0)).tag($0) }
                }
                .labelsHidden().frame(width: 120)
                Picker("", selection: $mbCenter) { ForEach(MBCenter.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    .labelsHidden().fixedSize().help("Date both charts jump to (TradingView Go to date)")
                QuickFButton()
                if fOn, mbf.ready { Text("F: \(mbf.matched.count)").font(.caption.bold()).foregroundStyle(Color.accentColor) }
                Button("Multibaggers…") { openWindow(id: "multibaggers") }
            }
            Spacer()
            Picker("", selection: $sortMode) {
                ForEach(["List order", "A → Z", "Day % (high first)"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize().help("Order of the reel")
            Picker("", selection: $layout) {
                ForEach(ReelLayout.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Chart 1 only, Chart 2 only, both (side by side / stacked), 1 → 2: Chart 1 then Chart 2 for each stock, or Chart 1 with the NSE delivery chart under it")
            Menu {
                Toggle("Preload the next charts (faster, uses more memory)", isOn: $preload)
                Divider()
                Toggle("Apply my zoom to every chart after it loads", isOn: $autoZoom)
                Picker("Wait before applying zoom", selection: $zoomDelay) {
                    ForEach([1.5, 2.5, 4.0, 6.0], id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) }
                }
                Toggle("Swap zoom − / + (if they work the wrong way)", isOn: $zoomSwap)
                Divider()
                Button("Chart settings… (in the Chart viewer)") { openWindow(id: "chart") }
                Button("Sign in to TradingView accounts… (in the Chart viewer ⋯ menu)") { openWindow(id: "chart") }
                Button("Reload these charts") { pool.reloadAll() }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var columnControls: some View {
        HStack(spacing: 6) {
            if vm.table.index(of: vm.settings.triggerColumn) != nil {
                Button("\(vm.settings.triggerColumn) = 0") { column = vm.settings.triggerColumn; op = "="; value = "0" }
                Button("\(vm.settings.triggerColumn) = 1") { column = vm.settings.triggerColumn; op = "="; value = "1" }
                Button("\(vm.settings.triggerColumn) has a value") { column = vm.settings.triggerColumn; op = "has a value"; value = "" }
                Divider().frame(height: 16)
            }
            Picker("", selection: $column) {
                Text("Column…").tag("")
                ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: $op) {
                ForEach(["=", "≠", ">", "≥", "<", "≤", "contains", "has a value"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
            if op != "has a value" { TextField("value", text: $value).frame(width: 70).textFieldStyle(.roundedBorder) }
            let options = distinctValues
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { v in Button(v.isEmpty ? "(blank)" : v) { value = v } }
                } label: { Image(systemName: "chevron.down.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("Values in this column")
            }
            Toggle("and my Filter", isOn: $alsoFilter).toggleStyle(.checkbox)
        }
    }

    private var distinctValues: [String] {
        guard let c = vm.table.index(of: column) else { return [] }
        var seen = Set<String>()
        for r in vm.table.rows.prefix(5000) {
            seen.insert(r.text(c).trimmingCharacters(in: .whitespaces))
            if seen.count > 15 { return [] }
        }
        return seen.sorted { (Double($0) ?? .infinity, $0) < (Double($1) ?? .infinity, $1) }
    }

    private func infoBar(_ it: ReelItem?, count: Int) -> some View {
        HStack(spacing: 10) {
            if let it {
                Text(it.symbol).font(.title3.bold())
                if !it.note.isEmpty {
                    Text(it.note).font(.headline.monospacedDigit())
                        .foregroundStyle(it.note.hasPrefix("+") ? Color.green : (it.note.hasPrefix("-") ? Color.red : Color.primary))
                }
                if let r = it.row, let n = vm.companyNameIndex { Text(r.text(n)).foregroundStyle(.secondary).lineLimit(1) }
                if let r = it.row, let s = vm.sectorColumnIndex {
                    let sec = r.text(s)
                    Text(sec).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let rot = vm.sectorRotation(sec, day: it.day ?? vm.currentGainerDay) {
                        Text(ScreenerViewModel.quadrantLabel(rot.quadrant)).font(.caption)
                    }
                }
                if let r = it.row, let t = vm.table.index(of: vm.settings.triggerColumn) {
                    Text("\(vm.settings.triggerColumn) \(r.text(t))").font(.caption.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if let g = it.gainer, let day = it.day {
                    let grade = vm.pickGrade(g.symbol, day: day)
                    Button { vm.cyclePick(g, day: day); refresh += 1 } label: {
                        Text("P").font(.headline).frame(width: 22)
                            .foregroundStyle(grade == .pick ? Color.green : (grade == .ok ? Color.orange : Color.secondary))
                    }
                    .help("My pick: grey → green → orange (⌘K)")
                    .keyboardShortcut("k", modifiers: .command)
                }
                if ReelLayout(rawValue: layout) == .withDelivery {
                    Toggle("🔗 Sync", isOn: $syncDelivery).toggleStyle(.button)
                        .help("Keep the delivery chart on the same dates as Chart 1 — and move Chart 1 when you pan / zoom the delivery chart")
                }
                Button { vm.openChart(it.symbol, queue: items.map(\.symbol), openWindow: openWindow) } label: { Label("Chart viewer", systemImage: "arrow.up.forward.app") }
                    .help("Open this stock in the Chart viewer (snapshots, annotate, sign in)")
            }
            Text("\(shown + 1) / \(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    // MARK: Charts

    @ViewBuilder private func charts(_ it: ReelItem?) -> some View {
        let l = ReelLayout(rawValue: layout) ?? .chart1
        if let it {
            switch l {
            case .chart1: chartPane(it, 0)
            case .chart2: chartPane(it, 1)
            case .side: HSplitView { chartPane(it, 0); chartPane(it, 1) }
            case .stacked: VSplitView { chartPane(it, 0); chartPane(it, 1) }
            case .sequence: chartPane(it, phase)
            case .withDelivery:
                VSplitView {
                    chartPane(it, 0).frame(minHeight: 250)
                    DeliveryMiniChart(symbol: it.symbol, lw: deliveryLW, syncNote: syncDelivery ? syncNote : nil, focus: it.goTo)
                        .frame(minHeight: 110, idealHeight: 230)
                }
            }
        } else {
            Color.clear
        }
    }

    private func chartPane(_ it: ReelItem, _ c: Int) -> some View {
        let symbol = it.symbol
        let col = min(c, vm.chartCount - 1)
        return VStack(spacing: 0) {
            if let u = vm.chartURL(symbol, column: col) {
                ReelWebView(web: pool.view(for: u, slot: c, goTo: it.goTo))
                    .overlay(alignment: .topTrailing) { zoomBar(c, goTo: it.goTo) }
                    .overlay(alignment: .bottomLeading) {
                        if let g = it.goTo {
                            Text("📅 \(g)").font(.caption.monospacedDigit().bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule()).padding(6)
                        }
                    }
            } else {
                Text("No chart link for \(symbol)").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if c == 1 && vm.chartCount < 2 {
                Text("No Chart 2 yet — add a Link2 column to your chart sheet").font(.caption2).foregroundStyle(.orange).padding(2)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    /// Per-chart zoom, remembered and re-applied to every stock's chart after it loads.
    private func zoomBar(_ c: Int, goTo: String?) -> some View {
        _ = zoomTick
        let steps = ReelPool.zoomSteps(c)
        let page = ReelPool.pageZoom(c)
        return HStack(spacing: 4) {
            Text("Chart \(c + 1)").font(.caption2.bold())
            Divider().frame(height: 12)
            Button { pool.nudge(slot: c, by: -1); zoomTick += 1 } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Show more bars (zoom out the time axis) — remembered for every Chart \(c + 1)")
            Text(steps == 0 ? "0" : String(format: "%+d", steps)).font(.caption2.monospacedDigit()).frame(minWidth: 18)
            Button { pool.nudge(slot: c, by: 1); zoomTick += 1 } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Show fewer, wider bars (zoom in the time axis) — remembered for every Chart \(c + 1)")
            Button { pool.resetZoom(slot: c); zoomTick += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Back to the layout's own zoom (reloads this chart)")
            if let g = goTo {
                Divider().frame(height: 12)
                Button { pool.goToAgain(slot: c, date: g) } label: { Image(systemName: "calendar") }
                    .help("Jump this chart to \(g) again (TradingView Go to date). If it doesn't move: click the chart, press ⌥G and paste — the date is copied.")
            }
            Divider().frame(height: 12)
            Button { pool.signIn(slot: c) } label: { Image(systemName: "person.crop.circle") }
                .help("Sign in to TradingView here — \(TVAccounts.name(TVAccounts.account(forChart: c))) (Google pop-ups open in their own window)")
            Divider().frame(height: 12)
            Button { pool.setPageZoom(slot: c, page - 0.1); zoomTick += 1 } label: { Text("A−").font(.caption2) }
                .help("Smaller page (more chart fits)")
            Text("\(Int((page * 100).rounded()))%").font(.caption2.monospacedDigit())
            Button { pool.setPageZoom(slot: c, page + 0.1); zoomTick += 1 } label: { Text("A+").font(.caption2) }
                .help("Bigger page")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
        .opacity(0.92)
    }

    // MARK: Scrubbing

    private func filmstrip(_ list: [ReelItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, it in
                        Button { index = Double(i); show(i, list) } label: {
                            VStack(spacing: 1) {
                                Text(it.symbol).font(.caption.bold()).lineLimit(1)
                                if !it.note.isEmpty { Text(it.note).font(.caption2.monospacedDigit()).lineLimit(1) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(i == shown ? Color.accentColor.opacity(0.35) : (i == Int(index) && dragging ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)),
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .frame(height: 40)
            .onChange(of: Int(index)) { i in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) } }
        }
    }

    private func scrubber(_ list: [ReelItem]) -> some View {
        HStack(spacing: 8) {
            Button { step(-1, list) } label: { Image(systemName: "chevron.left") }.disabled(shown == 0).help("Previous (←)")
            Button { playing.toggle(); lastStep = Date() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .help("Autoplay (⌘P)")
            if ReelLayout(rawValue: layout) == .sequence {
                Text("Chart 1").font(.caption).foregroundStyle(phase == 0 ? Color.accentColor : Color.secondary)
                Picker("", selection: $seq1) { ForEach(Self.speeds, id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) } }
                    .labelsHidden().fixedSize().help("Seconds on Chart 1 for every stock")
                Text("→ Chart 2").font(.caption).foregroundStyle(phase == 1 ? Color.accentColor : Color.secondary)
                Picker("", selection: $seq2) { ForEach(Self.speeds, id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) } }
                    .labelsHidden().fixedSize().help("Then seconds on Chart 2, then the next stock")
            } else {
                Picker("", selection: $seconds) {
                    ForEach(Self.speeds, id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) }
                }
                .labelsHidden().fixedSize().help("Seconds per chart in autoplay")
            }
            Slider(value: $index, in: 0...Double(max(1, list.count - 1)), step: 1) { editing in
                dragging = editing
                if !editing { show(Int(index), list) }
            }
            .disabled(list.count < 2)
            .onChange(of: index) { v in
                // keep loading while the slider rests briefly mid-drag (or after clicks on the track)
                settle?.cancel()
                let w = DispatchWorkItem { if Int(v) != shown { show(Int(v), list) } }
                settle = w
                DispatchQueue.main.asyncAfter(deadline: .now() + (dragging ? 0.35 : 0.05), execute: w)
            }
            Button { step(1, list) } label: { Image(systemName: "chevron.right") }.disabled(shown >= list.count - 1).help("Next (→)")
            Text("⇧← ⇧→ jump 10").font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    static let speeds: [Double] = [1, 1.5, 2, 3, 4, 5, 8, 12]

    // MARK: Sync (Chart 1 ↔ delivery chart)

    private func chart1Web() -> WKWebView? {
        let list = items
        guard list.indices.contains(shown), let u = vm.chartURL(list[shown].symbol, column: 0) else { return nil }
        return pool.view(for: u, slot: 0, goTo: list[shown].goTo)
    }

    /// TradingView → delivery chart: follow Chart 1's visible dates.
    private func pollTV(_ it: ReelItem?) {
        guard syncDelivery, ReelLayout(rawValue: layout) == .withDelivery, it != nil, !dragging,
              Date().timeIntervalSince(pushedToTVAt) > 0.8, syncFails < 25,
              let web = chart1Web(), !web.isLoading else { return }
        TVRange.run(web, TVRange.getBody) { r in
            let parts = r.split(separator: ",").compactMap { Int($0) }
            guard parts.count >= 2 else {
                syncFails += 1
                syncNote = syncFails >= 25 ? "Sync: TradingView doesn't expose its chart here — panning the delivery chart still re-centres Chart 1"
                                           : "Sync: waiting for TradingView…"
                return
            }
            syncFails = 0
            syncNote = "🔗 synced"
            guard r != lastTV else { return }
            lastTV = r
            _ = deliveryLW.follow(tvResult: r)
        }
    }

    private func step(_ d: Int, _ list: [ReelItem]) {
        guard !list.isEmpty else { return }
        if ReelLayout(rawValue: layout) == .sequence {
            if d == 1 && phase == 0 { phase = 1; lastStep = Date(); return }      // → : Chart 2 of the same stock first
            if d == -1 && phase == 1 { phase = 0; lastStep = Date(); return }
        }
        phase = 0
        let i = max(0, min(list.count - 1, shown + d))
        index = Double(i)
        show(i, list)
        lastStep = Date()
    }

    private func restart() {
        index = 0
        refresh += 1
        show(0, items)
    }

    /// Loads the charts for item `i` and, if on, preloads the next two (and the previous one).
    private func show(_ i: Int, _ list: [ReelItem]) {
        guard list.indices.contains(i) else { shown = 0; return }
        shown = i
        guard preload else { return }
        let l = ReelLayout(rawValue: layout) ?? .chart1
        let cols: [Int] = l == .chart1 || l == .withDelivery ? [0] : (l == .chart2 ? [1] : [0, 1])
        var urls: [(URL, Int, String?)] = []
        for j in [i, i + 1, i + 2, i - 1] where list.indices.contains(j) {
            for c in cols { if let u = vm.chartURL(list[j].symbol, column: min(c, vm.chartCount - 1)) { urls.append((u, c, list[j].goTo)) } }
        }
        pool.preload(urls, keep: cols.count * 4)
    }
}

// MARK: - Model bits

enum ReelSource: String, CaseIterable, Identifiable {
    case gainers = "Daily gainers", column = "Column filter", filter = "My Filter", all = "All stocks", multibaggers = "Multibaggers", scan = "Event scan"
    var id: String { rawValue }
}

enum ReelLayout: String, CaseIterable, Identifiable {
    case chart1 = "Chart 1", chart2 = "Chart 2", side = "Both ⇆", stacked = "Both ⇅", sequence = "1 → 2", withDelivery = "1 + Delivery"
    var id: String { rawValue }
}

struct ReelItem {
    let symbol: String
    let note: String
    var row: SheetRow? = nil
    var gainer: GainerRow? = nil
    var day: String? = nil
    var goTo: String? = nil        // TradingView "Go to date" after the chart loads (yyyy-MM-dd)
    var key: String? = nil         // unique id when a stock appears more than once (multibagger months)
}

/// Keeps a few loaded chart pages so stepping back and forth is instant, and re-applies your remembered
/// zoom (time-axis wheel steps + page size) to each chart after it loads.
final class ReelPool: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// For "Go to date" on web views it doesn't own (the Chart viewer).
    static let helper = ReelPool()
    private var popups: [(window: NSWindow, web: WKWebView, slot: Int)] = []
    private var views: [String: WKWebView] = [:]
    private var slots: [String: Int] = [:]    // key → chart (0 = Chart 1, 1 = Chart 2)
    private var gotos: [String: String] = [:] // key → date to jump to after loading
    private var order: [String] = []          // most recent last
    private var keep = 6

    // Remembered per chart
    static func zoomSteps(_ slot: Int) -> Int { UserDefaults.standard.integer(forKey: "reel.zoomSteps.\(slot)") }
    static func pageZoom(_ slot: Int) -> Double {
        let v = UserDefaults.standard.double(forKey: "reel.pageZoom.\(slot)")
        return v == 0 ? 1 : v
    }
    private var autoZoom: Bool { UserDefaults.standard.object(forKey: "reel.autoZoom") as? Bool ?? true }
    private var delay: Double { let d = UserDefaults.standard.double(forKey: "reel.zoomDelay"); return d == 0 ? 2.5 : d }
    private var swap: Bool { UserDefaults.standard.bool(forKey: "reel.zoomSwap") }

    private static func key(_ url: URL, _ goTo: String?) -> String { url.absoluteString + (goTo.map { "#goto=" + $0 } ?? "") }

    private func make(_ url: URL, slot: Int, key: String, goTo: String?) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = TVAccounts.store(TVAccounts.account(forChart: slot))   // Chart 1 → Account 1, Chart 2 → Account 2
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        v.customUserAgent = WebHolder.userAgent
        v.pageZoom = Self.pageZoom(slot)
        v.navigationDelegate = self
        v.uiDelegate = self
        slots[key] = slot
        gotos[key] = goTo
        v.load(URLRequest(url: url))
        return v
    }

    func view(for url: URL, slot: Int, goTo: String? = nil) -> WKWebView {
        let key = Self.key(url, goTo)
        if let v = views[key] { touch(key); return v }
        let v = make(url, slot: slot, key: key, goTo: goTo)
        views[key] = v
        touch(key)
        trim()
        return v
    }

    func preload(_ urls: [(URL, Int, String?)], keep: Int) {
        self.keep = max(4, keep + 2)
        for (u, slot, g) in urls {
            let key = Self.key(u, g)
            guard views[key] == nil else { continue }
            views[key] = make(u, slot: slot, key: key, goTo: g)
            touch(key)
        }
        trim()
    }

    func reloadAll() { views.values.forEach { $0.reload() } }

    // MARK: Sign-in (Google / Apple pop-ups)

    /// Opens TradingView's sign-in page in the pane showing this chart (its own account).
    func signIn(slot: Int) {
        guard let entry = views.first(where: { slots[$0.key] == slot && $0.value.superview != nil }),
              let u = URL(string: "https://in.tradingview.com/accounts/signin/") else { return }
        entry.value.load(URLRequest(url: u))
    }

    private func slot(of web: WKWebView) -> Int {
        if let k = views.first(where: { $0.value === web })?.key { return slots[k] ?? 0 }
        return popups.first(where: { $0.web === web })?.slot ?? 0
    }

    // window.open(...) → a real window sharing that account's cookies, so the login flows back to the chart
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let slot = slot(of: webView)
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = WebHolder.userAgent
        popup.uiDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in — \(TVAccounts.name(TVAccounts.account(forChart: slot)))"
        w.contentView = popup
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append((w, popup, slot))
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let i = popups.firstIndex(where: { $0.web === webView }) else { return }
        let slot = popups[i].slot
        popups[i].window.close()
        popups.remove(at: i)
        for (k, v) in views where slots[k] == slot { v.reload() }       // pick up the new login
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    // MARK: Zoom

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let key = views.first(where: { $0.value === webView })?.key else { return }
        let steps = autoZoom ? Self.zoomSteps(slots[key] ?? 0) : 0
        let date = gotos[key]
        guard steps != 0 || date != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
            guard let self, let webView else { return }
            if steps != 0 { self.wheel(webView, steps: steps, tries: 4) }
            if let date {
                DispatchQueue.main.asyncAfter(deadline: .now() + (steps != 0 ? 1.0 : 0)) { self.goTo(webView, date: date, tries: 3) }
            }
        }
    }

    // MARK: Go to date

    /// Jumps the chart to `date` with TradingView's own "Go to" dialog (⌥G): opens it, types the date, presses Go to.
    /// Works by scripting TradingView's page, so it can break if TradingView changes its page.
    func goTo(_ web: WKWebView, date: String, tries: Int, native: Bool = false) {
        if native, let w = web.window {
            w.makeFirstResponder(web)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.option], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: "©", charactersIgnoringModifiers: "g",
                                            isARepeat: false, keyCode: 5) {
                    if type == .keyDown { web.keyDown(with: e) } else { web.keyUp(with: e) }
                }
            }
        }
        let open = native ? "'native'" : """
        (function(){
          function vis(e){ var r=e.getBoundingClientRect(); return r.width>0 && r.height>0; }
          var ins=[].slice.call(document.querySelectorAll('input')).filter(vis);
          if (ins.some(function(i){ return /^\\d{4}-\\d{2}-\\d{2}$/.test(i.value); })) return 'open';
          var b=document.querySelector('[data-name="go-to-date"]');
          if (b && vis(b)) { b.click(); return 'clicked'; }
          var o={key:'g', code:'KeyG', keyCode:71, which:71, altKey:true, bubbles:true, cancelable:true};
          (document.activeElement || document.body).dispatchEvent(new KeyboardEvent('keydown', o));
          document.dispatchEvent(new KeyboardEvent('keyup', o));
          return 'key';
        })()
        """
        web.evaluateJavaScript(open) { [weak self, weak web] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let self, let web else { return }
                self.fill(web, date: date) { result in
                    if result == "noinput" && tries > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.goTo(web, date: date, tries: tries - 1, native: web.window != nil && !native)
                        }
                    }
                }
            }
        }
    }

    private func fill(_ web: WKWebView, date: String, done: @escaping (String) -> Void) {
        let js = """
        (function(d){
          function vis(e){ var r=e.getBoundingClientRect(); return r.width>0 && r.height>0; }
          var ins=[].slice.call(document.querySelectorAll('input')).filter(vis);
          var inp=ins.find(function(i){ return /^\\d{4}-\\d{2}-\\d{2}$/.test(i.value); })
               || ins.find(function(i){ return /yyyy/i.test(i.placeholder||''); });
          if (!inp) return 'noinput';
          var set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
          inp.focus(); set.call(inp, d);
          inp.dispatchEvent(new Event('input',{bubbles:true}));
          inp.dispatchEvent(new Event('change',{bubbles:true}));
          var root=inp.closest('[role="dialog"],[data-name*="dialog"],[class*="dialog"]') || document;
          var btns=[].slice.call(root.querySelectorAll('button')).filter(vis);
          var go=btns.find(function(b){ return /^\\s*go\\s*to\\s*$/i.test(b.textContent); }) || root.querySelector('[data-name="submit-button"]');
          if (go) { setTimeout(function(){ go.click(); }, 200); return 'done'; }
          ['keydown','keyup'].forEach(function(t){ inp.dispatchEvent(new KeyboardEvent(t,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true})); });
          return 'enter';
        })('\(date)')
        """
        web.evaluateJavaScript(js) { r, _ in done((r as? String) ?? "error") }
    }

    /// Re-runs Go to date on the chart on screen (and copies the date, for ⌥G + paste by hand).
    func goToAgain(slot: Int, date: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(date, forType: .string)
        for (k, v) in views where slots[k] == slot && v.superview != nil { goTo(v, date: date, tries: 2, native: true) }
    }

    /// Turns the mouse wheel `steps` times over the chart (+ = zoom in). Retries while the chart is still drawing.
    private func wheel(_ web: WKWebView, steps: Int, tries: Int) {
        let s = swap ? -steps : steps
        let js = """
        (function(n){
          var best=null, area=0;
          document.querySelectorAll('canvas').forEach(function(c){
            var r=c.getBoundingClientRect(); var a=r.width*r.height; if(a>area){area=a; best=c;} });
          if(!best || area < 40000) return 'wait';
          var r=best.getBoundingClientRect(); var x=r.left+r.width*0.7, y=r.top+r.height*0.5;
          for(var i=0;i<Math.abs(n);i++){
            best.dispatchEvent(new WheelEvent('wheel',{deltaY:(n>0?-100:100), deltaMode:0, clientX:x, clientY:y, bubbles:true, cancelable:true, view:window}));
          }
          return 'ok';
        })(\(s))
        """
        web.evaluateJavaScript(js) { [weak self, weak web] result, _ in
            guard let self, let web, (result as? String) == "wait", tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.wheel(web, steps: steps, tries: tries - 1) }
        }
    }

    /// One more / fewer zoom step: applied now to that chart's pages on screen and remembered for the rest.
    func nudge(slot: Int, by d: Int) {
        UserDefaults.standard.set(Self.zoomSteps(slot) + d, forKey: "reel.zoomSteps.\(slot)")
        for (k, v) in views where slots[k] == slot { wheel(v, steps: d, tries: 0) }
    }

    /// Forget the zoom for this chart and reload its pages (back to the layout's own zoom).
    func resetZoom(slot: Int) {
        UserDefaults.standard.set(0, forKey: "reel.zoomSteps.\(slot)")
        for (k, v) in views where slots[k] == slot { v.reload() }
    }

    func setPageZoom(slot: Int, _ z: Double) {
        let v = max(0.5, min(1.6, (z * 10).rounded() / 10))
        UserDefaults.standard.set(v, forKey: "reel.pageZoom.\(slot)")
        for (k, w) in views where slots[k] == slot { w.pageZoom = v }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func trim() {
        var i = 0
        while order.count > keep && i < order.count {
            let k = order[i]
            if let v = views[k], v.superview != nil { i += 1; continue }     // on screen: keep
            views[k]?.stopLoading()
            views[k] = nil
            slots[k] = nil
            gotos[k] = nil
            order.remove(at: i)
        }
    }
}

/// Shows whichever pooled web view is current (swapped in without reloading).
struct ReelWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> NSView { let v = NSView(); attach(web, to: v); return v }
    func updateNSView(_ v: NSView, context: Context) {
        if v.subviews.first !== web { attach(web, to: v) }
    }
    private func attach(_ web: WKWebView, to v: NSView) {
        v.subviews.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: v.leadingAnchor), web.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            web.topAnchor.constraint(equalTo: v.topAnchor), web.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
    }
}

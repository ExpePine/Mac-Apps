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

    @AppStorage("reel.source") private var source = ReelSource.gainers.rawValue
    @AppStorage("reel.column") private var column = ""
    @AppStorage("reel.op") private var op = "="
    @AppStorage("reel.value") private var value = "1"
    @AppStorage("reel.alsoFilter") private var alsoFilter = false
    @AppStorage("reel.layout") private var layout = ReelLayout.chart1.rawValue
    @AppStorage("reel.preload") private var preload = true
    @AppStorage("reel.seconds") private var seconds = 3.0
    @AppStorage("reel.sort") private var sortMode = "List order"

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
        }
        var seen = Set<String>()
        out = out.filter { !$0.symbol.isEmpty && seen.insert($0.symbol).inserted }
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

    private var columnPredicate: RowPredicate? {
        guard !column.isEmpty, vm.table.index(of: column) != nil else { return nil }
        let ops: [String: RuleOperator] = ["=": .equals, "≠": .notEquals, ">": .greaterThan, "≥": .greaterOrEqual, "<": .lessThan, "≤": .lessOrEqual, "contains": .contains]
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
        .onAppear { if column.isEmpty { column = vm.settings.triggerColumn }; vm.refreshChartLinksIfStale(); show(0, list) }
        .onChange(of: source) { _ in restart() }
        .onChange(of: column) { _ in restart() }
        .onChange(of: op) { _ in restart() }
        .onChange(of: value) { _ in restart() }
        .onChange(of: alsoFilter) { _ in restart() }
        .onChange(of: sortMode) { _ in restart() }
        .onChange(of: vm.gainersDay) { _ in restart() }
        .onChange(of: layout) { _ in show(shown, items) }
        .onReceive(timer) { _ in
            guard playing, !dragging, Date().timeIntervalSince(lastStep) >= seconds else { return }
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
            .help("Chart 1 only, Chart 2 only, or both (side by side / stacked)")
            Menu {
                Toggle("Preload the next charts (faster, uses more memory)", isOn: $preload)
                Divider()
                Button("Chart settings… (in the Chart viewer)") { openWindow(id: "chart") }
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
                Divider().frame(height: 16)
            }
            Picker("", selection: $column) {
                Text("Column…").tag("")
                ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: $op) {
                ForEach(["=", "≠", ">", "≥", "<", "≤", "contains"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
            TextField("value", text: $value).frame(width: 70).textFieldStyle(.roundedBorder)
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
            case .chart1: chartPane(it.symbol, 0)
            case .chart2: chartPane(it.symbol, 1)
            case .side: HSplitView { chartPane(it.symbol, 0); chartPane(it.symbol, 1) }
            case .stacked: VSplitView { chartPane(it.symbol, 0); chartPane(it.symbol, 1) }
            }
        } else {
            Color.clear
        }
    }

    private func chartPane(_ symbol: String, _ c: Int) -> some View {
        let col = min(c, vm.chartCount - 1)
        return VStack(spacing: 0) {
            if let u = vm.chartURL(symbol, column: col) {
                ReelWebView(web: pool.view(for: u))
            } else {
                Text("No chart link for \(symbol)").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if c == 1 && vm.chartCount < 2 {
                Text("No Chart 2 yet — add a Link2 column to your chart sheet").font(.caption2).foregroundStyle(.orange).padding(2)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
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
            Picker("", selection: $seconds) {
                ForEach([1.5, 2, 3, 5, 8], id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) }
            }
            .labelsHidden().fixedSize().help("Seconds per chart in autoplay")
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

    private func step(_ d: Int, _ list: [ReelItem]) {
        guard !list.isEmpty else { return }
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
        let cols: [Int] = l == .chart1 ? [0] : (l == .chart2 ? [1] : [0, 1])
        var urls: [URL] = []
        for j in [i + 1, i + 2, i - 1] where list.indices.contains(j) {
            for c in cols { if let u = vm.chartURL(list[j].symbol, column: min(c, vm.chartCount - 1)) { urls.append(u) } }
        }
        pool.preload(urls, keep: cols.count * 4)
    }
}

// MARK: - Model bits

enum ReelSource: String, CaseIterable, Identifiable {
    case gainers = "Daily gainers", column = "Column filter", filter = "My Filter", all = "All stocks"
    var id: String { rawValue }
}

enum ReelLayout: String, CaseIterable, Identifiable {
    case chart1 = "Chart 1", chart2 = "Chart 2", side = "Both ⇆", stacked = "Both ⇅"
    var id: String { rawValue }
}

struct ReelItem {
    let symbol: String
    let note: String
    var row: SheetRow? = nil
    var gainer: GainerRow? = nil
    var day: String? = nil
}

/// Keeps a few loaded chart pages (most recent first) so stepping back and forth is instant.
@MainActor final class ReelPool: ObservableObject {
    private var views: [String: WKWebView] = [:]
    private var order: [String] = []          // most recent last
    private var keep = 6

    private func make(_ url: URL) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()     // same sign-in as the Chart viewer
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        v.customUserAgent = WebHolder.userAgent
        v.load(URLRequest(url: url))
        return v
    }

    func view(for url: URL) -> WKWebView {
        let key = url.absoluteString
        if let v = views[key] { touch(key); return v }
        let v = make(url)
        views[key] = v
        touch(key)
        trim()
        return v
    }

    func preload(_ urls: [URL], keep: Int) {
        self.keep = max(4, keep + 2)
        for u in urls where views[u.absoluteString] == nil {
            views[u.absoluteString] = make(u)
            touch(u.absoluteString)
        }
        trim()
    }

    func reloadAll() { views.values.forEach { $0.reload() } }

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

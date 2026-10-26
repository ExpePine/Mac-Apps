import SwiftUI
import Charts

/// Multibaggers: every stock that gained ≥ 30% (your threshold) in a calendar month since Jan 2023,
/// month by month — and a one-click Chart Reel of them with both charts jumped to the move's date.
struct MultibaggerView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var mb = MultibaggerCenter.shared

    @AppStorage("mb.threshold") private var threshold = 30.0
    @AppStorage("mb.from") private var fromMonth = "2023-01"
    @AppStorage("mb.usePeak") private var usePeak = false
    @AppStorage("mb.center") private var centerRaw = MBCenter.start.rawValue
    @AppStorage("mb.scope") private var scope = "Sheet stocks"

    @State private var month: String?          // nil = all months
    @State private var showF = false
    @AppStorage("mb.fOn") private var fOn = false
    @ObservedObject private var mbf = MBFilterCenter.shared
    @State private var selection: MBEvent.ID?
    @State private var search = ""

    private var shown: [MBEvent] {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        var e = scoped
        if let m = month { e = e.filter { $0.month == m } }
        if !q.isEmpty { e = e.filter { $0.symbol.contains(q) } }
        if fOn, mbf.ready { e = e.filter { mbf.matched.contains($0.id) } }
        return e
    }

    private var scoped: [MBEvent] {
        var e = mb.events
        if scope == "Sheet stocks" { let s = Set(vm.allSymbols.map { $0.uppercased() }); e = e.filter { s.contains($0.symbol) } }
        if scope == "My Filter", let l = vm.labelIndex {
            let s = Set(vm.filterRows.map { $0.text(l).trimmingCharacters(in: .whitespaces).uppercased() }); e = e.filter { s.contains($0.symbol) }
        }
        return e
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mb.book.series.isEmpty && !mb.isFetching {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Multibaggers").font(.title2.bold())
                    Text("Downloads ~5 years of Yahoo daily closes for your sheet's \(vm.allSymbols.count) stocks, then lists every stock that gained ≥ \(CombiEngine.fmt(threshold))% in a calendar month from \(MBEngine.monthTitle(fromMonth)) to now. Open them in the Chart Reel with both charts jumped to the move.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 620)
                    Button("Download Yahoo history") { mb.fetch(vm.allSymbols) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    monthList.frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
                    eventTable.frame(minWidth: 620)
                }
            }
        }
        .navigationTitle("Multibaggers")
        .onAppear { mb.loadIfNeeded() }
        .onChange(of: threshold) { _ in mb.recompute() }
        .onChange(of: fromMonth) { _ in mb.recompute() }
        .onChange(of: usePeak) { _ in mb.recompute() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Multibagger = gain ≥").font(.caption)
                TextField("", value: $threshold, format: .number).frame(width: 44).multilineTextAlignment(.trailing)
                Text("% in a calendar month, from").font(.caption)
                Picker("", selection: $fromMonth) {
                    ForEach(["2023-01", "2023-07", "2024-01", "2024-07", "2025-01", "2025-07", "2026-01"], id: \.self) { Text(MBEngine.monthTitle($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                Picker("", selection: $usePeak) {
                    Text("month-end close").tag(false)
                    Text("best close in the month").tag(true)
                }
                .labelsHidden().fixedSize()
                .help("Gain vs the previous month's last close: at the month's last close, or at its highest close")
                Spacer()
                if mb.isFetching {
                    ProgressView(value: Double(mb.progress.done), total: Double(max(1, mb.progress.total))).frame(width: 140)
                    Button("Stop") { mb.cancel() }
                } else {
                    Button { mb.fetch(vm.allSymbols) } label: { Label(mb.book.series.isEmpty ? "Download Yahoo history" : "Update Yahoo", systemImage: "arrow.down.circle") }
                        .help("First time: 5 years per stock. Later: only the last 3 months, merged into what's stored.")
                }
            }
            HStack(spacing: 10) {
                Picker("", selection: $scope) { ForEach(["Sheet stocks", "My Filter", "All downloaded"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("Chart centre:").font(.caption)
                Picker("", selection: $centerRaw) { ForEach(MBCenter.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    .labelsHidden().fixedSize()
                    .help("The date the Chart Reel jumps both TradingView charts to (TradingView's Go to date)")
                SymbolField(vm: vm, placeholder: "Search", text: $search).frame(width: 120)
                Button { showF.toggle() } label: { FBadge(on: fOn) }
                .buttonStyle(.plain)
                .help("F: pick Filter combinations checked on each stock's data just BEFORE its multibagger month — saved combinations are kept (⌥⌘F)")
                .popover(isPresented: $showF, arrowEdge: .bottom) { MBFPanel(event: scoped.first { $0.id == selection }, on: $fOn).environmentObject(vm) }
                if fOn, mbf.ready { Text("F\(mbf.activeName.map { " " + $0 } ?? ""): \(mbf.matched.count) matched").font(.caption.bold()).foregroundStyle(Color.accentColor) }
                Spacer()
                if let s = mb.status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Menu {
                    Button("Both charts side by side") { openReel(start: nil, layout: .side) }
                    Button("Chart 1 + Delivery chart") { openReel(start: nil, layout: .withDelivery) }
                    Button("Chart 1 → Chart 2") { openReel(start: nil, layout: .sequence) }
                } label: { Label("Chart Reel", systemImage: "film.stack") } primaryAction: { openReel(start: nil) }
                    .fixedSize()
                    .disabled(shown.isEmpty)
                    .help("Flick through these multibaggers, jumped to the move's date — click for your last layout, or pick: both charts, Chart 1 + Delivery chart, Chart 1 → Chart 2")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var monthList: some View {
        let counts = Dictionary(grouping: scoped, by: \.month).mapValues(\.count)
        let months = counts.keys.sorted(by: >)
        return VStack(spacing: 0) {
            Chart {
                ForEach(months.reversed(), id: \.self) { m in
                    BarMark(x: .value("Month", MBEngine.monthTitle(m)), y: .value("Count", counts[m] ?? 0))
                        .foregroundStyle(m == month ? Color.accentColor : Color.green.opacity(0.6))
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 70).padding(8)
            List(selection: $month) {
                Text("All months (\(counts.values.reduce(0, +)))").tag(String?.none)
                ForEach(months, id: \.self) { m in
                    HStack {
                        Text(MBEngine.monthTitle(m))
                        Spacer()
                        Text("\(counts[m] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(String?.some(m))
                }
            }
        }
    }

    private var eventTable: some View {
        let rows = shown
        return VStack(spacing: 0) {
            HStack {
                Text("\(rows.count) multibagger\(rows.count == 1 ? "" : "s")\(month.map { " in " + MBEngine.monthTitle($0) } ?? "")").font(.caption.bold())
                Spacer()
                Text("Double-click: Chart Reel from that stock").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Table(rows, selection: $selection) {
                TableColumn("Symbol") { e in SymbolWithDots(symbol: e.symbol) }.width(min: 110, ideal: 130)
                TableColumn("Month") { e in Text(e.monthTitle) }.width(min: 60, ideal: 70)
                TableColumn("Gain") { e in Text(String(format: "%+.0f%%", e.gain)).monospacedDigit().foregroundStyle(.green) }.width(min: 50, ideal: 60)
                TableColumn("Best in month") { e in Text(String(format: "%+.0f%%", e.peakGain)).monospacedDigit() }.width(min: 70, ideal: 80)
                TableColumn("Start") { e in Text(e.startDay).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Crossed \(CombiEngine.fmt(threshold))%") { e in Text(e.crossDay).monospacedDigit() }.width(min: 80, ideal: 95)
                TableColumn("Peak") { e in Text(e.peakDay).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Chart goes to") { e in Text(e.day(for: MBCenter(rawValue: centerRaw) ?? .start)).monospacedDigit().foregroundStyle(.orange) }.width(min: 80, ideal: 95)
            }
            .contextMenu(forSelectionType: MBEvent.ID.self) { ids in
                if let id = ids.first, let e = rows.first(where: { $0.id == id }) {
                    Button("Chart Reel from \(e.symbol)") { openReel(start: e.id) }
                    Button("Chart Reel (Chart 1 + Delivery) from \(e.symbol)") { openReel(start: e.id, layout: .withDelivery) }
                    Button("Copy date \(e.day(for: MBCenter(rawValue: centerRaw) ?? .start))") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.day(for: MBCenter(rawValue: centerRaw) ?? .start), forType: .string)
                    }
                }
            } primaryAction: { ids in openReel(start: ids.first) }
        }
    }

    /// Hands the current list to the Chart Reel (both charts) and opens it.
    private func openReel(start: MBEvent.ID?, layout: ReelLayout? = nil) {
        let d = UserDefaults.standard
        d.set(ReelSource.multibaggers.rawValue, forKey: "reel.source")
        d.set(month ?? "", forKey: "reel.mbMonth")
        d.set(scope, forKey: "reel.mbScope")
        d.set(start ?? "", forKey: "reel.mbStart")
        d.set(UUID().uuidString + "|" + (start ?? ""), forKey: "reel.jump")      // tells an already-open reel to move
        let l = ReelLayout(rawValue: d.string(forKey: "reel.layout") ?? "") ?? .chart1
        if let layout { d.set(layout.rawValue, forKey: "reel.layout") }
        else if l == .chart1 || l == .chart2 { d.set(ReelLayout.side.rawValue, forKey: "reel.layout") }
        openWindow(id: "reel")
    }
}


// MARK: - F: which Filter combinations came before a multibagger?

/// Checks a Filter-style combination on each multibagger's stored snapshot from just before its month
/// (the last stored day on or before the base day) and, for the same days, on every other stock — giving
/// how many multibaggers it caught and how often a match turned into one (hit rate).
@MainActor final class MBFilterCenter: ObservableObject {
    static let shared = MBFilterCenter()
    @Published var group: FilterGroup = (UserDefaults.standard.data(forKey: "mb.fGroup").flatMap { try? JSONDecoder().decode(FilterGroup.self, from: $0) }) ?? FilterGroup(mode: .all) {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(group), forKey: "mb.fGroup") }
    }
    @Published private(set) var matched: Set<String> = []        // event ids
    @Published private(set) var ready = false
    @Published private(set) var running = false
    @Published private(set) var summary = ""
    @Published private(set) var issues: [String] = []
    /// Saved combinations — view, rename, edit, run and delete them in the F panel, the reel or ⌥⌘F.
    @Published var combos: [MBCombo] = MBCombo.loadAll() { didSet { MBCombo.saveAll(combos) } }
    /// The saved combination the editor is working on (nil = unsaved / new).
    @Published var activeCombo: UUID?
    @Published private(set) var lastResult: MBComboResult?

    func run(events: [MBEvent], vm: ScreenerViewModel) {
        guard !running else { return }
        guard let label = vm.labelIndex else { summary = "Import data first."; return }
        let g = group, current = vm.table
        let days = HistoryStore.days()
        running = true; summary = "Checking stored days…"
        Task {
            let out = await Task.detached(priority: .userInitiated) { () -> (Set<String>, String, [String], MBComboResult?) in
                guard !days.isEmpty else { return ([], "No stored daily snapshots yet — they build up as the app imports the sheet each day.", [], nil) }
                // the snapshot each event is judged on
                var byDay: [String: [MBEvent]] = [:]
                var noData = 0
                for e in events {
                    if let d = days.last(where: { $0 <= e.baseDay }) { byDay[d, default: []].append(e) } else { noData += 1 }
                }
                var hit = Set<String>(), issues: [String] = []
                var matchesAll = 0, judged = 0
                for (d, evs) in byDay {
                    guard let data = HistoryStore.load(d), let t = ScreenerViewModel.align(data, to: current) else { continue }
                    var iss: [String] = []
                    guard let pred = FilterCompiler.compile(g, table: t, issues: &iss) else { issues = iss; continue }
                    if issues.isEmpty { issues = iss }
                    var bySym: [String: SheetRow] = [:]
                    for r in t.rows { bySym[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] = r }
                    matchesAll += t.rows.filter(pred).count
                    for e in evs { judged += 1; if let r = bySym[e.symbol], pred(r) { hit.insert(e.id) } }
                }
                let caught = judged > 0 ? Double(hit.count) / Double(judged) * 100 : 0
                let precision = matchesAll > 0 ? Double(hit.count) / Double(matchesAll) * 100 : 0
                var s = "Caught \(hit.count) of \(judged) multibaggers (\(String(format: "%.0f", caught))%) on their pre-move snapshot."
                if matchesAll > 0 { s += " On those \(byDay.count) day\(byDay.count == 1 ? "" : "s") \(matchesAll) stocks matched → \(String(format: "%.1f", precision))% of matches became multibaggers." }
                if noData > 0 { s += " \(noData) older moves have no stored snapshot before them." }
                return (hit, s, issues, MBComboResult(caught: hit.count, judged: judged, matches: matchesAll, ranAt: Date()))
            }.value
            matched = out.0; summary = out.1; issues = out.2; lastResult = out.3
            if let r = out.3, let id = activeCombo, let i = combos.firstIndex(where: { $0.id == id }), combos[i].group == g {
                combos[i].result = r
            }
            ready = true; running = false
        }
    }
}

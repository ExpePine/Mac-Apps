import SwiftUI
import Charts

/// Daily Gainers: NIFTY 50 / SENSEX mini charts, the day's gainers with sector mix, Filter columns in colour,
/// and a 5–10 word "why" per stock from news headlines via Groq.
struct GainersView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var chartRange = 0              // 0 = today (5-min), 1 = 3 months
    @State private var showSettings = false
    @State private var sortColumn: Int?
    @State private var sortDescending = true
    @State private var selection: [SheetRow] = []
    @State private var version = 0
    @ObservedObject private var live = LiveQuotes.shared
    @AppStorage("live.enabled") private var liveOn = true
    @AppStorage("live.interval") private var liveInterval = 60.0

    var body: some View {
        let day = vm.currentGainerDay
        let gainers = vm.gainers(on: day)
        VStack(spacing: 0) {
            indexStrip
            Divider()
            MarketStrip()
            Divider()
            controls(day: day, gainers: gainers)
            Divider()
            summary(day: day, gainers: gainers)
            Divider()
            if gainers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No stocks up ≥ \(fmt(vm.settings.gainersThreshold))% on \(day)").font(.title3)
                    Text(live.lastUpdate == nil ? "Waiting for the first live Yahoo pass (\(live.progress.done)/\(live.progress.total))…" : "Lower the threshold or pick another day.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(day: day, gainers: gainers)
            }
        }
        .navigationTitle("Daily Gainers")
        .task { await LiveQuotes.shared.keepLive(vm) }             // live Yahoo prices for every stock
        .task {
            while !Task.isCancelled {
                await vm.refreshIndexCharts()                          // NIFTY / SENSEX intraday, every minute
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
        .onChange(of: live.tick) { _ in version += 1 }
        .sheet(isPresented: $showSettings) { NewsAISettings().environmentObject(vm) }
        .onAppear { if vm.sectorReport == nil { Task { await vm.computeSectors(notify: false) } } }
        .onChange(of: vm.sectorReport?.asOf) { _ in version += 1 }
        .onChange(of: vm.newsCache.reasons.count) { _ in version += 1 }
        .onChange(of: vm.settings.gainersShowFilterColumns) { _ in version += 1 }
        .onChange(of: vm.settings.gainersColumnFilters) { _ in version += 1 }
        .onChange(of: vm.settings.gainersOnlyFilterList) { _ in version += 1 }
        .onChange(of: vm.picks.count) { _ in version += 1 }
    }

    // MARK: Index mini charts

    private var indexStrip: some View {
        HStack(spacing: 14) {
            indexCard("NIFTY 50", ScreenerViewModel.benchmarkSymbol)
            indexCard("SENSEX", ScreenerViewModel.sensexSymbol)
            Picker("", selection: $chartRange) {
                Text("Today").tag(0)
                Text("3M").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
            VStack(alignment: .trailing, spacing: 4) {
                Toggle("Live", isOn: $liveOn).toggleStyle(.switch).controlSize(.small)
                    .help("Re-read every stock's price from Yahoo while NSE is open (Mon–Fri 09:15–15:30 IST)")
                Picker("", selection: $liveInterval) {
                    ForEach([30.0, 60, 120, 300], id: \.self) { Text($0 < 60 ? "every \(Int($0)) s" : "every \(Int($0 / 60)) min").tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                Button("Refresh now") { Task { await live.sweep(vm) } }.controlSize(.small).disabled(live.updating)
            }
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.statusText).font(.caption.monospacedDigit())
                        .foregroundStyle(live.updating ? Color.orange : (LiveQuotes.marketOpen() ? Color.green : Color.secondary))
                    if live.updating { ProgressView(value: Double(live.progress.done), total: Double(max(1, live.progress.total))).frame(width: 160) }
                    if let e = live.lastError { Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
                }
                .frame(width: 230, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func indexCard(_ name: String, _ symbol: String) -> some View {
        let intra = vm.indexIntraday[symbol]
        let daily = vm.priceBook.series(for: symbol)
        let points: [(Int, Double)] = {
            if chartRange == 0, let s = intra, s.closes.count > 1 { return s.closes.enumerated().map { ($0.offset, $0.element) } }
            let c = Array((daily?.closes ?? []).suffix(63))
            return c.enumerated().map { ($0.offset, $0.element) }
        }()
        let change: Double? = chartRange == 0 ? (intra?.change ?? daily?.dailyChange(on: daily?.lastDay ?? ""))
                                              : (daily.flatMap { s in s.closes.count > 63 ? (s.closes.last! / s.closes[s.closes.count - 64] - 1) * 100 : nil })
        let last = intra?.last ?? daily?.closes.last
        let up = (change ?? 0) >= 0
        let prev = chartRange == 0 ? intra?.previousClose : nil
        let why = vm.reason(name, day: vm.currentGainerDay)
        return VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption.bold()).foregroundStyle(.secondary)
                Text(last.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "—").font(.title3.bold().monospacedDigit())
                Text(change.map { String(format: "%+.2f%%", $0) } ?? "—").font(.callout.bold().monospacedDigit())
                    .foregroundStyle(up ? Color.green : Color.red)
            }
            .frame(width: 110, alignment: .leading)
            Chart {
                ForEach(points, id: \.0) { p in
                    LineMark(x: .value("t", p.0), y: .value("v", p.1)).foregroundStyle(up ? Color.green : Color.red)
                    AreaMark(x: .value("t", p.0), yStart: .value("lo", points.map(\.1).min() ?? p.1), yEnd: .value("v", p.1))
                        .foregroundStyle((up ? Color.green : Color.red).opacity(0.08))
                }
                if let prev { RuleMark(y: .value("prev", prev)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(dash: [3, 3])) }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisValueLabel().font(.system(size: 8)) } }
            .frame(height: 70)
        }
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                Text(why ?? "Why? — click “Why? (news + Groq)” for the reason")
                    .font(.caption).foregroundStyle(why == nil ? .secondary : .primary).lineLimit(2)
                    .help(why.map { "Groq's summary of today's market headlines: \($0)" } ?? "")
                Spacer()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .help(chartRange == 0 ? "Today, 5-minute Yahoo data; dashed line = previous close" : "Last 3 months of daily closes")
    }

    // MARK: Controls

    private func controls(day: String, gainers: [GainerRow]) -> some View {
        HStack(spacing: 10) {
            Picker("Day", selection: $vm.gainersDay) {
                Text("Latest (\(vm.gainerDays.first ?? "—"))").tag(String?.none)
                ForEach(vm.gainerDays.dropFirst(), id: \.self) { d in Text(d).tag(String?.some(d)) }
            }
            .frame(width: 210)
            Text("Up at least").font(.callout)
            TextField("5", value: $vm.settings.gainersThreshold, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
            Text("%").font(.callout)
            Toggle("Filter columns & colours", isOn: $vm.settings.gainersShowFilterColumns).toggleStyle(.switch).controlSize(.small)
                .help("Show the Filter screen's columns next to each gainer, painted with your cell colours")
            Toggle("Only my Filter list", isOn: $vm.settings.gainersOnlyFilterList).toggleStyle(.switch).controlSize(.small)
                .help("Only gainers that also pass the Filter screen's conditions")
            Spacer()
            if let p = vm.explainProgress {
                ProgressView(value: Double(p.0), total: Double(max(1, p.1))).frame(width: 100)
                Text("\(p.0)/\(p.1)").font(.caption.monospacedDigit())
            }
            if let s = vm.newsStatus { Text(s).font(.caption).foregroundStyle(.orange).lineLimit(1) }
            Button { markSelection(.pick, gainers: gainers, day: day) } label: { Label("My pick", systemImage: "checkmark.circle.fill") }
                .tint(.green)
                .disabled(selection.isEmpty)
                .help("Mark the selected stocks as my pick (green P). Or click P on a row to cycle grey → green → orange.")
            Button { markSelection(.ok, gainers: gainers, day: day) } label: { Label("OK", systemImage: "circle.lefthalf.filled") }
                .tint(.orange)
                .disabled(selection.isEmpty)
                .help("Mark the selected stocks as an OK selection (orange P)")
            Button { openWindow(id: "picks") } label: { Label("My Picks", systemImage: "star.square.on.square") }
                .help("All your picks in one place, with returns since (⌥⌘P)")
            Button { UserDefaults.standard.set(ReelSource.gainers.rawValue, forKey: "reel.source"); openWindow(id: "reel") } label: { Label("Chart Reel", systemImage: "film.stack") }
                .help("Flick through these gainers' charts with a slider (⌥⌘R)")
            OpenMenu()
            Button { vm.explainIndices(day: day); vm.explainGainers(gainers, day: day) } label: { Label("Why? (news + Groq)", systemImage: "sparkles") }
                .disabled(vm.isExplaining)
                .help("Fetch recent headlines for each gainer and ask Groq for a 5–10 word reason (cached per day)")
            Menu {
                Button("Re-fetch all reasons for this day") { vm.explainIndices(day: day, force: true); vm.explainGainers(gainers, day: day, force: true) }
                Button("Update Yahoo prices") { Task { await vm.updateSectorPrices() } }
                Divider()
                Button("News & AI settings…") { showSettings = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Summary (analysis)

    private func summary(day: String, gainers: [GainerRow]) -> some View {
        let br = vm.breadth(on: day)
        let avg = gainers.isEmpty ? 0 : gainers.map(\.change).reduce(0, +) / Double(gainers.count)
        let sectorIdx = vm.sectorColumnIndex
        var bySector: [String: Int] = [:]
        if let sc = sectorIdx { for g in gainers { bySector[g.row.text(sc).isEmpty ? "—" : g.row.text(sc), default: 0] += 1 } }
        var byQuadrant: [Quadrant: Int] = [:]
        if let sc = sectorIdx {
            for g in gainers { if let r = vm.sectorRotation(g.row.text(sc), day: day) { byQuadrant[r.quadrant, default: 0] += 1 } }
        }
        let filterSet = Set(vm.filterRows.map(\.id))
        let inFilter = gainers.filter { filterSet.contains($0.row.id) }.count
        let explained = gainers.filter { vm.reason($0.symbol, day: day) != nil }.count
        return HStack(alignment: .top, spacing: 20) {
            stat("Gainers ≥ \(fmt(vm.settings.gainersThreshold))%", "\(gainers.count)", .green)
            stat("Average gain", String(format: "%+.1f%%", avg), .green)
            stat("Advancers / decliners", "\(br.up) / \(br.down)", br.up >= br.down ? .green : .red,
                 note: br.up + br.down > 0 ? String(format: "%.0f%% up", Double(br.up) / Double(br.up + br.down) * 100) : "")
            stat("In your Filter list", "\(inFilter)", .blue)
            stat("Reasons", "\(explained)/\(gainers.count)", .purple)
            let mine = vm.picks.filter { $0.day == day }
            stat("My picks · OK", "\(mine.filter { $0.grade == .pick }.count) · \(mine.filter { $0.grade == .ok }.count)", .green,
                 note: "click P in the table")
            if !bySector.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sectors among gainers").font(.caption).foregroundStyle(.secondary)
                    FlowChips(items: bySector.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) \($0.value)" })
                }
                if !byQuadrant.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gainers by sector rotation").font(.caption).foregroundStyle(.secondary)
                        FlowChips(items: Quadrant.allCases.compactMap { q in byQuadrant[q].map { "\(ScreenerViewModel.quadrantLabel(q)) \($0)" } })
                    }
                    .help("Which rotation-map quadrant each gainer's sector was in that day. Many gainers in Lagging sectors = stock-specific moves; in Leading = sector momentum.")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Table

    private func table(day: String, gainers: [GainerRow]) -> some View {
        let base = vm.table
        let extraNames = ["Day %", "Close", "Why (news)", "Sector rotation", "Sector trend", "Sector score"]
        let sc = vm.sectorColumnIndex
        let derived = SheetTable(headers: base.headers + extraNames,
                                 rows: gainers.map { g in
                                     let why = vm.reason(g.symbol, day: day) ?? ""
                                     let rot = sc.flatMap { vm.sectorRotation(g.row.text($0), day: day) }
                                     return SheetRow(id: g.row.id,
                                                     cells: g.row.cells + [String(format: "%+.2f%%", g.change),
                                                                           g.close.map { String(format: "%.2f", $0) } ?? "", why,
                                                                           rot.map { ScreenerViewModel.quadrantLabel($0.quadrant) } ?? "",
                                                                           rot?.trend.rawValue ?? "",
                                                                           rot.map { String(format: "%.0f", $0.score) + ($0.rank.map { " (#\($0))" } ?? "") } ?? ""],
                                                     numbers: g.row.numbers + [g.change, g.close, nil, nil, nil, rot?.score])
                                 },
                                 originalHeaders: base.originalHeaders + extraNames)
        let n = base.headers.count
        let dayCol = n, closeCol = n + 1, whyCol = n + 2, rotCol = n + 3, trendCol = n + 4, scoreCol = n + 5
        let byID = Dictionary(gainers.map { ($0.row.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cols: [Int] = [vm.labelIndex ?? 0, dayCol, closeCol, whyCol]
        if let sc { cols += [sc, rotCol, trendCol, scoreCol] }
        if vm.settings.gainersShowFilterColumns {
            cols += vm.filterColumnIndices.filter { !cols.contains($0) }
        }
        var rows = derived.rows
        if vm.settings.gainersOnlyFilterList {
            let pass = Set(vm.filterRows.map(\.id))
            rows = rows.filter { pass.contains($0.id) }
        }
        let active = vm.settings.gainersColumnFilters.filter { $0.value.isActive }
        for (name, f) in active {
            guard let c = derived.index(of: name) else { continue }
            rows = rows.filter { f.passes($0, column: c) }
        }
        if let c = sortColumn { rows = Sorter.sort(rows, column: c, descending: sortDescending) }
        let marked = Set(active.keys.compactMap { derived.index(of: $0) })
        let painter: CellPainter? = vm.settings.gainersShowFilterColumns ? CellPainter(vm.settings.cellRules, table: derived) : nil
        return VStack(spacing: 0) {
            SheetTableView(headers: derived.headers, originalHeaders: derived.originalHeaders, columns: cols, rows: rows,
                           version: version &+ rows.count &+ (sortColumn ?? -1) &* 31 &+ (sortDescending ? 1 : 0),
                           emphasizedColumn: dayCol, sortColumn: sortColumn, sortDescending: sortDescending,
                           painter: painter, frozenColumns: 1,
                           onHeaderClick: { i in
                               if sortColumn == i { sortDescending.toggle() } else { sortColumn = i; sortDescending = true }
                           },
                           onDoubleClickRow: { row in vm.openChart(vm.rowKey(row), queue: rows.map { vm.rowKey($0) }, goTo: vm.currentGainerDay, openWindow: openWindow) },
                           onHoverChart: ChartPeek.enabled ? { row, chart in ChartPeek.shared.show(vm.rowKey(row), chart: chart, vm: vm) } : nil,
                           chartDotsAfter: vm.labelIndex,
                           columnMenu: { i in
                               AnyView(GainerColumnMenu(name: derived.headers[i], sample: derived.rows.map { $0.number(i) },
                                                        sortColumn: $sortColumn, sortDescending: $sortDescending, column: i)
                                   .environmentObject(vm))
                           },
                           markedColumns: marked,
                           sColor: { vm.sColor($0) },
                           onSClick: { row in vm.shotSymbol = vm.rowKey(row); openWindow(id: "shots") },
                           pColor: { row in vm.pickColor(vm.rowKey(row), day: day) },
                           onPClick: { row in if let g = byID[row.id] { vm.cyclePick(g, day: day) } },
                           onSelectRows: { selection = $0 },
                           rowMenu: { row in vm.rowMenu(row, selection: selection, openWindow: openWindow, queue: rows) })
            Divider()
            HStack(spacing: 10) {
                Text("\(rows.count) of \(derived.rows.count) shown").font(.caption.bold())
                if !active.isEmpty || vm.settings.gainersOnlyFilterList {
                    Button("Clear filters") { vm.settings.gainersColumnFilters = [:]; vm.settings.gainersOnlyFilterList = false }
                        .controlSize(.small)
                }
                let missing = vm.stocksWithoutYahoo(on: day)
                if missing > 0 { Text("\(missing) sheet stocks have no Yahoo price for \(day)").font(.caption2).foregroundStyle(.orange) }
                Text("Day % = Yahoo price vs previous close (live while NSE is open). “Why” = Groq's summary of recent headlines (\(vm.settings.newsProvider.rawValue)); check the source before acting. Right-click a stock to add it to a watchlist.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(6)
        }
    }

    // MARK: Helpers

    private func markSelection(_ grade: PickGrade, gainers: [GainerRow], day: String) {
        let ids = Set(selection.map(\.id))
        for g in gainers where ids.contains(g.row.id) { vm.setPick(g, day: day, grade: grade) }
        version += 1
    }

    private func stat(_ title: String, _ value: String, _ color: Color, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }
}

/// Simple wrapping row of small chips.
struct FlowChips: View {
    let items: [String]
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 5).map { Array(items[$0..<min($0 + 5, items.count)]) }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { t in
                        Text(t).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
        }
    }
}

/// Groq key + model, news source, company-name column.
struct NewsAISettings: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var models: [String] = []
    @State private var status = ""
    @State private var loading = false

    var body: some View {
        Form {
            Section {
                SecureField("Groq API key", text: $key)
                HStack {
                    Button("Save key") { Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: GroqClient.keychainAccount); status = "Key saved in the Keychain."; loadModels() }
                    Button("Load models") { loadModels() }.disabled(loading)
                    if loading { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Model", selection: $vm.settings.groqModel) {
                    if vm.settings.groqModel.isEmpty { Text("Pick a model…").tag("") }
                    if !vm.settings.groqModel.isEmpty && !models.contains(vm.settings.groqModel) { Text(vm.settings.groqModel).tag(vm.settings.groqModel) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            } header: { Text("Groq (AI summaries)") } footer: {
                Text("Get a key at console.groq.com. The key stays in your Mac's Keychain. The model list comes live from Groq because models change; pick a chat model (not a speech or guard model). Only headlines are sent — no portfolio data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("News source", selection: $vm.settings.newsProvider) {
                    ForEach(NewsProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Company name column (better searches)", selection: $vm.settings.companyNameColumn) {
                    Text("Auto (\(vm.companyNameIndex.map { vm.headers[$0] } ?? "symbol only"))").tag("")
                    ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
                }
            } header: { Text("News") } footer: {
                Text("Both sources are free and need no key, but are unofficial: Google News RSS may slow down if polled heavily, and Yahoo's search endpoint can change. Reasons are cached per day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
        .onAppear {
            key = GroqClient.apiKey
            if !key.isEmpty { loadModels() }
        }
    }

    private func loadModels() {
        loading = true
        Task {
            do {
                let m = try await GroqClient.models()
                models = m.filter { id in !["whisper", "tts", "guard", "playai", "orpheus"].contains { id.lowercased().contains($0) } }
                status = "\(models.count) chat models"
            } catch {
                status = error.localizedDescription
            }
            loading = false
        }
    }
}


/// ▼ panel on a gainers column: sort, and a quick min / max / text filter.
struct GainerColumnMenu: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let name: String
    let sample: [Double?]
    @Binding var sortColumn: Int?
    @Binding var sortDescending: Bool
    let column: Int

    private var isNumeric: Bool { sample.compactMap { $0 }.count * 2 >= max(1, sample.count) }
    private var filter: Binding<ColumnQuickFilter> {
        Binding(get: { vm.settings.gainersColumnFilters[name] ?? ColumnQuickFilter() },
                set: { vm.settings.gainersColumnFilters[name] = $0.isActive ? $0 : nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            HStack {
                Button { sortColumn = column; sortDescending = false } label: { Label("Sort ascending", systemImage: "arrow.up") }
                Button { sortColumn = column; sortDescending = true } label: { Label("Sort descending", systemImage: "arrow.down") }
            }
            .controlSize(.small)
            Divider()
            Text("Show only rows where").font(.caption).foregroundStyle(.secondary)
            if isNumeric {
                let vals = sample.compactMap { $0 }
                HStack {
                    Text("from").font(.callout)
                    TextField("min", text: numberText(\.min)).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("to").font(.callout)
                    TextField("max", text: numberText(\.max)).textFieldStyle(.roundedBorder).frame(width: 80)
                }
                if let lo = vals.min(), let hi = vals.max() {
                    Text("Values here: \(fmt(lo)) … \(fmt(hi))").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                TextField("contains…", text: filter.contains).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Toggle("Not blank", isOn: filter.nonEmpty).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Clear") { vm.settings.gainersColumnFilters[name] = nil }.disabled(!(vm.settings.gainersColumnFilters[name]?.isActive ?? false))
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }

    /// A text field bound to an optional number (blank = no limit).
    private func numberText(_ key: WritableKeyPath<ColumnQuickFilter, Double?>) -> Binding<String> {
        Binding(get: { filter.wrappedValue[keyPath: key].map { fmt($0) } ?? "" },
                set: { t in
                    var f = filter.wrappedValue
                    f[keyPath: key] = NumberParser.parse(t.replacingOccurrences(of: ",", with: ""))
                    filter.wrappedValue = f
                })
    }
}

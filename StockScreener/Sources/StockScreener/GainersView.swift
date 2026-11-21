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
    /// Your column order and hidden columns for this table (names; "\u{1F}"-separated).
    @AppStorage("gainers.colOrder") private var colOrderRaw = ""
    @AppStorage("gainers.colHidden") private var colHiddenRaw = ""
    @State private var showColumnChooser = false
    @State private var chooserHeaders: [String] = []
    @State private var chooserDefault: [String] = []
    @State private var version = 0
    @ObservedObject private var live = LiveQuotes.shared
    @AppStorage("live.enabled") private var liveOn = true
    @AppStorage("live.interval") private var liveInterval = 60.0
    @AppStorage(GainerPeriod.key) private var periodRaw = GainerPeriod.daily.rawValue
    @AppStorage(GainerPeriod.calendarKey) private var calendarOn = false
    @AppStorage("gainers.th.weekly") private var thWeekly = 10.0
    @AppStorage("gainers.th.monthly") private var thMonthly = 30.0
    private var period: GainerPeriod { GainerPeriod(rawValue: periodRaw) ?? .daily }
    @AppStorage(GainerUniverse.key) private var universeRaw = GainerUniverse.all.rawValue
    @AppStorage(GainerUniverse.mcapKey) private var mcapMin = 0.0
    @ObservedObject private var universe = UniverseStore.shared
    @State private var customCap = ""
    private var uni: GainerUniverse { GainerUniverse(rawValue: universeRaw) ?? .all }
    private var threshold: Binding<Double> {
        switch period {
        case .daily: return $vm.settings.gainersThreshold
        case .weekly: return $thWeekly
        case .monthly: return $thMonthly
        }
    }
    private var periodText: String {
        switch period {
        case .daily: return "on the day"
        case .weekly: return calendarOn ? "this week (week-to-date)" : "over 5 trading days"
        case .monthly: return calendarOn ? "this month (month-to-date)" : "over 21 trading days"
        }
    }

    var body: some View {
        let day = vm.currentGainerDay
        let _ = (periodRaw, calendarOn, thWeekly, thMonthly, universeRaw, mcapMin)       // redraw when these change
        let gainers = vm.gainers(on: day)
        VStack(spacing: 0) {
            ScraperHealthBanner()
            indexStrip
                .overlay(alignment: .trailing) { ScraperHealthBadge().controlSize(.small).padding(.trailing, 6) }
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
                    Text("No stocks up ≥ \(fmt(threshold.wrappedValue))% \(periodText) (\(day))").font(.title3)
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
        .task(id: "\(universeRaw)|\(mcapMin)|\(day)|\(periodRaw)|\(calendarOn)|\(threshold.wrappedValue)|\(universe.members.count)") {
            await universe.ensure(uni, needMcap: mcapMin > 0)
            guard mcapMin > 0 else { return }
            let cands = vm.yahooGainers(on: day, min: vm.gainerThreshold, period: period, calendar: calendarOn)
                .filter { uni == .all || universe.isMember($0.symbol, of: uni) == true }
                .map(\.symbol)
            await universe.fillShares(cands)
        }
        .sheet(isPresented: $showSettings) { NewsAISettings().environmentObject(vm) }
        .sheet(isPresented: $showColumnChooser) {
            GainersColumnChooser(all: chooserHeaders, defaults: chooserDefault, orderRaw: $colOrderRaw, hiddenRaw: $colHiddenRaw)
        }
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

    private var presets: [Double] {
        switch period {
        case .daily: return [1, 2, 3, 5, 10, 15, 20]
        case .weekly: return [5, 10, 15, 20, 30]
        case .monthly: return [10, 20, 30, 50, 100]
        }
    }

    private func controls(day: String, gainers: [GainerRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            Picker("Day", selection: $vm.gainersDay) {
                Text("Latest (\(vm.gainerDays.first ?? "—"))").tag(String?.none)
                ForEach(vm.gainerDays.dropFirst(), id: \.self) { d in Text(d).tag(String?.some(d)) }
            }
            .frame(width: 210).fixedSize()
            Picker("", selection: $periodRaw) {
                ForEach(GainerPeriod.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Daily = % on the day · Weekly = last 5 trading days · Monthly = last 21 trading days (or week / month to date). Each keeps its own threshold.")
            Text("Up at least").font(.callout).fixedSize()
            TextField("5", value: threshold, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
            Menu {
                ForEach(presets, id: \.self) { v in Button("\(fmt(v))%") { threshold.wrappedValue = v } }
            } label: { Text("%") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Pick a preset or type any number")
            Picker("", selection: $universeRaw) {
                ForEach(GainerUniverse.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .labelsHidden().fixedSize()
            .help("Only stocks in this Nifty index (members from NSE, refreshed weekly). Only your sheet's stocks are ever shown.")
            Menu {
                ForEach(GainerUniverse.mcapPresets, id: \.self) { v in
                    Button(v == 0 ? "Any market cap" : "≥ ₹" + GainerUniverse.crore(v)) { mcapMin = v }
                }
                Divider()
                Button("Refresh index list & market caps from NSE") { Task { await universe.refresh(uni, needMcap: true) } }
            } label: { Text(mcapMin == 0 ? "Any mcap" : "Mcap ≥ ₹" + GainerUniverse.crore(mcapMin)) }
            .fixedSize()
            .help("Market cap = issued shares (NSE) × that day's close. Type your own below the presets, or pick one.")
            TextField("Cr", text: $customCap).textFieldStyle(.roundedBorder).frame(width: 60)
                .onSubmit { if let v = Double(customCap.replacingOccurrences(of: ",", with: "")), v >= 0 { mcapMin = v; customCap = "" } }
                .help("Your own minimum market cap in ₹ crore — type and press Return")
            if universe.busy { ProgressView().controlSize(.small) }
            if period != .daily {
                Toggle("To date", isOn: $calendarOn).toggleStyle(.switch).controlSize(.small).fixedSize()
                    .help("On: week-to-date / month-to-date (vs the last close before the week or month began). Off: rolling 5 / 21 trading days.")
            }
            if let st = universe.status { Text(st).font(.caption).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 0)
        }
        HStack(spacing: 10) {
            Toggle("Filter columns & colours", isOn: $vm.settings.gainersShowFilterColumns).toggleStyle(.switch).controlSize(.small).fixedSize()
                .help("Show the Filter screen's columns next to each gainer, painted with your cell colours")
            Toggle("Only my Filter list", isOn: $vm.settings.gainersOnlyFilterList).toggleStyle(.switch).controlSize(.small).fixedSize()
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
            AddToWatchlistButton(groups: [("Selected", selection.map { vm.rowKey($0) }), ("All gainers on \(day)", gainers.map(\.symbol))],
                                 day: day, source: "Daily gainers \(day)")
            Button { openWindow(id: "picks") } label: { Label("My Picks", systemImage: "star.square.on.square") }
                .help("All your picks in one place, with returns since (⌥⌘P)")
            Button { UserDefaults.standard.set(ReelSource.gainers.rawValue, forKey: "reel.source"); openWindow(id: "reel") } label: { Label("Chart Reel", systemImage: "film.stack") }
                .help("Flick through these gainers' charts with a slider (⌥⌘R)")
            Button { openWindow(id: "quick") } label: { Label("Quick", systemImage: "square.grid.3x3") }
                .help("Pictures of Chart 1, Chart 2 and the delivery chart of these gainers in a 2×2 or 3×3 grid — refreshed every hour")
            Button { openWindow(id: "delchart") } label: { Label("DEL chart", systemImage: "chart.bar.xaxis") }
                .help("The whole market's delivered value per day (Σ DELIV_QTY × CLOSE), with traded value, delivery % and Nifty 50")
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
        }
        .fixedSize(horizontal: false, vertical: true)
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
            stat("\(period.title) gainers ≥ \(fmt(threshold.wrappedValue))%", "\(gainers.count)", .green,
                 note: periodText + (uni == .all ? "" : " · " + uni.title) + (mcapMin > 0 ? " · mcap ≥ ₹" + GainerUniverse.crore(mcapMin) : ""))
            stat("Average gain", String(format: "%+.1f%%", avg), .green)
            stat("Advancers / decliners", "\(br.up) / \(br.down)", br.up >= br.down ? .green : .red,
                 note: br.up + br.down > 0 ? String(format: "%.0f%% up", Double(br.up) / Double(br.up + br.down) * 100) : "")
            stat("In your Filter list", "\(inFilter)", .blue)
            stat("Reasons", "\(explained)/\(gainers.count)", .purple)
            let mine = vm.picks.filter { $0.day == day }
            stat("My picks · OK", "\(mine.filter { $0.grade == .pick }.count) · \(mine.filter { $0.grade == .ok }.count)", .green,
                 note: "click P in the table")
            if !bySector.isEmpty {
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

    private func gainerRow(_ g: GainerRow, day: String, sc: Int?, periodCol: String?) -> SheetRow {
        let why: String = vm.reason(g.symbol, day: day) ?? ""
        let rot = sc.flatMap { vm.sectorRotation(g.row.text($0), day: day) }
        let dayCh: Double? = periodCol == nil ? g.change : vm.priceBook.series(for: g.symbol)?.dailyChange(on: day)
        let dayText: String = dayCh.map { String(format: "%+.2f%%", $0) } ?? ""
        let closeText: String = g.close.map { String(format: "%.2f", $0) } ?? ""
        let quad: String = rot.map { ScreenerViewModel.quadrantLabel($0.quadrant) } ?? ""
        let trend: String = rot?.trend.rawValue ?? ""
        var score: String = ""
        if let r = rot {
            score = String(format: "%.0f", r.score)
            if let k = r.rank { score += " (#\(k))" }
        }
        var cells: [String] = g.row.cells
        cells += [dayText, closeText, why, quad, trend, score]
        var nums: [Double?] = g.row.numbers
        nums += [dayCh, g.close, nil, nil, nil, rot?.score]
        if periodCol != nil {
            cells.append(String(format: "%+.2f%%", g.change))
            nums.append(g.change)
        }
        return SheetRow(id: g.row.id, cells: cells, numbers: nums)
    }

    private func table(day: String, gainers: [GainerRow]) -> some View {
        let base = vm.table
        let periodCol: String? = period == .daily ? nil : period.column
        let extraNames = ["Day %", "Close", "Why (news)", "Sector rotation", "Sector trend", "Sector score"] + (periodCol.map { [$0] } ?? [])
        let sc = vm.sectorColumnIndex
        let derived = SheetTable(headers: base.headers + extraNames,
                                 rows: gainers.map { g in gainerRow(g, day: day, sc: sc, periodCol: periodCol) },
                                 originalHeaders: base.originalHeaders + extraNames)
        let n = base.headers.count
        let dayCol = n, closeCol = n + 1, whyCol = n + 2, rotCol = n + 3, trendCol = n + 4, scoreCol = n + 5
        let byID = Dictionary(gainers.map { ($0.row.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cols: [Int] = [vm.labelIndex ?? 0] + (periodCol == nil ? [] : [n + 6]) + [dayCol, closeCol, whyCol]
        if let sc { cols += [sc, rotCol, trendCol, scoreCol] }
        if vm.settings.gainersShowFilterColumns {
            cols += vm.filterColumnIndices.filter { !cols.contains($0) }
        }
        // your order first (drag headers, or the chooser), then any other default column; hidden ones left out
        let defaultNames = cols.map { derived.headers[$0] }
        let labelName = derived.headers[vm.labelIndex ?? 0]
        let hidden = Set(GainersColumnChooser.split(colHiddenRaw))
        var names: [String] = []
        for nm in GainersColumnChooser.split(colOrderRaw) + defaultNames where !hidden.contains(nm) && derived.index(of: nm) != nil && !names.contains(nm) {
            names.append(nm)
        }
        names.removeAll { $0 == labelName }
        if let pc = periodCol, !GainersColumnChooser.split(colOrderRaw).contains(pc), let k = names.firstIndex(of: pc) {
            names.remove(at: k); names.insert(pc, at: 0)                 // Week % / Month % next to the symbol
        }
        cols = [vm.labelIndex ?? 0] + names.compactMap { derived.index(of: $0) }
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
        // Filter colours on the Filter columns (when shown), and always the rules that paint the symbol (e.g. by Safety)
        let symName = derived.headers[vm.labelIndex ?? 0]
        let rulesHere = vm.settings.gainersShowFilterColumns ? vm.settings.cellRules : vm.settings.cellRules.filter { $0.paint == symName }
        let painter: CellPainter? = rulesHere.isEmpty ? nil : CellPainter(rulesHere, table: derived)
        return VStack(spacing: 0) {
            SheetTableView(headers: derived.headers, originalHeaders: derived.originalHeaders, columns: cols, rows: rows,
                           version: version &+ rows.count &+ (sortColumn ?? -1) &* 31 &+ (sortDescending ? 1 : 0),
                           emphasizedColumn: dayCol, sortColumn: sortColumn, sortDescending: sortDescending,
                           painter: painter, frozenColumns: 1,
                           onHeaderClick: { i in
                               if sortColumn == i { sortDescending.toggle() } else { sortColumn = i; sortDescending = true }
                           },
                           onDoubleClickRow: { row in vm.openChart(vm.rowKey(row), queue: rows.map { vm.rowKey($0) }, goTo: vm.currentGainerDay, context: .gainers, openWindow: openWindow) },
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
                           rowMenu: { row in vm.rowMenu(row, selection: selection, openWindow: openWindow, queue: rows) },
                           onColumnOrder: { order in
                               colOrderRaw = GainersColumnChooser.join(order.map { derived.headers[$0] })
                           },
                           onHideColumn: { i in
                               let nm = derived.headers[i]
                               var h = GainersColumnChooser.split(colHiddenRaw); if !h.contains(nm) { h.append(nm) }
                               colHiddenRaw = GainersColumnChooser.join(h)
                           },
                           hiddenColumns: derived.headers.indices.filter { !cols.contains($0) },
                           onShowColumn: { i in
                               let nm = derived.headers[i]
                               colHiddenRaw = GainersColumnChooser.join(GainersColumnChooser.split(colHiddenRaw).filter { $0 != nm })
                               var o = GainersColumnChooser.split(colOrderRaw)
                               if o.isEmpty { o = cols.map { derived.headers[$0] } }
                               if !o.contains(nm) { o.append(nm) }
                               colOrderRaw = GainersColumnChooser.join(o)
                           },
                           onChooseColumns: {
                               chooserHeaders = derived.headers
                               chooserDefault = cols.map { derived.headers[$0] }
                               showColumnChooser = true
                           })
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


/// Pick which columns the Daily Gainers table shows and drag them into your order.
struct GainersColumnChooser: View {
    let all: [String]
    let defaults: [String]          // what's shown now, in order
    @Binding var orderRaw: String
    @Binding var hiddenRaw: String
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [String] = []
    @State private var search = ""

    static func split(_ s: String) -> [String] { s.isEmpty ? [] : s.components(separatedBy: "\u{1F}") }
    static func join(_ a: [String]) -> String { a.joined(separator: "\u{1F}") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Gainers columns").font(.headline)
            Text("Tick to show · drag to reorder (the symbol stays first). You can also drag headers in the table, and right-click a header to hide it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shown, in order").font(.caption.bold())
                    List {
                        ForEach(shown, id: \.self) { nm in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                Text(nm).lineLimit(1)
                                Spacer()
                                if nm != defaults.first {
                                    Button { shown.removeAll { $0 == nm } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        .onMove { from, to in shown.move(fromOffsets: from, toOffset: to) }
                    }
                    .frame(width: 280, height: 380)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a column").font(.caption.bold())
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                    List(all.filter { !shown.contains($0) && (search.isEmpty || $0.localizedCaseInsensitiveContains(search)) }, id: \.self) { nm in
                        HStack {
                            Text(nm).lineLimit(1)
                            Spacer()
                            Button { shown.append(nm) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    .frame(width: 240, height: 350)
                }
            }
            HStack {
                Button("Reset to default") { orderRaw = ""; hiddenRaw = ""; dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    orderRaw = Self.join(shown)
                    // hide only what you took out (other columns can still appear, e.g. with "Filter columns & colours")
                    var h = Set(Self.split(hiddenRaw)).union(defaults.filter { !shown.contains($0) })
                    h.subtract(shown)
                    hiddenRaw = Self.join(h.sorted())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { shown = defaults }
    }
}

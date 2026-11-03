import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

/// Watchlists: stocks added from Daily Gainers, the Filter, charts, Multibaggers… with their returns since added,
/// a portfolio curve vs Nifty 50, forward-return analysis, breakdowns and a comparison of all lists.
struct WatchlistView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow

    enum Tab: String, CaseIterable { case stocks = "Stocks", performance = "Performance", analysis = "Analysis", compare = "Compare lists" }
    @AppStorage("watch.tab") private var tabRaw = Tab.stocks.rawValue
    @AppStorage("watch.status") private var status = "Active"
    @AppStorage("watch.sort") private var sortKey = "ret"
    @AppStorage("watch.sortDesc") private var sortDesc = true
    @AppStorage("watch.sheetCols") private var sheetColsRaw = ""
    @AppStorage("watch.hidden") private var hiddenRaw = ""
    @State private var search = ""
    @State private var tagFilter = ""
    @State private var sourceFilter = ""
    @State private var selection = Set<UUID>()
    @State private var anchor: UUID?
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var pasteText = ""
    @State private var showPaste = false

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .stocks }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 230, maxWidth: 320)
            Group {
                if tab == .compare { CompareListsView(rowsFor: rows(for:)).environmentObject(vm) }
                else if let li = vm.currentWatchlistIndex { detail(li) }
                else { Text("No watchlists").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Watchlists")
        .onAppear { if vm.watchlists.contains(where: { !$0.items.isEmpty }) && needsPrices { vm.fetchWatchPrices() } }
        .sheet(isPresented: $showPaste) { pasteSheet }
    }

    private var needsPrices: Bool {
        let syms = vm.watchlists.flatMap { $0.items.map(\.symbol) }
        return syms.contains { vm.priceBook.series(for: $0) == nil } || vm.priceBook.series(for: ScreenerViewModel.benchmarkSymbol) == nil
    }

    // MARK: Data

    private var rowBySymbol: [String: SheetRow] {
        Dictionary(vm.table.rows.map { (vm.rowKey($0).uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    func rows(for list: Watchlist) -> [WatchRow] {
        let byS = rowBySymbol, sc = vm.sectorColumnIndex
        return list.items.map { it in
            WatchRow(item: it, r: vm.watchReturns(it), sector: sc.flatMap { c in byS[it.symbol.uppercased()]?.text(c) } ?? "", list: list.name)
        }
    }

    private func filtered(_ all: [WatchRow]) -> [WatchRow] {
        var out = all
        switch status {
        case "Active": out = out.filter { !$0.item.exited }
        case "Exited": out = out.filter { $0.item.exited }
        default: break
        }
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        if !q.isEmpty { out = out.filter { $0.symbol.contains(q) || $0.item.note.uppercased().contains(q) || $0.sector.uppercased().contains(q) } }
        if !tagFilter.isEmpty { out = out.filter { $0.item.tags.contains(tagFilter) } }
        if !sourceFilter.isEmpty { out = out.filter { Self.sourceKind($0.item.source) == sourceFilter } }
        return sortRows(out)
    }

    /// "Daily gainers 2026-11-03" → "Daily gainers".
    static func sourceKind(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"\s*\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
        return t.isEmpty ? "—" : t
    }

    // MARK: Columns

    struct Col: Identifiable {
        let id: String
        let title: String
        let width: CGFloat
        let num: ((WatchRow) -> Double?)?
        let text: ((WatchRow) -> String)?
        var pct = false
        var optional = true
    }

    private var sheetCols: [String] { sheetColsRaw.split(separator: "|").map(String.init).filter { vm.table.index(of: $0) != nil } }
    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    private var allCols: [Col] {
        let byS = rowBySymbol
        var c: [Col] = [
            Col(id: "symbol", title: "Symbol", width: 110, num: nil, text: { $0.symbol }, optional: false),
            Col(id: "source", title: "Added from", width: 130, num: nil, text: { $0.item.source.isEmpty ? "—" : $0.item.source }),
            Col(id: "tags", title: "Tags", width: 100, num: nil, text: { $0.item.tags.joined(separator: ", ") }),
            Col(id: "sector", title: "Sector", width: 120, num: nil, text: { $0.sector }),
            Col(id: "added", title: "Added", width: 86, num: nil, text: { $0.item.addedDay }),
            Col(id: "days", title: "Days", width: 46, num: { $0.r.tradingDays.map(Double.init) }, text: nil),
            Col(id: "addedPx", title: "Added ₹", width: 74, num: { $0.item.addedPrice }, text: nil),
            Col(id: "now", title: "Now ₹", width: 74, num: { $0.r.now }, text: nil),
            Col(id: "ret", title: "Return", width: 70, num: { $0.r.sinceAdded }, text: nil, pct: true, optional: false),
            Col(id: "alpha", title: "vs Nifty", width: 68, num: { $0.alpha }, text: nil, pct: true),
            Col(id: "d1", title: "1D", width: 58, num: { $0.r.day1 }, text: nil, pct: true),
            Col(id: "d5", title: "5D", width: 58, num: { $0.r.day5 }, text: nil, pct: true),
            Col(id: "m1", title: "1M", width: 62, num: { $0.r.month1 }, text: nil, pct: true),
            Col(id: "fwd5", title: "+5d", width: 60, num: { $0.r.fwd5 }, text: nil, pct: true),
            Col(id: "fwd22", title: "+22d", width: 62, num: { $0.r.fwd22 }, text: nil, pct: true),
            Col(id: "best", title: "Best", width: 64, num: { $0.r.maxSinceAdded }, text: nil, pct: true),
            Col(id: "worst", title: "Worst", width: 64, num: { $0.r.worstSinceAdded }, text: nil, pct: true),
            Col(id: "fromBest", title: "From best", width: 70, num: { $0.r.fromPeak }, text: nil, pct: true),
            Col(id: "to10", title: "Days→+10%", width: 76, num: { $0.r.daysTo10.map(Double.init) }, text: nil),
            Col(id: "status", title: "Target / stop", width: 96, num: nil, text: { Self.statusText($0) }),
        ]
        for h in sheetCols {
            let i = vm.table.index(of: h)
            c.append(Col(id: "sheet:" + h, title: h, width: 80,
                         num: { r in i.flatMap { byS[r.symbol.uppercased()]?.number($0) } },
                         text: { r in i.flatMap { byS[r.symbol.uppercased()]?.text($0) } ?? "" }))
        }
        return c
    }
    private var cols: [Col] { allCols.filter { !$0.optional || !hidden.contains($0.id) } }

    static func statusText(_ r: WatchRow) -> String {
        var p: [String] = []
        if r.item.exited { p.append("exited") }
        if r.r.targetHit { p.append("🎯 target") } else if let t = r.item.target { p.append("🎯 \(Int(t))") }
        if r.r.stopHit { p.append("⛔ stop") } else if let s = r.item.stop { p.append("⛔ \(Int(s))") }
        return p.joined(separator: " ")
    }

    private func sortRows(_ rows: [WatchRow]) -> [WatchRow] {
        guard let c = allCols.first(where: { $0.id == sortKey }) else { return rows }
        if let f = c.num {
            return rows.sorted { a, b in
                let x = f(a), y = f(b)
                if x == nil { return false }; if y == nil { return true }
                return sortDesc ? x! > y! : x! < y!
            }
        }
        if let t = c.text { return rows.sorted { sortDesc ? t($0) > t($1) : t($0) < t($1) } }
        return rows
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { tab == .compare ? nil : vm.currentWatchlistIndex.map { vm.watchlists[$0].id } },
                                    set: { if let id = $0 { vm.selectedWatchlistID = id; if tab == .compare { tabRaw = Tab.stocks.rawValue } } })) {
                ForEach(vm.watchlists) { list in
                    HStack(spacing: 6) {
                        Circle().fill(Self.color(list.color)).frame(width: 8, height: 8)
                        if renaming == list.id {
                            TextField("Name", text: $newName, onCommit: { rename(list.id) }).textFieldStyle(.roundedBorder)
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(list.name).lineLimit(1)
                                let s = WatchSummary(rows(for: list).filter { !$0.item.exited })
                                Text("\(list.items.filter { !$0.exited }.count) stocks" + (s.avg.map { String(format: " · %+.1f%%", $0) } ?? ""))
                                    .font(.caption2).foregroundStyle((s.avg ?? 0) >= 0 ? Color.secondary : Color.red)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .tag(list.id)
                    .contextMenu {
                        Button("Rename") { newName = list.name; renaming = list.id }
                        Menu("Colour") {
                            ForEach(["", "red", "orange", "yellow", "green", "blue", "purple"], id: \.self) { c in
                                Button(c.isEmpty ? "None" : c.capitalized) { setList(list.id) { $0.color = c } }
                            }
                        }
                        Button("Duplicate") { duplicate(list) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(list.id) }.disabled(vm.watchlists.count <= 1)
                    }
                }
                .onMove { vm.watchlists.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 10) {
                Button { vm.newWatchlist(named: ""); tabRaw = Tab.stocks.rawValue } label: { Image(systemName: "plus") }.help("New watchlist")
                Spacer()
                Button { tabRaw = Tab.compare.rawValue } label: { Label("Compare", systemImage: "chart.bar.xaxis") }
                    .help("All watchlists side by side")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .padding(8)
        }
    }

    static func color(_ c: String) -> Color {
        switch c {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return .secondary.opacity(0.4)
        }
    }

    // MARK: Detail

    private func detail(_ li: Int) -> some View {
        let list = vm.watchlists[li]
        let all = rows(for: list)
        let shown = filtered(all)
        return VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 10, lineSpacing: 6) {
                Text(list.name).font(.title2.bold())
                Picker("", selection: $tabRaw) {
                    ForEach(Tab.allCases.filter { $0 != .compare }, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if vm.isFetchingWatch { HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Updating prices…").font(.caption) } }
                Button { vm.fetchWatchPrices() } label: { Label("Refresh prices", systemImage: "arrow.clockwise") }
                    .disabled(vm.isFetchingWatch || list.items.isEmpty)
                Button { pasteText = ""; showPaste = true } label: { Label("Add symbols…", systemImage: "plus") }
                Button { openReel(shown) } label: { Label("Chart Reel", systemImage: "film.stack") }
                    .disabled(shown.isEmpty).help("Flick through these charts, each centred on the day it was added")
                Menu {
                    Button("Copy symbols (one per line)") { copy(shown.map(\.symbol).joined(separator: "\n")) }
                    Button("Copy for TradingView (NSE:SYMBOL, …)") { copy(shown.map { "NSE:" + $0.symbol }.joined(separator: ",")) }
                    Button("Copy table (tab-separated)") { copy(tsv(shown)) }
                    Button("Export CSV…") { exportCSV(shown, name: list.name) }
                } label: { Label("Copy / Export", systemImage: "square.and.arrow.up") }
                .fixedSize()
                Menu {
                    Button("Duplicate list") { duplicate(list) }
                    Menu("Merge into…") {
                        ForEach(vm.watchlists.filter { $0.id != list.id }) { other in Button(other.name) { merge(list, into: other.id) } }
                    }
                    Divider()
                    Button("Remove exited stocks") { setList(list.id) { $0.items.removeAll { $0.exited } } }
                    Button("Remove all stocks", role: .destructive) { setList(list.id) { $0.items.removeAll() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(10)
            TextField("Notes about this list (idea, rules, when to review…)", text: Binding(
                get: { vm.watchlists.indices.contains(li) ? vm.watchlists[li].note : "" },
                set: { v in if vm.watchlists.indices.contains(li) { vm.watchlists[li].note = v } }))
                .textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            if let e = vm.watchError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            switch tab {
            case .stocks: stocksTab(li, list: list, all: all, shown: shown)
            case .performance: WatchPerformanceView(list: list, rows: filtered(all)).environmentObject(vm)
            case .analysis: WatchAnalysisView(rows: filtered(all)).environmentObject(vm)
            case .compare: EmptyView()
            }
        }
    }

    // MARK: Stocks tab

    private func stocksTab(_ li: Int, list: Watchlist, all: [WatchRow], shown: [WatchRow]) -> some View {
        let tags = Array(Set(all.flatMap(\.item.tags))).sorted()
        let sources = Array(Set(all.map { Self.sourceKind($0.item.source) })).sorted()
        let s = WatchSummary(shown)
        return VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Picker("", selection: $status) { ForEach(["Active", "Exited", "All"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Search symbol, note, sector", text: $search).textFieldStyle(.roundedBorder).frame(width: 190)
                if !tags.isEmpty {
                    Picker("Tag", selection: $tagFilter) { Text("All tags").tag(""); ForEach(tags, id: \.self) { Text($0).tag($0) } }.fixedSize()
                }
                if sources.count > 1 {
                    Picker("From", selection: $sourceFilter) { Text("Anywhere").tag(""); ForEach(sources, id: \.self) { Text($0).tag($0) } }.fixedSize()
                }
                columnsMenu
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            summaryStrip(s).padding(.horizontal, 10).padding(.bottom, 6)
            Divider()
            grid(li, list: list, rows: shown)
            if let id = selection.first, selection.count == 1, let ii = vm.watchlists[li].items.firstIndex(where: { $0.id == id }),
               let row = shown.first(where: { $0.id == id }) {
                Divider()
                WatchItemEditor(li: li, ii: ii, row: row).environmentObject(vm).id(id)
            }
            Text("Returns use Yahoo daily closes (unofficial source), from the close on the day added (exited stocks: to their exit close). +5d / +22d = return 5 / 22 trading days after adding. Not financial advice.")
                .font(.caption2).foregroundStyle(.secondary).padding(6)
        }
    }

    private var columnsMenu: some View {
        Menu {
            Section("Columns") {
                ForEach(allCols.filter { $0.optional && !$0.id.hasPrefix("sheet:") }) { c in
                    Button { toggleHidden(c.id) } label: { if hidden.contains(c.id) { Text(c.title) } else { Label(c.title, systemImage: "checkmark") } }
                }
            }
            Menu("Sheet columns (today's values)") {
                ForEach(vm.headers, id: \.self) { h in
                    Button { toggleSheetCol(h) } label: { if sheetCols.contains(h) { Label(h, systemImage: "checkmark") } else { Text(h) } }
                }
            }
        } label: { Label("Columns", systemImage: "tablecells") }
        .fixedSize()
    }

    private func toggleHidden(_ id: String) {
        var h = hidden; if h.contains(id) { h.remove(id) } else { h.insert(id) }
        hiddenRaw = h.sorted().joined(separator: ",")
    }
    private func toggleSheetCol(_ name: String) {
        var c = sheetCols; if let i = c.firstIndex(of: name) { c.remove(at: i) } else { c.append(name) }
        sheetColsRaw = c.joined(separator: "|")
    }

    private func summaryStrip(_ s: WatchSummary) -> some View {
        FlowLayout(spacing: 20, lineSpacing: 6) {
            stat("Average return", pctS(s.avg), color: tone(s.avg), note: "equal weight · \(s.priced) stocks")
            stat("Median", pctS(s.median), color: tone(s.median))
            stat("Win rate", s.winRate.map { String(format: "%.0f%%", $0) } ?? "—", color: .primary)
            stat("vs Nifty (avg)", s.avgAlpha.map { String(format: "%+.2f pts", $0) } ?? "—", color: tone(s.avgAlpha))
            stat("Avg best / worst", "\(pctS(s.avgBest, d: 1)) / \(pctS(s.avgWorst, d: 1))", color: .primary, note: "highest / lowest close since added")
            stat("Reached +10%", s.priced == 0 ? "—" : "\(s.hit10) / \(s.priced)", color: .green,
                 note: s.avgDaysTo10.map { String(format: "in %.0f days on avg", $0) })
            stat("Best", s.best.map { "\($0.symbol) " + pctS($0.r.sinceAdded, d: 1) } ?? "—", color: .green)
            stat("Worst", s.worst.map { "\($0.symbol) " + pctS($0.r.sinceAdded, d: 1) } ?? "—", color: .red)
        }
    }

    // MARK: Grid

    private func grid(_ li: Int, list: Watchlist, rows: [WatchRow]) -> some View {
        let cs = cols
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(cs) { c in
                        Button {
                            if sortKey == c.id { sortDesc.toggle() } else { sortKey = c.id; sortDesc = c.num != nil }
                        } label: {
                            HStack(spacing: 2) {
                                Text(c.title).lineLimit(1)
                                if sortKey == c.id { Image(systemName: sortDesc ? "chevron.down" : "chevron.up").font(.caption2) }
                            }
                            .frame(width: c.width - 8, alignment: c.num != nil ? .trailing : .leading)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { r in
                            gridRow(r, cols: cs)
                                .background(selection.contains(r.id) ? Color.accentColor.opacity(0.25) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { vm.openChart(r.symbol, queue: rows.map(\.symbol), openWindow: openWindow) }
                                .onTapGesture { click(r.id, rows) }
                                .contextMenu { rowMenu(li, list: list, ids: selection.contains(r.id) ? selection : [r.id], rows: rows) }
                        }
                    }
                }
            }
        }
        .onDeleteCommand { remove(selection, from: li) }
    }

    private func gridRow(_ r: WatchRow, cols: [Col]) -> some View {
        HStack(spacing: 0) {
            ForEach(cols) { c in
                Group {
                    if c.id == "symbol" {
                        HStack(spacing: 4) {
                            SymbolWithDots(symbol: r.symbol, bold: false)
                            if r.item.exited { Text("exited").font(.caption2).foregroundStyle(.secondary) }
                            if !r.item.note.isEmpty { Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary).help(r.item.note) }
                        }
                    } else if c.pct, let f = c.num {
                        pct(f(r), bold: c.id == "ret")
                    } else if let f = c.num, c.id.hasPrefix("sheet:") == false {
                        let v = f(r)
                        Text(v.map { c.id == "days" || c.id == "to10" ? String(Int($0)) : String(format: "%.2f", $0) } ?? "—")
                            .monospacedDigit().foregroundStyle(v == nil ? .secondary : .primary)
                    } else if let t = c.text {
                        Text(t(r)).lineLimit(1).foregroundStyle(c.id == "status" && r.r.stopHit ? Color.red : (c.id == "status" && r.r.targetHit ? Color.green : Color.primary))
                    }
                }
                .frame(width: c.width - 8, alignment: c.num != nil && !c.id.hasPrefix("sheet:") ? .trailing : .leading)
                .padding(.horizontal, 4)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private func click(_ id: UUID, _ rows: [WatchRow]) {
        let m = NSEvent.modifierFlags
        if m.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if m.contains(.shift), let a = anchor, let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == id }) {
            selection = Set(rows[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = [id]; anchor = id
        }
    }

    @ViewBuilder private func rowMenu(_ li: Int, list: Watchlist, ids: Set<UUID>, rows: [WatchRow]) -> some View {
        let picked = rows.filter { ids.contains($0.id) }
        if let first = picked.first {
            Button("Open chart of \(first.symbol)") { vm.openChart(first.symbol, queue: rows.map(\.symbol), openWindow: openWindow) }
            Button("Chart Reel of \(picked.count == 1 ? "this list" : "\(picked.count) stocks")") { openReel(picked.count == 1 ? rows : picked) }
            Divider()
        }
        Button("Mark exited at the latest close") { markExited(ids, li: li) }
        Button("Reopen (not exited)") { setItems(ids, li: li) { $0.exitDay = nil; $0.exitPrice = nil } }
        Menu("Move to") {
            ForEach(vm.watchlists.filter { $0.id != list.id }) { other in Button(other.name) { transfer(ids, from: li, to: other.id, move: true) } }
        }
        Menu("Copy to") {
            ForEach(vm.watchlists.filter { $0.id != list.id }) { other in Button(other.name) { transfer(ids, from: li, to: other.id, move: false) } }
        }
        Menu("Tag") {
            let existing = Array(Set(vm.watchlists.flatMap { $0.items.flatMap(\.tags) })).sorted()
            ForEach(existing, id: \.self) { t in Button(t) { setItems(ids, li: li) { if !$0.tags.contains(t) { $0.tags.append(t) } } } }
            if !existing.isEmpty { Divider() }
            ForEach(["Breakout", "Delivery", "Multibagger", "Swing", "Long term"], id: \.self) { t in
                if !existing.contains(t) { Button(t) { setItems(ids, li: li) { if !$0.tags.contains(t) { $0.tags.append(t) } } } }
            }
            Divider()
            Button("Clear tags") { setItems(ids, li: li) { $0.tags = [] } }
        }
        Button("Re-price at today's close (restart the clock)") {
            setItems(ids, li: li) { it in
                if let s = vm.priceBook.series(for: it.symbol), let p = s.closes.last, let d = s.lastDay {
                    it.addedDay = d; it.addedPrice = p; it.priceSource = "Yahoo close \(d)"; it.addedAt = Date()
                }
            }
        }
        Divider()
        Button("Screenshots…") { if let s = picked.first?.symbol { vm.shotSymbol = s; openWindow(id: "shots") } }.disabled(picked.count != 1)
        Button("Copy symbols") { copy(picked.map(\.symbol).joined(separator: "\n")) }
        Button("Remove \(ids.count) from list", role: .destructive) { remove(ids, from: li) }
    }

    // MARK: Actions

    private func setList(_ id: UUID, _ f: (inout Watchlist) -> Void) {
        if let i = vm.watchlists.firstIndex(where: { $0.id == id }) { f(&vm.watchlists[i]) }
    }
    private func setItems(_ ids: Set<UUID>, li: Int, _ f: (inout WatchItem) -> Void) {
        guard vm.watchlists.indices.contains(li) else { return }
        var l = vm.watchlists[li]
        for k in l.items.indices where ids.contains(l.items[k].id) { f(&l.items[k]) }
        vm.watchlists[li] = l
    }
    private func markExited(_ ids: Set<UUID>, li: Int) {
        setItems(ids, li: li) { it in
            guard !it.exited else { return }
            if let s = vm.priceBook.series(for: it.symbol), let p = s.closes.last, let d = s.lastDay { it.exitDay = d; it.exitPrice = p }
            else { it.exitDay = HistoryStore.dayKey(Date()) }
        }
    }
    private func transfer(_ ids: Set<UUID>, from li: Int, to target: UUID, move: Bool) {
        guard vm.watchlists.indices.contains(li), let ti = vm.watchlists.firstIndex(where: { $0.id == target }) else { return }
        let items = vm.watchlists[li].items.filter { ids.contains($0.id) }
        let have = Set(vm.watchlists[ti].items.filter { !$0.exited }.map { $0.symbol.uppercased() })
        for var it in items where !have.contains(it.symbol.uppercased()) { it.id = UUID(); vm.watchlists[ti].items.append(it) }
        if move { remove(ids, from: li) }
    }
    private func duplicate(_ list: Watchlist) {
        var c = Watchlist(name: list.name + " copy")
        c.items = list.items.map { var x = $0; x.id = UUID(); return x }
        c.note = list.note; c.color = list.color
        vm.watchlists.append(c); vm.selectedWatchlistID = c.id
    }
    private func merge(_ list: Watchlist, into target: UUID) {
        guard let li = vm.watchlists.firstIndex(where: { $0.id == list.id }) else { return }
        transfer(Set(list.items.map(\.id)), from: li, to: target, move: false)
        vm.selectedWatchlistID = target
    }
    private func rename(_ id: UUID) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { setList(id) { $0.name = n } }
        renaming = nil
    }
    private func delete(_ id: UUID) {
        guard vm.watchlists.count > 1 else { return }
        vm.watchlists.removeAll { $0.id == id }
        vm.selectedWatchlistID = vm.watchlists.first?.id
    }
    private func remove(_ ids: Set<UUID>, from li: Int) {
        guard vm.watchlists.indices.contains(li) else { return }
        vm.watchlists[li].items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Chart Reel (Chart 1 + Delivery) of these stocks, each centred on the day it was added.
    private func openReel(_ rows: [WatchRow]) {
        ScanCenter.shared.reel = rows.map { r in
            (r.symbol, (r.item.source.isEmpty ? "added" : r.item.source) + " · " + pctS(r.r.sinceAdded, d: 1), r.item.addedDay)
        }
        let d = UserDefaults.standard
        d.set(ReelSource.scan.rawValue, forKey: "reel.source")
        d.set("", forKey: "reel.mbStart")
        d.set(UUID().uuidString + "|", forKey: "reel.jump")
        openWindow(id: "reel")
    }

    // MARK: Small views

    private func stat(_ title: String, _ value: String, color: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func tone(_ v: Double?) -> Color { v == nil ? .secondary : (v! >= 0 ? .green : .red) }
    private func pctS(_ v: Double?, d: Int = 2) -> String { v.map { String(format: "%+.\(d)f%%", $0) } ?? "—" }
    private func pct(_ v: Double?, bold: Bool = false) -> some View {
        Text(pctS(v)).monospacedDigit().fontWeight(bold ? .semibold : .regular).foregroundStyle(tone(v))
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add symbols").font(.headline)
            Text("Paste symbols separated by commas, spaces or new lines (TCS, INFY or NSE:TCS). Priced at the data day's close.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $pasteText).font(.system(.body, design: .monospaced)).frame(height: 160).border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { showPaste = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let syms = pasteText.components(separatedBy: CharacterSet(charactersIn: ",; \n\t")).filter { !$0.isEmpty }
                    vm.addSymbols(syms)
                    showPaste = false
                    vm.fetchWatchPrices()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 420)
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
    private func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }

    private func tsv(_ rows: [WatchRow], sep: String = "\t") -> String {
        let header = ["Symbol", "Added from", "Tags", "Sector", "Added", "Days", "Added price", "Now", "Return %", "vs Nifty pts", "1D %", "5D %", "1M %",
                      "+5d %", "+22d %", "Best %", "Worst %", "From best %", "Target", "Stop", "Exited", "Exit price", "Note"]
        let clean: (String) -> String = { $0.replacingOccurrences(of: sep, with: " ").replacingOccurrences(of: "\n", with: " ") }
        let lines = rows.map { r in
            [r.symbol, clean(r.item.source), clean(r.item.tags.joined(separator: " ")), clean(r.sector), r.item.addedDay,
             r.r.tradingDays.map(String.init) ?? "", f(r.item.addedPrice), f(r.r.now), f(r.r.sinceAdded), f(r.alpha),
             f(r.r.day1), f(r.r.day5), f(r.r.month1), f(r.r.fwd5), f(r.r.fwd22), f(r.r.maxSinceAdded), f(r.r.worstSinceAdded), f(r.r.fromPeak),
             f(r.item.target), f(r.item.stop), r.item.exitDay ?? "", f(r.item.exitPrice), clean(r.item.note)].joined(separator: sep)
        }
        return ([header.joined(separator: sep)] + lines).joined(separator: "\n")
    }

    private func exportCSV(_ rows: [WatchRow], name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = name + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? tsv(rows, sep: ",").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - One stock: note, tags, target, stop, exit, price since added

private struct WatchItemEditor: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let li: Int
    let ii: Int
    let row: WatchRow
    @State private var tagsText = ""
    @State private var target = ""
    @State private var stop = ""

    private func update(_ f: (inout WatchItem) -> Void) {
        guard vm.watchlists.indices.contains(li), vm.watchlists[li].items.indices.contains(ii) else { return }
        f(&vm.watchlists[li].items[ii])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.symbol).font(.headline)
                    Text("added \(row.item.addedDay)" + (row.item.source.isEmpty ? "" : " from \(row.item.source)")).font(.caption).foregroundStyle(.secondary)
                    if row.item.exited { Text("exited \(row.item.exitDay ?? "")").font(.caption).foregroundStyle(.orange) }
                }
                TextField("Note", text: Binding(get: { row.item.note }, set: { v in update { $0.note = v } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                HStack {
                    TextField("Tags (comma)", text: $tagsText).textFieldStyle(.roundedBorder).frame(width: 170)
                        .onSubmit { update { $0.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
                    TextField("Target ₹", text: $target).textFieldStyle(.roundedBorder).frame(width: 80)
                        .onSubmit { update { $0.target = Double(target) } }
                    TextField("Stop ₹", text: $stop).textFieldStyle(.roundedBorder).frame(width: 80)
                        .onSubmit { update { $0.stop = Double(stop) } }
                    Button("Save") {
                        update {
                            $0.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            $0.target = Double(target); $0.stop = Double(stop)
                        }
                    }
                }
                .controlSize(.small)
                Text(row.item.priceSource.isEmpty ? "No starting price yet — Refresh prices" : "Starting price from \(row.item.priceSource)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 320, maxWidth: 460, alignment: .leading)
            priceChart.frame(minWidth: 260, maxWidth: .infinity).frame(height: 120)
        }
        .padding(10)
        .onAppear {
            tagsText = row.item.tags.joined(separator: ", ")
            target = row.item.target.map { String(format: "%.2f", $0) } ?? ""
            stop = row.item.stop.map { String(format: "%.2f", $0) } ?? ""
        }
    }

    private struct P: Identifiable { let d: Date; let v: Double; var id: Date { d } }

    @ViewBuilder private var priceChart: some View {
        if let s = vm.priceBook.series(for: row.symbol), let i = s.index(onOrBefore: row.item.addedDay) {
            let from = max(0, i - 20)
            let pts = (from..<s.closes.count).map { P(d: WatchCurve.date(s.days[$0]), v: s.closes[$0]) }
            Chart {
                ForEach(pts) { p in LineMark(x: .value("Day", p.d), y: .value("₹", p.v)) }
                RuleMark(x: .value("Added", WatchCurve.date(row.item.addedDay))).foregroundStyle(.blue.opacity(0.6))
                    .annotation(position: .top, alignment: .leading) { Text("added").font(.caption2).foregroundStyle(.blue) }
                if let p = row.item.addedPrice { RuleMark(y: .value("Added ₹", p)).foregroundStyle(Color.gray.opacity(0.6)).lineStyle(StrokeStyle(dash: [3, 3])) }
                if let t = row.item.target { RuleMark(y: .value("Target", t)).foregroundStyle(.green.opacity(0.7)) }
                if let st = row.item.stop { RuleMark(y: .value("Stop", st)).foregroundStyle(.red.opacity(0.7)) }
                if let e = row.item.exitDay { RuleMark(x: .value("Exit", WatchCurve.date(e))).foregroundStyle(.orange.opacity(0.7)) }
            }
            .chartYScale(domain: .automatic(includesZero: false))
        } else {
            Text("No Yahoo prices for \(row.symbol) yet").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

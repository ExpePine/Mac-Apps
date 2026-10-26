import SwiftUI

/// "Filter" screen: only the columns you choose, advanced filters, sorting and cell colors.
struct FilterView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showColumns = false
    @AppStorage("filterConditionsVisible") private var conditionsVisible = true
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var flashedDay: String?
    @StateObject private var finder = TableFinder()

    private var isCollapsed: Bool { visibility == .detailOnly }

    private func openReel(_ source: ReelSource, value: String? = nil, column: String? = nil, op: String = "=", sequence: Bool = false) {
        let d = UserDefaults.standard
        d.set(source.rawValue, forKey: "reel.source")
        if let value {
            d.set(column ?? vm.settings.triggerColumn, forKey: "reel.column")
            d.set(op, forKey: "reel.op")
            d.set(value, forKey: "reel.value")
        }
        if sequence { d.set(ReelLayout.sequence.rawValue, forKey: "reel.layout") }      // Chart 1 → Chart 2, then next stock
        d.set(UUID().uuidString + "|", forKey: "reel.jump")                               // restart an open reel
        openWindow(id: "reel")
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            FilterSidebar(showColumns: $showColumns)
                .navigationSplitViewColumnWidth(min: 320, ideal: 440, max: 620)
        } detail: {
            VStack(spacing: 0) {
                AlertsBanner()
                PastDayBanner()
                if !vm.hasData {
                    placeholder
                } else {
                    if finder.isVisible { FindBar(finder: finder); Divider() }
                    if vm.tgMode { TGStrip() }
                    if let note = vm.flashSummary { FlashToast(text: note) }
                    if !vm.filterIssues.isEmpty {
                        issuesBanner
                        Divider()
                    }
                    SheetTableView(headers: vm.headers,
                                   originalHeaders: vm.table.originalHeaders,
                                   columns: vm.filterColumnIndices,
                                   rows: vm.filterRows,
                                   version: vm.filterVersion,
                                   emphasizedColumn: vm.table.index(of: vm.settings.triggerColumn),
                                   sortColumn: vm.table.index(of: vm.settings.filterSortColumn),
                                   sortDescending: vm.settings.filterSortDescending,
                                   painter: vm.painter,
                                   frozenColumns: vm.settings.frozenColumns,
                                   onHeaderClick: { index in
                                       let name = vm.headers[index]
                                       if vm.table.index(of: vm.settings.filterSortColumn) == index {
                                           vm.settings.filterSortDescending.toggle()
                                       } else {
                                           vm.settings.filterSortColumn = name
                                           vm.settings.filterSortDescending = true
                                       }
                                   },
                                   onSelectRow: { row in
                                       vm.selectStock(from: row)
                                       if let row { ChartPeek.shared.preload(vm.rowKey(row), vm: vm) }
                                   },
                                   onDoubleClickRow: { row in vm.openChart(vm.rowKey(row), queue: vm.filterRows.map { vm.rowKey($0) }, openWindow: openWindow) },
                                   onHoverChart: ChartPeek.enabled ? { row, chart in
                                       ChartPeek.shared.preload(vm.rowKey(row), vm: vm)
                                       ChartPeek.shared.show(vm.rowKey(row), chart: chart, vm: vm)        // blue dot = Chart 1, orange = Chart 2
                                   } : nil,
                                   chartDotsAfter: vm.labelIndex,
                                   columnMenu: { index in
                                       AnyView(ColumnMenuView(column: index).environmentObject(vm))
                                   },
                                   markedColumns: vm.columnsWithRules,
                                   eColor: { row in (vm.eStatus[row.id] ?? .none).nsColor },
                                   ePanel: { row in
                                       AnyView(StockRulesView(stock: vm.stockName(row), row: row).environmentObject(vm))
                                   },
                                   flash: vm.flashSpec,
                                   sColor: { vm.sColor($0) },
                                   onSClick: { row in
                                       vm.shotSymbol = vm.rowKey(row)
                                       openWindow(id: "shots")
                                   },
                                   findQuery: finder.activeQuery,
                                   findCurrent: finder.currentMatch,
                                   onSelectRows: { vm.filterSelection = $0 },
                                   rowMenu: { row in vm.rowMenu(row, selection: vm.filterSelection, openWindow: openWindow, queue: vm.filterRows) },
                                   onColumnOrder: { order in vm.settings.filterColumns = order.map { vm.headers[$0] } },
                                   onHideColumn: { index in
                                       vm.settings.filterColumns = vm.filterColumnIndices.filter { $0 != index }.map { vm.headers[$0] }
                                   },
                                   hiddenColumns: vm.headers.indices.filter { !vm.filterColumnIndices.contains($0) },
                                   onShowColumn: { index in
                                       vm.settings.filterColumns = vm.filterColumnIndices.map { vm.headers[$0] } + [vm.headers[index]]
                                   },
                                   onChooseColumns: { showColumns = true })
                    if vm.showTimeline {
                        Divider()
                        TimelineBar()
                    }
                    Divider()
                    statusBar
                }
            }
        }
        .navigationTitle("Filter")
        .hidingSystemSidebarToggle()
        .onAppear {
            visibility = conditionsVisible ? .all : .detailOnly
            flashedDay = nil
            flashIfNewDay()
        }
        .onChange(of: vm.filterVersion) { _ in
            flashIfNewDay()
            finder.update(rows: vm.filterRows, columns: vm.filterColumnIndices)
        }
        .onChange(of: finder.isVisible) { visible in
            if visible { finder.update(rows: vm.filterRows, columns: vm.filterColumnIndices) }
        }
        .background(WindowReader { window in
            FindRouter.register(window) { [weak finder] in finder?.show() }
        })
        .onChange(of: visibility) { newValue in conditionsVisible = newValue != .detailOnly }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        visibility = isCollapsed ? .all : .detailOnly
                    }
                } label: {
                    Label(isCollapsed ? "Show conditions" : "Hide conditions", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .help(isCollapsed ? "Show the conditions pane (⌥⌘S)" : "Hide the conditions pane to see the full table (⌥⌘S)")
            }
            ToolbarItemGroup {
                Button {
                    vm.showRulesEditor = true
                } label: {
                    Label("Rules", systemImage: "envelope.badge")
                }
                .help("All Email / Alert rules (per-stock rules are on each row's E button)")
                Button {
                    vm.toggleTG()
                } label: {
                    Text("TG").font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(vm.tgMode ? Color.white : Color.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(vm.tgMode ? Color.green : Color.green.opacity(0.12)))
                }
                .help("Top Gainers: only stocks up more than \(String(format: "%g", vm.settings.tgThreshold))% that day (same filters and colors). Uses Yahoo prices, else the sheet's change% column.")
                Button {
                    openWindow(id: "nn")
                } label: {
                    Text("N").font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.purple)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.purple.opacity(0.12)))
                }
                .help("Neural Net: filter-value combinations shared by monthly top gainers (≥ \(vm.settings.nnGainThreshold)% in a month)")
                Menu {
                    Button("This Filter's stocks") { openReel(.filter) }
                    Button("\(vm.settings.triggerColumn) = 1") { openReel(.column, value: "1") }
                    Button("\(vm.settings.triggerColumn) = 0") { openReel(.column, value: "0") }
                    Button("Daily gainers") { openReel(.gainers) }
                    Divider()
                    Section("Chart 1 → Chart 2 for each stock") {
                        Button("\(vm.settings.triggerColumn) has a value") { openReel(.column, value: "", op: "has a value", sequence: true) }
                        Button("This Filter's stocks") { openReel(.filter, sequence: true) }
                        Menu("Any column has a value…") {
                            ForEach(vm.filterColumnIndices.map { vm.headers[$0] }, id: \.self) { h in
                                Button(h) { openReel(.column, value: "", column: h, op: "has a value", sequence: true) }
                            }
                        }
                        Button("Any column / value… (set it in the reel)") { openReel(.column, value: "1", sequence: true) }
                    }
                } label: {
                    Label("Chart Reel", systemImage: "film.stack")
                } primaryAction: { openReel(.filter) }
                .help("Flick through charts with a slider — click for this Filter's stocks, or pick a list (⌥⌘R)")
                Button {
                    openWindow(id: "changes")
                } label: {
                    Label("Changes", systemImage: "rectangle.grid.2x2")
                }
                .help("Cards showing what changed since the previous day (⇧⌘8)")
                Button {
                    openWindow(id: "gainers")
                } label: {
                    Label("Gainers", systemImage: "flame")
                }
                .help("Daily gainers with NIFTY / SENSEX charts and news reasons (⇧⌘G)")
                Button {
                    openWindow(id: "sectors")
                } label: {
                    Label(vm.unseenRegimeCount > 0 ? "Sectors (\(vm.unseenRegimeCount))" : "Sectors",
                          systemImage: vm.unseenRegimeCount > 0 ? "square.grid.3x3.fill" : "square.grid.3x3")
                }
                .help(vm.unseenRegimeCount > 0 ? "\(vm.unseenRegimeCount) new sector regime change(s) (⇧⌘0)" : "Sector momentum & regime changes (⇧⌘0)")
                Button {
                    openWindow(id: "perf")
                } label: {
                    Label("Performance", systemImage: "chart.line.uptrend.xyaxis")
                }
                .help("How stocks did after an event such as D_Trigger (⇧⌘9)")
                WatchlistMenu()
                AlertsButton()
                AnimateButton()
                FreezeMenu()
                Button {
                    showColumns = true
                } label: {
                    Label("Columns", systemImage: "rectangle.split.3x1")
                }
                .help("Choose which columns the Filter shows and their order — hidden ones stay in Data Import")
                StreakButton()
                T3Button()
                PriceT3Button()
                PeekMenu()


                Button {
                    vm.importNow()
                } label: {
                    Label("Re-import", systemImage: "square.and.arrow.down")
                }
                .disabled(vm.isLoading || vm.settings.sheetLink.isEmpty)

                Button {
                    openWindow(id: "data")
                } label: {
                    Label("Data Import", systemImage: "tablecells")
                }
            }
        }
        .sheet(isPresented: $showColumns) {
            ColumnChooser().environmentObject(vm)
        }
        .sheet(isPresented: $vm.showRulesEditor) {
            EmailRulesSheet().environmentObject(vm)
        }
    }

    /// Flash what changed since the previous stored day, once per data day while this window is open.
    private func flashIfNewDay() {
        guard vm.hasData, vm.timelineIndex == nil, !vm.filterRows.isEmpty else { return }
        let key = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        guard flashedDay != key else { return }
        flashedDay = key
        vm.flashChangesSincePreviousDay()
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No data imported yet").font(.title3.bold())
            Button {
                vm.importNow()
            } label: {
                Label("Import data", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isLoading || vm.settings.sheetLink.isEmpty)
            if vm.settings.sheetLink.isEmpty {
                Text("Add your sheet link in the Data Import window first.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var issuesBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(vm.filterIssues.prefix(4), id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Conditions with problems are skipped.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if vm.isFiltering { ProgressView().controlSize(.small) }
            Text("\(vm.filterRows.count) of \(vm.rows.count) rows")
                .fontWeight(.medium)
            if isCollapsed {
                let summary = ScreenerViewModel.describe(vm.settings.filterGroup)
                Text(summary.isEmpty ? "No filter" : "Filter: \(summary)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(summary)
                Button("Edit") {
                    withAnimation(.easeInOut(duration: 0.2)) { visibility = .all }
                }
                .buttonStyle(.link)
            }
            Text("\(vm.filterColumnIndices.count) columns")
            Text("\(vm.settings.filterGroup.activeCount) conditions")
            Spacer()
            Text("Sorted by \(vm.settings.filterSortColumn) \(vm.settings.filterSortDescending ? "▼" : "▲") · click a header to change")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Sidebar

struct FilterSidebar: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Binding var showColumns: Bool
    @State private var showNames = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("\(vm.filterColumnIndices.count) visible columns")
                    Spacer()
                    Button("Rename…") { showNames = true }
                        .help("Give columns like var 1 … var 10 their real names")
                    Button("Choose columns…") { showColumns = true }
                }
                ColumnPicker(title: "Sort by", selection: $vm.settings.filterSortColumn)
                Picker("Order", selection: $vm.settings.filterSortDescending) {
                    Text("Newest / highest first").tag(true)
                    Text("Oldest / lowest first").tag(false)
                }
                ColumnPicker(title: "Trigger column", selection: $vm.settings.triggerColumn)
                Picker("Stock name column", selection: $vm.settings.labelColumn) {
                    Text("First column\(vm.headers.first.map { " (\($0))" } ?? "")").tag("")
                    ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Columns & sorting")
            }

            Section {
                FilterGroupEditor(group: $vm.settings.filterGroup, columns: vm.headers, isRoot: true, onDelete: {})
                HStack {
                    if vm.isFiltering { ProgressView().controlSize(.small) }
                    Text("\(vm.filterRows.count) of \(vm.rows.count) rows match")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear all") {
                        vm.settings.filterGroup = FilterGroup()
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.settings.filterGroup.conditions.isEmpty && vm.settings.filterGroup.groups.isEmpty)
                }
            } header: {
                HStack {
                    Text("Advanced filter")
                    Spacer()
                    FormulaHelpButton()
                }
            } footer: {
                Text("Combine conditions with All (AND), Any (OR) or None (NOT). Add groups to nest them, compare a column with another column (× a factor), or write a formula.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($vm.settings.cellRules) { $rule in
                    CellRuleRow(rule: $rule, columns: vm.filterColumnIndices.map { vm.headers[$0] }) {
                        vm.settings.cellRules.removeAll { $0.id == rule.id }
                    }
                }
                HStack {
                    Button {
                        vm.settings.cellRules.append(CellRule(condition: Rule(column: defaultColorColumn), shade: .green))
                    } label: {
                        Label("Add color rule", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        let col = defaultColorColumn
                        vm.settings.cellRules.append(CellRule(condition: Rule(column: col, op: .greaterThan, value: "0"), shade: .green))
                        vm.settings.cellRules.append(CellRule(condition: Rule(column: col, op: .lessThan, value: "0"), shade: .red))
                    } label: {
                        Label("Green above / red below", systemImage: "plusminus")
                    }
                    .help("Adds two rules for one column: above a value = green, below = red, otherwise neutral")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Cell colors — per column")
            } footer: {
                Text("Each rule colors only cells in its own column. If several rules for a column match, the first wins; anything else stays neutral.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showNames) {
            ColumnNamesEditor().environmentObject(vm)
        }
    }

    private var defaultColorColumn: String {
        let cols = vm.filterColumnIndices
        let trigger = vm.table.index(of: vm.settings.triggerColumn)
        let pick = cols.first { $0 != trigger && $0 != vm.labelIndex && vm.rows.first?.number($0) != nil }
            ?? cols.first
        return pick.map { vm.headers[$0] } ?? ""
    }
}

// MARK: - Column chooser

struct ColumnChooser: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visible columns").font(.title2.bold())
            Text("Tick the columns to show on the Filter screen. Drag in the right list to change their order. Columns you leave out are only hidden here — Data Import always shows every column, including the computed ones (DLVR, Safety, DQ_PRANK, JUMP, DELSMA, STREAK). Tip: right-click a column header in the Filter to hide it quickly, or drag headers to reorder.")
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search columns", text: $search)
                        .textFieldStyle(.roundedBorder)
                    List {
                        ForEach(filteredHeaders, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { selected.contains(name) },
                                set: { on in
                                    if on { if !selected.contains(name) { selected.append(name) } }
                                    else { selected.removeAll { $0 == name } }
                                }
                            ))
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    HStack {
                        Button("Select all") { selected = vm.headers }
                        Button("Clear") { selected = [] }
                        Button("\(vm.settings.triggerColumn) and after") {
                            if let t = vm.table.index(of: vm.settings.triggerColumn) {
                                selected = Array(vm.headers[t...])
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .frame(width: 300)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Shown, in this order (\(selected.count))").font(.headline)
                    List {
                        ForEach(selected, id: \.self) { name in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                Text(name)
                                Spacer()
                                Button {
                                    selected.removeAll { $0 == name }
                                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onMove { from, to in selected.move(fromOffsets: from, toOffset: to) }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
                .frame(width: 300)
            }
            .frame(height: 380)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    vm.settings.filterColumns = selected
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            selected = vm.filterColumnIndices.map { vm.headers[$0] }
        }
    }

    private var filteredHeaders: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? vm.headers : vm.headers.filter { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension View {
    /// macOS 14+ adds its own sidebar button; we use ours (with a clearer label), so hide the system one.
    @ViewBuilder
    func hidingSystemSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}


/// Small orange line on top while TG is on: the day, how many top gainers, and their total Safety_limit.
struct TGStrip: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text("TG").font(.caption.bold()).foregroundStyle(.green)
            if let s = vm.tgSummary {
                Text("\(s.day) · \(s.count) stocks > \(String(format: "%g", vm.settings.tgThreshold))%")
                if let sum = s.safetySum {
                    Text("Σ Safety_limit \(sum.formatted(.number.precision(.fractionLength(0...2))))")
                        .fontWeight(.semibold)
                } else {
                    Text("no Safety_limit column")
                }
                Spacer()
                Text(source(s)).foregroundStyle(.secondary)
            } else {
                Text("Working out top gainers…")
                Spacer()
            }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Color.orange.opacity(0.07))
    }

    private func source(_ s: TGSummary) -> String {
        if s.fromYahoo > 0 && s.fromSheet == 0 { return "change% from Yahoo" }
        if s.fromYahoo == 0 { return vm.priceBook.series.isEmpty ? "change% from the sheet (fetch Yahoo prices in N)" : "change% from the sheet" }
        return "change%: \(s.fromYahoo) Yahoo, \(s.fromSheet) sheet"
    }
}

/// "Since yesterday" note shown while the changed cells flash.
struct FlashToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(text)
            Spacer()
            HStack(spacing: 6) {
                swatch(.systemGreen, "up"); swatch(.systemRed, "down"); swatch(.systemBlue, "new")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.10))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func swatch(_ c: NSColor, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: c).opacity(0.6)).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
        }
    }
}


/// Toolbar menu: add the selected / shown stocks to a watchlist, or open the watchlists.
struct WatchlistMenu: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var lastAdded: String?

    var body: some View {
        Menu {
            ForEach(vm.watchlists) { list in
                Section(list.name) {
                    Button("Add selected (\(vm.filterSelection.count))") { add(vm.filterSelection, list) }
                        .disabled(vm.filterSelection.isEmpty)
                    Button("Add all shown (\(vm.filterRows.count))") { add(vm.filterRows, list) }
                        .disabled(vm.filterRows.isEmpty)
                }
            }
            Divider()
            Button("New watchlist") { vm.newWatchlist(named: "") }
            Button("Open Watchlists  ⇧⌘5") { openWindow(id: "watch") }
        } label: {
            Label("Watchlist", systemImage: "star")
        }
        .help(lastAdded ?? "Add stocks to a watchlist (select rows with ⌘-click / ⇧-click, or right-click a row)")
    }

    private func add(_ rows: [SheetRow], _ list: Watchlist) {
        let n = vm.addToWatchlist(rows, listID: list.id)
        lastAdded = "Added \(n) to “\(list.name)”"
        openWindow(id: "watch")
    }
}

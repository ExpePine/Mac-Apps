import SwiftUI

/// "Filter" screen: only the columns you choose, advanced filters, sorting and cell colors.
struct FilterView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showColumns = false
    @AppStorage("filterConditionsVisible") private var conditionsVisible = true
    @State private var visibility: NavigationSplitViewVisibility = .all

    private var isCollapsed: Bool { visibility == .detailOnly }

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
                                   onSelectRow: { vm.selectStock(from: $0) },
                                   columnMenu: { index in
                                       AnyView(ColumnMenuView(column: index).environmentObject(vm))
                                   },
                                   markedColumns: vm.columnsWithRules,
                                   eColor: { row in (vm.eStatus[row.id] ?? .none).nsColor },
                                   ePanel: { row in
                                       AnyView(StockRulesView(stock: vm.stockName(row), row: row).environmentObject(vm))
                                   })
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
        .onAppear { visibility = conditionsVisible ? .all : .detailOnly }
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
                AlertsButton()
                AnimateButton()
                FreezeMenu()
                Button {
                    showColumns = true
                } label: {
                    Label("Columns", systemImage: "rectangle.split.3x1")
                }
                .help("Choose which columns are visible and their order")

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
            Text("Tick the columns to show on the Filter screen. Drag in the right list to change their order.")
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

import SwiftUI

/// The "Active Filter" window: rows sorted by D_Trigger, D_Trigger and the columns after it,
/// its own row filters, and per-column cell colors.
struct ActiveFilterView: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        NavigationSplitView {
            ActiveFilterSidebar()
                .navigationSplitViewColumnWidth(min: 340, ideal: 390)
        } detail: {
            VStack(spacing: 0) {
                if vm.rows.isEmpty {
                    placeholder("No data yet",
                                "Open the Data window and add your sheet link. Data appears here automatically.")
                } else if vm.triggerHeader == nil {
                    placeholder("Column \"\(vm.settings.triggerColumn)\" not found",
                                "Pick the trigger column at the top of the sidebar.")
                } else {
                    ActiveGridView()
                    Divider()
                    statusBar
                }
            }
        }
        .navigationTitle("Active Filter")
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $vm.settings.triggerSortDescending) {
                    Label("Newest / highest first", systemImage: "arrow.down").tag(true)
                    Label("Oldest / lowest first", systemImage: "arrow.up").tag(false)
                }
                .pickerStyle(.segmented)
                .help("Sort order for \(vm.settings.triggerColumn)")

                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(vm.isLoading || vm.settings.sheetLink.isEmpty)
            }
        }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(vm.activeRows.count) rows")
            if let trigger = vm.triggerHeader {
                Text("sorted by \(trigger) \(vm.settings.triggerSortDescending ? "↓" : "↑")")
            }
            Spacer()
            Text("\(vm.settings.cellRules.filter { $0.condition.isEnabled }.count) color rules")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Grid with per-cell shading

struct ActiveGridView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    private let columnWidth: CGFloat = 120

    var body: some View {
        let rows = vm.activeRows
        let columns = vm.activeColumns
        let trigger = vm.triggerHeader

        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 0) {
                            ForEach(columns, id: \.self) { column in
                                cell(row: row, column: column, index: index, isTrigger: column == trigger)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(columns, id: \.self) { column in
                            Text(column)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .foregroundStyle(column == trigger ? Color.accentColor : Color.primary)
                                .frame(width: columnWidth, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 7)
                                .help(column)
                        }
                    }
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
    }

    private func cell(row: SheetRow, column: String, index: Int, isTrigger: Bool) -> some View {
        let text = row.values[column] ?? ""
        let shade = vm.shade(for: row, column: column)
        return Text(text)
            .lineLimit(1)
            .fontWeight(isTrigger ? .semibold : .regular)
            .frame(width: columnWidth, alignment: NumberParser.parse(text) != nil ? .trailing : .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(shade?.color ?? Color.primary.opacity(index.isMultiple(of: 2) ? 0 : 0.035))
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1)
            }
            .help(text)
            .textSelection(.enabled)
    }
}

// MARK: - Sidebar: columns, row filters, cell colors

struct ActiveFilterSidebar: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        Form {
            Section {
                Picker("Trigger column", selection: $vm.settings.triggerColumn) {
                    if vm.resolveColumn(vm.settings.triggerColumn) == nil {
                        Text(vm.settings.triggerColumn.isEmpty ? "Choose…" : "\(vm.settings.triggerColumn) (not found)")
                            .tag(vm.settings.triggerColumn)
                    }
                    ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
                }
                Picker("Stock name column", selection: $vm.settings.labelColumn) {
                    Text("First column\(vm.headers.first.map { " (\($0))" } ?? "")").tag("")
                    ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Only rows that have a \(vm.settings.triggerColumn) value", isOn: $vm.settings.onlyRowsWithTrigger)
            } header: {
                Text("Columns")
            } footer: {
                Text("Shows the trigger column and every column after it in the sheet, sorted by the trigger column.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Match", selection: $vm.settings.activeMatchMode) {
                    ForEach(MatchMode.allCases) { Text($0.rawValue).tag($0) }
                }
                ForEach($vm.settings.activeFilterRules) { $rule in
                    RuleRow(rule: $rule, columns: vm.headers, showColor: false) {
                        vm.settings.activeFilterRules.removeAll { $0.id == rule.id }
                    }
                }
                Button {
                    vm.settings.activeFilterRules.append(Rule(column: vm.triggerHeader ?? vm.headers.first ?? ""))
                } label: {
                    Label("Add filter condition", systemImage: "plus")
                }
            } header: {
                Text("Filter — show only rows where")
            }

            Section {
                ForEach($vm.settings.cellRules) { $rule in
                    CellRuleRow(rule: $rule, columns: vm.activeColumns) {
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
                        Label("Add green-above / red-below pair", systemImage: "plusminus")
                    }
                    .help("Adds two rules for one column: above a value = green, below a value = red, otherwise neutral")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Cell colors — per column")
            } footer: {
                Text("Each rule colors only the cell in its own column. If several rules for a column match, the first one wins. Cells that match nothing stay neutral.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var defaultColorColumn: String {
        let columns = vm.activeColumns
        let trigger = vm.triggerHeader
        return columns.first { $0 != trigger && $0 != vm.labelHeader } ?? columns.first ?? ""
    }
}

struct CellRuleRow: View {
    @Binding var rule: CellRule
    let columns: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $rule.condition.isEnabled).labelsHidden()
                Picker("", selection: $rule.condition.column) {
                    if !columns.contains(rule.condition.column) {
                        Text(rule.condition.column.isEmpty ? "Choose column" : rule.condition.column)
                            .tag(rule.condition.column)
                    }
                    ForEach(columns, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete rule")
            }
            HStack {
                Picker("", selection: $rule.condition.op) {
                    ForEach(RuleOperator.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("value", text: $rule.condition.value)
                    .textFieldStyle(.roundedBorder)
                if rule.condition.op.needsSecondValue {
                    Text("and")
                    TextField("value", text: $rule.condition.value2)
                        .textFieldStyle(.roundedBorder)
                }
            }
            ShadePicker(selection: $rule.shade)
        }
        .opacity(rule.condition.isEnabled ? 1 : 0.5)
        .padding(.vertical, 4)
    }
}

/// A row of swatches for every available shade.
struct ShadePicker: View {
    @Binding var selection: Shade

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Shade.allCases) { shade in
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(shade.color ?? Color.clear)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(shade == .none ? 0.4 : 0.15), lineWidth: 1)
                    if shade == .none {
                        Image(systemName: "slash.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.accentColor, lineWidth: selection == shade ? 2.5 : 0)
                        .padding(-3)
                )
                .contentShape(Rectangle())
                .onTapGesture { selection = shade }
                .help(shade.name)
            }
            Text(selection.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .padding(.vertical, 2)
    }
}

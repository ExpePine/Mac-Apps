import SwiftUI

/// Panel opened from the small ▼ in a Filter-screen column header:
/// sort on the fly, the advanced conditions for this column, and its cell colors.
struct ColumnMenuView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    let column: Int

    /// Chart Reel of this column's stocks, each chart centred on its own day.
    private func reel(_ centre: String) {
        let d = UserDefaults.standard
        d.set(ReelSource.column.rawValue, forKey: "reel.source")
        d.set(name, forKey: "reel.column"); d.set("has a value", forKey: "reel.op"); d.set("", forKey: "reel.value")
        d.set(true, forKey: "reel.alsoFilter")
        d.set(centre, forKey: "reel.centre")
        d.set(UUID().uuidString + "|", forKey: "reel.jump")
        openWindow(id: "reel")
    }

    private var name: String { column < vm.headers.count ? vm.headers[column] : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title + sort
            HStack {
                Text(name).font(.headline).lineLimit(1)
                Spacer()
                FormulaHelpButton()
            }
            HStack(spacing: 8) {
                sortButton(descending: false)
                sortButton(descending: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "film.stack").foregroundStyle(.secondary)
                Button("Charts: value = days ago (0 → n)") { reel("days") }
                    .help("Chart Reel of this Filter's stocks with a value in \(name), sorted 0 → n, each centred \(name) trading days back")
                Button("Charts: since it started") { reel("since") }
                    .help("Chart Reel centred on the day each stock's \(name) value began (from the stored daily snapshots)")
            }
            .controlSize(.small)

            Divider()

            // Conditions on this column
            HStack {
                Text("Conditions on \(name)").font(.subheadline.bold())
                Spacer()
                Menu {
                    Button("\(name) vs a value") {
                        vm.settings.filterGroup.conditions.append(FilterCondition(column: name))
                    }
                    Button("\(name) vs another column") {
                        let other = vm.headers.first { $0 != name } ?? name
                        vm.settings.filterGroup.conditions.append(
                            FilterCondition(column: name, target: .column, otherColumn: other))
                    }
                    Button("Formula using \(name)") {
                        vm.settings.filterGroup.conditions.append(
                            FilterCondition(kind: .formula, formula: ColumnRenamer.formulaName(name) + " > "))
                    }
                    Divider()
                    Button("Has a value") {
                        vm.settings.filterGroup.conditions.append(FilterCondition(column: name, op: .hasValue))
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if conditionIDs.isEmpty {
                Text("No conditions on this column yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(conditionIDs, id: \.self) { id in
                            ConditionRow(condition: conditionBinding(id), columns: vm.headers) {
                                vm.settings.filterGroup.conditions.removeAll { $0.id == id }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            Text("Combined with your other filters as \(vm.settings.filterGroup.mode.label). \(vm.filterRows.count) of \(vm.rows.count) rows match.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            // Cell colors for this column
            HStack {
                Text("Cell colors").font(.subheadline.bold())
                Spacer()
                Button {
                    vm.settings.cellRules.append(CellRule(condition: Rule(column: name, op: .greaterThan, value: "0"), shade: .green))
                } label: { Label("Add", systemImage: "plus.circle") }
                Button {
                    vm.settings.cellRules.append(CellRule(condition: Rule(column: name, op: .greaterThan, value: "0"), shade: .green))
                    vm.settings.cellRules.append(CellRule(condition: Rule(column: name, op: .lessThan, value: "0"), shade: .red))
                } label: { Label("Green / red", systemImage: "plusminus") }
            }
            .buttonStyle(.borderless)

            ForEach(colorRuleIDs, id: \.self) { id in
                CellRuleRow(rule: colorBinding(id), columns: [name]) {
                    vm.settings.cellRules.removeAll { $0.id == id }
                }
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    private func sortButton(descending: Bool) -> some View {
        let active = vm.table.index(of: vm.settings.filterSortColumn) == column
            && vm.settings.filterSortDescending == descending
        return Button {
            vm.settings.filterSortColumn = name
            vm.settings.filterSortDescending = descending
        } label: {
            Label(descending ? "Sort high → low" : "Sort low → high",
                  systemImage: descending ? "arrow.down" : "arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : nil)
    }

    // Conditions at the top level of the Filter that use this column
    // (column comparisons on either side, or formulas that mention it).
    private var conditionIDs: [UUID] {
        vm.settings.filterGroup.conditions.filter { c in
            if c.kind == .formula {
                guard let f = try? Formula.compile(c.formula, table: vm.table) else {
                    return c.formula.localizedCaseInsensitiveContains(name)
                }
                return f.columns.contains(column)
            }
            return vm.table.index(of: c.column) == column
                || (c.target == .column && vm.table.index(of: c.otherColumn) == column)
        }.map(\.id)
    }

    private func conditionBinding(_ id: UUID) -> Binding<FilterCondition> {
        Binding(
            get: { vm.settings.filterGroup.conditions.first { $0.id == id } ?? FilterCondition() },
            set: { new in
                if let i = vm.settings.filterGroup.conditions.firstIndex(where: { $0.id == id }) {
                    vm.settings.filterGroup.conditions[i] = new
                }
            })
    }

    private var colorRuleIDs: [UUID] {
        vm.settings.cellRules.filter { vm.table.index(of: $0.condition.column) == column }.map(\.id)
    }

    private func colorBinding(_ id: UUID) -> Binding<CellRule> {
        Binding(
            get: { vm.settings.cellRules.first { $0.id == id } ?? CellRule() },
            set: { new in
                if let i = vm.settings.cellRules.firstIndex(where: { $0.id == id }) {
                    vm.settings.cellRules[i] = new
                }
            })
    }
}

extension ScreenerViewModel {
    /// Columns that have a top-level condition or a color rule (their header ▼ is highlighted).
    var columnsWithRules: Set<Int> {
        var out = Set<Int>()
        for c in settings.filterGroup.conditions where c.isEnabled {
            if c.kind == .formula {
                if let f = try? Formula.compile(c.formula, table: table) { out.formUnion(f.columns) }
            } else {
                if let i = table.index(of: c.column) { out.insert(i) }
                if c.target == .column, let i = table.index(of: c.otherColumn) { out.insert(i) }
            }
        }
        for r in settings.cellRules where r.condition.isEnabled {
            if let i = table.index(of: r.condition.column) { out.insert(i) }
        }
        return out
    }
}

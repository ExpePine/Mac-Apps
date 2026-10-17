import SwiftUI

// MARK: - Advanced filter editor (used by the Filter screen and by buy triggers)

struct FilterGroupEditor: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Binding var group: FilterGroup
    let columns: [String]
    var isRoot = false
    var depth = 0
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !isRoot {
                    Toggle("", isOn: $group.isEnabled).labelsHidden()
                        .help("Turn this group on/off")
                }
                Picker("", selection: $group.mode) {
                    ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text(isRoot ? "of these conditions:" : "of:")
                    .foregroundStyle(.secondary)
                Spacer()
                if !isRoot {
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete group")
                }
            }

            ForEach($group.conditions) { $condition in
                ConditionRow(condition: $condition, columns: columns) {
                    $group.conditions.wrappedValue.removeAll { $0.id == condition.id }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }

            ForEach($group.groups) { $child in
                AnyView(
                    FilterGroupEditor(group: $child, columns: columns, isRoot: false, depth: depth + 1) {
                        $group.groups.wrappedValue.removeAll { $0.id == child.id }
                    }
                )
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                .opacity(child.isEnabled ? 1 : 0.55)
            }

            Menu {
                Button("Column vs value") {
                    $group.conditions.wrappedValue.append(FilterCondition(column: columns.first ?? ""))
                }
                Button("Column vs another column") {
                    $group.conditions.wrappedValue.append(
                        FilterCondition(column: columns.first ?? "", target: .column,
                                        otherColumn: columns.dropFirst().first ?? columns.first ?? ""))
                }
                Button("Formula") {
                    $group.conditions.wrappedValue.append(FilterCondition(kind: .formula))
                }
                if depth < 4 {
                    Divider()
                    Button("Group (nested AND / OR / NOT)") {
                        $group.groups.wrappedValue.append(FilterGroup(mode: .any))
                    }
                }
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct ConditionRow: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Binding var condition: FilterCondition
    let columns: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: $condition.isEnabled).labelsHidden()
                if condition.kind == .formula {
                    Label("Formula", systemImage: "function").fontWeight(.medium)
                } else {
                    NamePicker(selection: $condition.column, columns: columns)
                }
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete condition")
            }

            if condition.kind == .formula {
                TextField("e.g. CLOSE > EMA_20 * 1.02 AND RSI_14 >= 60", text: $condition.formula, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                formulaStatus
            } else {
                HStack(spacing: 6) {
                    Picker("", selection: $condition.op) {
                        ForEach(RuleOperator.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    if condition.op.allowsColumnTarget {
                        Picker("", selection: $condition.target) {
                            ForEach(CompareTarget.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                if condition.op.needsValue {
                    if condition.target == .column && condition.op.allowsColumnTarget {
                        HStack(spacing: 6) {
                            NamePicker(selection: $condition.otherColumn, columns: columns)
                            Text("×").foregroundStyle(.secondary)
                            TextField("1", text: $condition.factor)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .help("Multiply the other column, e.g. 1.02 = 2% above it, 0.95 = 5% below")
                        }
                    } else {
                        HStack(spacing: 6) {
                            TextField("value", text: $condition.value)
                                .textFieldStyle(.roundedBorder)
                            if condition.op.needsSecondValue {
                                Text("and")
                                TextField("value", text: $condition.value2)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
            }
        }
        .opacity(condition.isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var formulaStatus: some View {
        let text = condition.formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            Text("Write a formula using column names. Click ? for help.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !vm.hasData {
            Text("Import data to check column names.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            switch Result(catching: { try Formula.compile(text, table: vm.table) }) {
            case .success(let compiled):
                Label("Valid · uses \(compiled.columns.map { vm.headers[$0] }.joined(separator: ", "))",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Column picker that keeps a name even if the column isn't in the imported data.
struct NamePicker: View {
    @Binding var selection: String
    let columns: [String]

    var body: some View {
        Picker("", selection: $selection) {
            if !columns.contains(selection) {
                Text(selection.isEmpty ? "Choose column" : "\(selection) (not found)").tag(selection)
            }
            ForEach(columns, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
    }
}

/// Picker over the sheet's columns, with a title. Keeps a typed name even if the column isn't loaded yet.
struct ColumnPicker: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            if !vm.headers.contains(selection) {
                Text(selection.isEmpty ? "Choose…" : "\(selection)\(vm.table.index(of: selection) == nil ? " (not found)" : "")")
                    .tag(selection)
            }
            ForEach(vm.headers, id: \.self) { Text($0).tag($0) }
        }
    }
}

struct FormulaHelpButton: View {
    @State private var show = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help("Formula help")
        .popover(isPresented: $show, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Formulas").font(.headline)
                    Text("A formula is true or false for each row. Use column names directly, or [in brackets] if they contain spaces or symbols. Capital letters don't matter.")
                    Group {
                        Text("Examples").font(.subheadline.bold())
                        code("CLOSE > EMA_20 * 1.02")
                        code("RSI_14 >= 60 AND VOLUME > 2 * AVG_VOL")
                        code("(D_TRIGGER > 0 OR [Breakout %] > 3) AND NOT SECTOR = 'Bank'")
                        code("pct(CLOSE, PREV_CLOSE) > 2")
                        code("abs(CLOSE - VWAP) / VWAP < 0.01")
                    }
                    Group {
                        Text("Operators").font(.subheadline.bold())
                        Text("+  −  *  /    >  >=  <  <=  =  !=    AND  OR  NOT    ( )")
                            .font(.system(.body, design: .monospaced))
                        Text("Functions").font(.subheadline.bold())
                        Text("abs(x) · round(x, digits) · min(a, b, …) · max(a, b, …) · pct(a, b) = % change from b to a · empty(x) · contains(x, 'text') · startswith(x, 'text')")
                        Text("Text goes in 'single quotes'. Blank cells never satisfy > or <.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(width: 420, alignment: .leading)
            }
            .frame(maxHeight: 460)
        }
    }

    private func code(_ s: String) -> some View {
        Text(s)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Cell color rules

struct CellRuleRow: View {
    @Binding var rule: CellRule
    let columns: [String]
    let onDelete: () -> Void

    private var ops: [RuleOperator] {
        [.greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .equals, .notEquals, .between,
         .contains, .notContains, .hasValue, .isEmpty]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $rule.condition.isEnabled).labelsHidden()
                NamePicker(selection: $rule.condition.column, columns: columns)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete rule")
            }
            HStack {
                Picker("", selection: $rule.condition.op) {
                    ForEach(ops) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                if rule.condition.op.needsValue {
                    TextField("value", text: $rule.condition.value)
                        .textFieldStyle(.roundedBorder)
                }
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

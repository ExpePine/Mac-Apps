import SwiftUI

struct RulesView: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        Form {
            Section {
                Picker("Match", selection: $vm.settings.matchMode) {
                    ForEach(MatchMode.allCases) { Text($0.rawValue).tag($0) }
                }

                ForEach($vm.settings.filterRules) { $rule in
                    RuleRow(rule: $rule, columns: vm.headers, showColor: false) {
                        vm.settings.filterRules.removeAll { $0.id == rule.id }
                    }
                }

                Button {
                    vm.settings.filterRules.append(Rule(column: vm.headers.first ?? ""))
                } label: {
                    Label("Add filter", systemImage: "plus")
                }
            } header: {
                Text("Filter — show only stocks where")
            }

            Section {
                ForEach($vm.settings.highlightRules) { $rule in
                    RuleRow(rule: $rule, columns: vm.headers, showColor: true) {
                        vm.settings.highlightRules.removeAll { $0.id == rule.id }
                    }
                }

                Button {
                    vm.settings.highlightRules.append(Rule(column: vm.headers.first ?? ""))
                } label: {
                    Label("Add highlight", systemImage: "plus")
                }
            } header: {
                Text("Highlight — color stocks where")
            } footer: {
                Text("If several highlight rules match a row, the first one in this list sets its color. Numbers like 1,234 · ₹2,450 · -3.2% · 12.4 B · 850 Cr are understood.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct RuleRow: View {
    @Binding var rule: Rule
    let columns: [String]
    let showColor: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $rule.isEnabled)
                    .labelsHidden()
                    .help("Turn this rule on/off")

                Picker("", selection: $rule.column) {
                    if !columns.contains(rule.column) {
                        Text(rule.column.isEmpty ? "Choose column" : rule.column).tag(rule.column)
                    }
                    ForEach(columns, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete rule")
            }

            HStack {
                Picker("", selection: $rule.op) {
                    ForEach(RuleOperator.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                TextField("value", text: $rule.value)
                    .textFieldStyle(.roundedBorder)

                if rule.op.needsSecondValue {
                    Text("and")
                    TextField("value", text: $rule.value2)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if showColor {
                HStack(spacing: 6) {
                    Text("Color").foregroundStyle(.secondary)
                    ForEach(HighlightColor.allCases) { c in
                        Circle()
                            .fill(c.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary, lineWidth: rule.color == c ? 2 : 0))
                            .onTapGesture { rule.color = c }
                            .help(c.rawValue.capitalized)
                    }
                }
            }
        }
        .opacity(rule.isEnabled ? 1 : 0.5)
        .padding(.vertical, 4)
    }
}

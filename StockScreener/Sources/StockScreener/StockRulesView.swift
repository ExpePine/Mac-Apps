import SwiftUI

/// Panel opened by a stock's E button: that stock's Email / Alert rules.
struct StockRulesView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let stock: String
    let row: SheetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(stock, systemImage: "envelope.badge").font(.title3.bold())
                Spacer()
                statusPill
                FormulaHelpButton()
            }

            if ruleIDs.isEmpty {
                Text("No Email / Alert rule for \(stock) yet. Add one — e.g. email me when CLOSE > 2000, or when RSI_14 ≥ 60 AND CLOSE > EMA_20.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ruleIDs, id: \.self) { id in
                        ruleEditor(ruleBinding(id))
                    }
                }
            }
            .frame(maxHeight: 420)

            HStack {
                Button {
                    var rule = BuyTrigger(isEnabled: true, name: "\(stock) alert")
                    rule.symbol = stock
                    rule.filter = FilterGroup(conditions: [FilterCondition(column: firstNumericColumn)])
                    vm.settings.buyTriggers.append(rule)
                } label: {
                    Label("Add rule for \(stock)", systemImage: "plus.circle")
                }
                Spacer()
                if !globalMatches.isEmpty {
                    Text("Also met: \(globalMatches.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.green).lineLimit(1)
                        .help("Rules for all stocks that this stock meets right now")
                }
            }

            if vm.settings.email.username.isEmpty {
                Label("To receive emails, add your Gmail and App Password in Alerts & Email → Email.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 520)
    }

    // MARK: Pieces

    private var statusPill: some View {
        let state = vm.eStatus[row.id] ?? .none
        let (text, color): (String, Color) = {
            switch state {
            case .none: return ("No rule", .secondary)
            case .configured: return ("Rule set — not met", .orange)
            case .met: return ("Condition met", .green)
            }
        }()
        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func ruleEditor(_ rule: Binding<BuyTrigger>) -> some View {
        let isMet = vm.buyMatches(rule.wrappedValue).contains { vm.rowKey($0).caseInsensitiveCompare(stock) == .orderedSame }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: rule.isEnabled).labelsHidden()
                TextField("Rule name", text: rule.name)
                    .textFieldStyle(.roundedBorder)
                Circle()
                    .fill(rule.wrappedValue.isEnabled ? (isMet ? Color.green : Color.orange) : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .help(isMet ? "Condition met now" : "Not met now")
                Button(role: .destructive) {
                    vm.settings.buyTriggers.removeAll { $0.id == rule.wrappedValue.id }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                Toggle(isOn: rule.sendEmail) { Label("Email", systemImage: "envelope") }
                Toggle(isOn: rule.alertInApp) { Label("Alert in app", systemImage: "bell") }
            }
            .toggleStyle(.checkbox)
            FilterGroupEditor(group: rule.filter, columns: vm.headers, isRoot: true, onDelete: {})
            if rule.wrappedValue.sendEmail {
                TextField("Send to (optional)", text: rule.recipients,
                          prompt: Text("Uses the Email tab's addresses if empty"))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .stroke(isMet ? Color.green.opacity(0.6) : Color.orange.opacity(0.5), lineWidth: 1))
    }

    private var ruleIDs: [UUID] { vm.rules(for: stock).map(\.id) }

    private func ruleBinding(_ id: UUID) -> Binding<BuyTrigger> {
        Binding(
            get: { vm.settings.buyTriggers.first { $0.id == id } ?? BuyTrigger() },
            set: { new in
                if let i = vm.settings.buyTriggers.firstIndex(where: { $0.id == id }) {
                    vm.settings.buyTriggers[i] = new
                }
            })
    }

    private var globalMatches: [String] {
        vm.settings.buyTriggers
            .filter { $0.isEnabled && $0.symbol.isEmpty && $0.filter.activeCount > 0 }
            .filter { t in vm.buyMatches(t).contains { vm.rowKey($0).caseInsensitiveCompare(stock) == .orderedSame } }
            .map(\.name)
    }

    private var firstNumericColumn: String {
        let cols = vm.filterColumnIndices
        let pick = cols.first { $0 != vm.labelIndex && row.number($0) != nil } ?? cols.first
        return pick.map { vm.headers[$0] } ?? ""
    }
}

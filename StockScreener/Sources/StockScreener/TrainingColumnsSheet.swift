import SwiftUI

/// Pick the columns the neural net and the pattern miner learn from.
/// Each column is labelled Feature / Price level / Raw size / Date / Name / Text; only features are auto-picked.
struct TrainingColumnsSheet: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [ColumnProfile] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var scope = 0          // 0 = Filter columns, 1 = all columns

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Training columns").font(.title3.bold())
            Text("Features describe a stock in a way that compares fairly across stocks: ratios, % changes, RSI, scores, 0/1 flags. Price levels (D_CLOSE, EMA_20…), raw sizes (volume, market cap), dates and names are left out automatically, because a ₹50 stock and a ₹5,000 stock differ there without telling the net anything about momentum. You can still tick any column yourself.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("", selection: $scope) {
                    Text("Filter columns").tag(0)
                    Text("All columns").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 240).labelsHidden()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Spacer()
                Button("Auto-pick features") { selected = Set(vm.nnAutoFeatures) }
                    .help("The Filter screen's columns that are features")
                Button("All shown features") {
                    selected.formUnion(shown.filter { $0.kind.isFeature }.map(\.name))
                }
                Button("Clear") { selected.removeAll() }
            }

            Table(shown) {
                TableColumn("") { p in
                    Toggle("", isOn: Binding(
                        get: { selected.contains(p.name) },
                        set: { on in if on { selected.insert(p.name) } else { selected.remove(p.name) } }))
                        .labelsHidden()
                }
                .width(24)
                TableColumn("Column") { p in
                    Text(p.name).fontWeight(selected.contains(p.name) ? .semibold : .regular)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Kind") { p in
                    Text(p.kind.title)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(color(p.kind).opacity(0.15)))
                        .foregroundStyle(color(p.kind))
                }
                .width(90)
                TableColumn("Why") { p in
                    HStack(spacing: 4) {
                        if selected.contains(p.name) && !p.kind.isFeature {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Picked by you, although it doesn't look like a feature")
                        }
                        Text(p.reason).foregroundStyle(.secondary).lineLimit(2).help(p.reason)
                    }
                }
                .width(min: 200, ideal: 340)
                TableColumn("Filled") { p in Text("\(Int(p.coverage * 100))%").monospacedDigit() }.width(50)
                TableColumn("Values") { p in Text(p.distinct >= 5000 ? "5000+" : "\(p.distinct)").monospacedDigit() }.width(55)
            }
            .frame(minHeight: 340)

            HStack {
                Text("\(selected.count) selected")
                    .foregroundStyle(selected.count < 2 ? .orange : .secondary)
                if selected.count < 2 { Text("· pick at least 2").foregroundStyle(.orange) }
                Spacer()
                Button("Use auto-pick") {
                    vm.settings.nnFeatures = []
                    dismiss()
                }
                .help("Always follow the Filter screen: its feature columns, updated as you change them")
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use these \(selected.count)") {
                    // keep the sheet's column order
                    vm.settings.nnFeatures = profiles.map(\.name).filter { selected.contains($0) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            Text("Change the columns, then click Learn patterns again to retrain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 860, height: 600)
        .onAppear {
            profiles = vm.nnColumnProfiles
            selected = Set(vm.nnFeatureColumns)
            if profiles.contains(where: { selected.contains($0.name) && !$0.inFilter }) { scope = 1 }
        }
    }

    private var shown: [ColumnProfile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return profiles.filter { p in
            (scope == 1 || p.inFilter || selected.contains(p.name))
                && (q.isEmpty || p.name.localizedCaseInsensitiveContains(q))
        }
    }

    private func color(_ k: ColumnKind) -> Color {
        switch k {
        case .feature: return .green
        case .priceLevel: return .orange
        case .rawSize: return .yellow
        case .date: return .blue
        case .identifier, .text: return .secondary
        case .constant: return .gray
        }
    }
}

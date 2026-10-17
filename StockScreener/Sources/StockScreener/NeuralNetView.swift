import SwiftUI

/// "N" — learns which combinations of Filter-column values monthly top gainers (≥30% in ~1 month) share,
/// and trains a small neural net on them.
struct NeuralNetView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var tab = 0
    @State private var comboSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let report = vm.nnReport {
                modeBanner(report)
                TabView(selection: $tab) {
                    combosTab(report).tabItem { Text("Combinations (\(report.combos.count))") }.tag(0)
                    modelTab(report).tabItem { Text("Neural net") }.tag(1)
                    gainersTab(report).tabItem { Text("Gainers (\(report.gainers))") }.tag(2)
                }
                .padding(10)
            } else {
                emptyState
            }
        }
        .navigationTitle("N — Neural Net")
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Label("Monthly top gainer =", systemImage: "chart.line.uptrend.xyaxis")
                Stepper("≥ \(vm.settings.nnGainThreshold)%", value: $vm.settings.nnGainThreshold, in: 10...200, step: 5)
                    .fixedSize()
                Stepper("in \(vm.settings.nnWindowDays) trading days", value: $vm.settings.nnWindowDays, in: 5...60)
                    .fixedSize()
                Spacer()
                featureMenu
            }
            HStack(spacing: 10) {
                Button {
                    vm.fetchYahooPrices()
                } label: {
                    Label(vm.priceBook.series.isEmpty ? "Fetch Yahoo prices" : "Refresh Yahoo prices",
                          systemImage: "arrow.down.circle")
                }
                .disabled(vm.isFetchingPrices)
                if vm.isFetchingPrices {
                    ProgressView(value: Double(vm.priceProgress.0), total: Double(max(1, vm.priceProgress.1)))
                        .frame(width: 160)
                    Text("\(vm.priceProgress.0)/\(vm.priceProgress.1)").font(.caption.monospacedDigit())
                    Button("Stop") { vm.cancelYahooFetch() }
                } else {
                    Text(vm.priceBookAgeText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let status = vm.nnStatus {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    vm.trainPatternModel()
                } label: {
                    Label("Learn patterns", systemImage: "brain")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isTraining || vm.priceBook.series.isEmpty || !vm.hasData)
            }
            if let e = vm.priceError ?? vm.nnError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private var featureMenu: some View {
        Menu {
            ForEach(vm.headers.filter { $0 != "NN_score" }, id: \.self) { name in
                Button {
                    var list = vm.settings.nnFeatures.isEmpty ? vm.nnFeatureColumns : vm.settings.nnFeatures
                    if list.contains(name) { list.removeAll { $0 == name } } else { list.append(name) }
                    vm.settings.nnFeatures = list
                } label: {
                    if vm.nnFeatureColumns.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("Use the Filter screen's numeric columns") { vm.settings.nnFeatures = [] }
        } label: {
            Label("\(vm.nnFeatureColumns.count) input columns", systemImage: "slider.horizontal.3")
        }
        .fixedSize()
        .help("Which Filter columns the patterns and the neural net learn from")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile").font(.system(size: 46)).foregroundStyle(.secondary)
            Text("Learn what monthly top gainers have in common").font(.title3.bold())
            Text("1. Fetch Yahoo prices (daily closes for every stock, ~1 year; cached).\n2. Click Learn patterns. Stocks that gained ≥ \(vm.settings.nnGainThreshold)% within \(vm.settings.nnWindowDays) trading days are the gainers; the app finds the combinations of your Filter-column values they share, and trains a small neural net on them.\n3. Use a combination as a filter or an alert rule, and sort by the new NN_score column.")
                .foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modeBanner(_ r: NNReport) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: r.mode == "Predictive" ? "clock.arrow.circlepath" : "camera.metering.center.weighted")
                .foregroundStyle(r.mode == "Predictive" ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(r.mode) mode · \(r.stocks) stocks · \(r.gainers) gained ≥ \(Int(r.threshold))% (base rate \(pct(Double(r.gainers) / Double(max(1, r.stocks)))))")
                    .font(.callout.bold())
                Text(r.modeDetail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("Trained \(r.trainedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background((r.mode == "Predictive" ? Color.green : Color.orange).opacity(0.08))
    }

    // MARK: Tabs

    private func combosTab(_ r: NNReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search combinations", text: $comboSearch).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("Hit rate = share of stocks with the combination that became gainers · Lift = hit rate ÷ base rate")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Table(filteredCombos(r)) {
                TableColumn("Combination of filter values") { c in
                    Text(c.items.map { $0.describe(r.featureNames) }.joined(separator: "  AND  "))
                        .font(.system(.callout, design: .monospaced))
                        .help(c.items.map { $0.describe(r.featureNames) }.joined(separator: " AND "))
                }
                .width(min: 280, ideal: 420)
                TableColumn("Gainers") { c in Text("\(c.gainersWith) / \(r.gainers)").monospacedDigit() }
                    .width(80)
                TableColumn("Stocks") { c in Text("\(c.totalWith)").monospacedDigit() }.width(60)
                TableColumn("Hit rate") { c in Text(pct(c.hitRate)).monospacedDigit().foregroundStyle(.green) }.width(70)
                TableColumn("Lift") { c in
                    Text(String(format: "%.1f×", c.lift)).monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(c.lift >= 3 ? .green : (c.lift >= 1.5 ? .orange : .secondary))
                }
                .width(55)
                TableColumn("Example gainers") { c in
                    Text(c.examples.prefix(6).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                }
                TableColumn("") { c in
                    HStack(spacing: 4) {
                        Button("Filter") {
                            vm.applyCombo(c, names: r.featureNames)
                            openWindow(id: "filter")
                        }
                        .help("Show this combination on the Filter screen (replaces the current filter)")
                        Button("Alert") { vm.ruleFromCombo(c, names: r.featureNames) }
                            .help("Create an Email / Alert rule for this combination")
                    }
                    .controlSize(.small)
                }
                .width(120)
            }
        }
    }

    private func modelTab(_ r: NNReport) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Model: inputs → 16 → 8 → 1 (ReLU, sigmoid), Adam, gainers weighted up").font(.caption).foregroundStyle(.secondary)
                if let auc = r.auc {
                    metric("Test AUC", String(format: "%.2f", auc),
                           auc >= 0.7 ? "useful ranking" : (auc >= 0.6 ? "weak signal" : "close to chance (0.5)"),
                           auc >= 0.7 ? .green : (auc >= 0.6 ? .orange : .red))
                    if let p = r.precisionTop20 {
                        metric("Gainers in top 20 (test)", pct(p),
                               "vs \(pct(Double(r.gainers) / Double(max(1, r.stocks)))) at random", .blue)
                    }
                } else {
                    Text("Not enough gainers to train (need ≥ 5). Lower the threshold or widen the window.")
                        .foregroundStyle(.orange)
                }
                Text("Held-out test: 20% of stocks the net never saw. Small samples make these numbers noisy; treat them as a guide, not a forecast.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if !r.importance.isEmpty {
                    Text("What the net relies on").font(.headline).padding(.top, 6)
                    ForEach(r.importance.prefix(12), id: \.0) { name, drop in
                        HStack {
                            Text(name).frame(width: 140, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(drop > 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                                    .frame(width: max(2, g.size.width * min(1, max(0, drop) / max(0.001, r.importance.first?.1 ?? 0.001))))
                            }
                            .frame(height: 10)
                            Text(String(format: "%+.3f", drop)).font(.caption.monospacedDigit()).frame(width: 60)
                        }
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Today's highest NN_score").font(.headline)
                Text("Added as the NN_score column (0–100) — sort, filter, color or alert on it.")
                    .font(.caption).foregroundStyle(.secondary)
                List(r.topScored, id: \.0) { sym, score in
                    HStack {
                        Text(sym).fontWeight(.semibold)
                        Spacer()
                        Text(String(format: "%.1f", score)).monospacedDigit()
                            .foregroundStyle(score >= 70 ? .green : (score >= 50 ? .orange : .secondary))
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }

    private func gainersTab(_ r: NNReport) -> some View {
        List(r.gainerList, id: \.0) { sym, gain in
            HStack {
                Text(sym).fontWeight(.semibold)
                Spacer()
                Text(String(format: "+%.1f%%", gain)).monospacedDigit().foregroundStyle(.green)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    // MARK: Helpers

    private func filteredCombos(_ r: NNReport) -> [PatternCombo] {
        let q = comboSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return r.combos }
        return r.combos.filter { c in
            (c.items.map { $0.describe(r.featureNames) } + c.examples).joined(separator: " ").localizedCaseInsensitiveContains(q)
        }
    }

    private func metric(_ title: String, _ value: String, _ note: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.title.bold().monospacedDigit()).foregroundStyle(color)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
}

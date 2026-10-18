import SwiftUI

/// Header for the ranking model: what it learned from and whether it beats luck.
struct PanelBanner: View {
    let panel: PanelReport

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: panel.beatsLuck ? "checkmark.seal.fill" : "questionmark.diamond")
                .foregroundStyle(panel.beatsLuck ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ranking model · \(panel.labeledDays) labelled days · \(panel.rows) stock-days · \(panel.stocks) stocks · predicts the next \(panel.mainHorizon) trading days")
                    .font(.callout.bold())
                Text(panel.verdict + (panel.lowConfidence ? "  Low confidence: under ~60 labelled days, results can change a lot as data grows." : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background((panel.beatsLuck ? Color.green : Color.orange).opacity(0.08))
    }
}

struct PanelModelTab: View {
    let panel: PanelReport

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(panel.testMethod).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 22) {
                        metric("Rank correlation (IC)", String(format: "%+.3f", panel.metrics.ic),
                               "avg per test day; 0 = random, above ~0.05 is useful", panel.metrics.ic > 0.05 ? .green : (panel.metrics.ic > 0.02 ? .orange : .red))
                        metric("Luck level", String(format: "%+.3f", panel.luckICs.max() ?? 0),
                               "best of \(panel.luckICs.count) shuffled-label runs", .secondary)
                    }
                    HStack(spacing: 22) {
                        metric("Top-20 extra gain", String(format: "%+.2f pts", panel.metrics.top20Lift),
                               "top 20 by score vs the day's average, over \(panel.mainHorizon) days", panel.metrics.top20Lift > 0 ? .green : .red)
                        metric("Days IC > 0", String(format: "%.0f%%", panel.metrics.icPositive * 100),
                               "\(panel.metrics.testDays) test days", .blue)
                    }
                    HStack(spacing: 22) {
                        if let auc = panel.metrics.auc {
                            metric("Gainer AUC", String(format: "%.2f", auc),
                                   "gainer = ≥ \(String(format: "%.1f", panel.gainerThreshold))% within \(panel.mainHorizon) days", auc >= 0.65 ? .green : .orange)
                        }
                        if let p = panel.metrics.precision20 {
                            metric("Gainers in top 20", String(format: "%.1f%%", p * 100),
                                   String(format: "vs %.1f%% at random", panel.metrics.baseRate * 100), .blue)
                        }
                    }
                    Text("How it works: \(panel.members) small nets (16→8 + a pairwise layer) learn from \(panel.featureNames.count) inputs — your columns ranked among all stocks each day, plus their 1-day and 5-day changes. Targets are the real gains over \(panel.horizons.map(String.init).joined(separator: ", ")) trading days, with a ranking loss that pushes gainers above the rest. NN_score = average rank across the nets (0–100); NN_conf = how much they agree.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                    Text("What it relies on (drop in IC when scrambled)").font(.headline)
                    let top = panel.importance.first?.1 ?? 0.001
                    ForEach(panel.importance.prefix(15), id: \.0) { name, drop in
                        HStack {
                            Text(name).frame(width: 170, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(drop > 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                                    .frame(width: max(2, g.size.width * min(1, max(0, drop) / max(0.001, top))))
                            }
                            .frame(height: 10)
                            Text(String(format: "%+.3f", drop)).font(.caption.monospacedDigit()).frame(width: 60)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 6) {
                Text("Today's highest NN_score").font(.headline)
                Text("Confidence = how much the \(panel.members) nets agree.").font(.caption).foregroundStyle(.secondary)
                List(panel.topScored, id: \.0) { sym, score, conf in
                    HStack {
                        Text(sym).fontWeight(.semibold)
                        Spacer()
                        Text(String(format: "%.0f", score)).monospacedDigit()
                            .foregroundStyle(score >= 90 ? .green : (score >= 75 ? .orange : .secondary))
                        Text(String(format: "conf %.0f", conf)).font(.caption.monospacedDigit())
                            .foregroundStyle(conf >= 70 ? .green : .secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ note: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            Text(note).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .leading)
        }
    }
}

/// Column pairs the pairwise layer says act together.
struct PanelPairsTab: View {
    let panel: PanelReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pairs the model learned to read together. + means: when both are high (or both low) together, the score goes up; − means the combination counts against a stock. Inputs are ranks within each day, so “high” means high compared with other stocks that day.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let top = max(0.0001, panel.pairs.map { abs($0.2) }.max() ?? 0.0001)
            List(Array(panel.pairs.enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.0).fontWeight(.semibold)
                    Text("×").foregroundStyle(.secondary)
                    Text(pair.1).fontWeight(.semibold)
                    Spacer()
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pair.2 >= 0 ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                            .frame(width: max(2, g.size.width * abs(pair.2) / top))
                    }
                    .frame(width: 160, height: 10)
                    Text(String(format: "%+.3f", pair.2)).font(.caption.monospacedDigit()).frame(width: 60)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }
}

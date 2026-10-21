import SwiftUI
import SamsaraCore

struct InsightsView: View {
    var body: some View {
        ScrollView {
            InsightsContent().padding(20)
        }
        .background(Theme.pageBackground)
    }
}

struct InsightsContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let insights = store.analyzer.insights(all: store.expenses, period: store.period)
        VStack(alignment: .leading, spacing: 16) {
            Text("Insights · \(store.period.label)").font(.largeTitle.weight(.bold))

            VStack(spacing: 10) {
                ForEach(insights) { InsightRow(insight: $0) }
            }

            CategoryChangeCard()

            Card(title: "About this data") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(store.expenses.count) entries in total, \(Money.format(Analyzer.total(store.expenses))).")
                    if !store.sourceNote.isEmpty {
                        Text("Source: \(store.sourceNote)\(store.lastSync.map { " on " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "").")
                    }
                    ForEach(store.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text("Amounts are Samsara's Price column, which is the total for each line (quantity already included).")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

/// Category totals now vs the previous period.
struct CategoryChangeCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if store.period != .all {
            let changes = store.analyzer.categoryChanges(current: store.current, previous: store.previous)
                .sorted { $0.current > $1.current }
            Card(title: "Category change", subtitle: "\(store.period.label) vs \(store.period.comparisonLabel)") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        Text("Category").bold()
                        Text("Now").bold().gridColumnAlignment(.trailing)
                        Text("Before").bold().gridColumnAlignment(.trailing)
                        Text("Change").bold().gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(changes.prefix(14)) { c in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.color(for: c.category)).frame(width: 8, height: 8)
                                Text(c.category)
                            }
                            Text(Money.format(c.current)).monospacedDigit()
                            Text(Money.format(c.previous)).monospacedDigit().foregroundStyle(.secondary)
                            Text(changeText(c))
                                .monospacedDigit()
                                .foregroundStyle(c.change > 0 ? .orange : (c.change < 0 ? .green : .secondary))
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func changeText(_ c: CategoryChange) -> String {
        if c.change == 0 { return "—" }
        let amount = (c.change > 0 ? "+" : "−") + Money.format(abs(c.change))
        if let p = c.percent { return "\(amount) (\(p.signedPercentText))" }
        return "\(amount) (new)"
    }
}

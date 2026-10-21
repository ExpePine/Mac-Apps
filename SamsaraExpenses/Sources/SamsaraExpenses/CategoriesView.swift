import SwiftUI
import Charts
import SamsaraCore

struct CategoriesView: View {
    @EnvironmentObject var store: Store
    @State private var selected: String?

    var body: some View {
        let cats = store.analyzer.byCategory(store.current)
        let total = Analyzer.total(store.current)
        let changes = Dictionary(store.analyzer.categoryChanges(current: store.current, previous: store.previous)
            .map { ($0.category, $0) }, uniquingKeysWith: { a, _ in a })

        HSplitView {
            List(cats, selection: $selected) { b in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Theme.color(for: b.key)).frame(width: 9, height: 9)
                        Text(b.key).fontWeight(.medium)
                        Spacer()
                        Text(Money.format(b.total)).monospacedDigit()
                    }
                    HStack {
                        Text("\(b.count) items · \(total > 0 ? Money.percent(b.total / total * 100) : "0%")")
                        Spacer()
                        if let c = changes[b.key], let p = c.percent, store.period != .all {
                            Text(p.signedPercentText).foregroundStyle(p > 0 ? .orange : .green)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ShareBar(fraction: total > 0 ? b.total / total : 0, color: Theme.color(for: b.key))
                }
                .padding(.vertical, 4)
            }
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)

            Group {
                if let key = selected ?? cats.first?.key {
                    ScrollView {
                        CategoryDetail(category: key).padding(20)
                    }
                } else {
                    Text("No categories in this period").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
        }
        .onChange(of: store.period) { _ in selected = nil }
    }
}

struct CategoryDetail: View {
    @EnvironmentObject var store: Store
    let category: String

    var body: some View {
        let a = store.analyzer
        let allInCat = store.expenses.filter { $0.category == category }
        let inPeriod = store.current.filter { $0.category == category }
        let total = Analyzer.total(inPeriod)
        let monthly = a.monthly(allInCat)
        let avgMonth = monthly.isEmpty ? 0 : Analyzer.total(allInCat.filter { $0.date != nil }) / Double(monthly.count)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(Theme.color(for: category)).frame(width: 14, height: 14)
                Text(category).font(.largeTitle.weight(.bold))
            }
            HStack(spacing: 12) {
                KPICard(title: store.period.label, value: Money.format(total), symbol: "indianrupeesign.circle",
                        footnote: "\(inPeriod.count) items")
                KPICard(title: "Monthly average", value: Money.format(avgMonth), symbol: "calendar",
                        footnote: "Across \(monthly.count) month\(monthly.count == 1 ? "" : "s") of data")
                KPICard(title: "Avg per item", value: inPeriod.isEmpty ? "—" : Money.format(total / Double(inPeriod.count)),
                        symbol: "cart")
            }
            Card(title: "Month by month", subtitle: "All data for \(category)") {
                MonthlyChart(points: monthly, period: store.period, analyzer: a).frame(height: 200)
            }
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Top items", subtitle: store.period.label) {
                    TopItemsList(buckets: a.topProducts(inPeriod, limit: 10, by: .spend))
                }
                Card(title: "Where from", subtitle: store.period.label) {
                    TopItemsList(buckets: a.byVendor(inPeriod))
                }
            }
        }
    }
}

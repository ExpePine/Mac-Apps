import SwiftUI
import Charts
import SamsaraCore

struct DashboardView: View {
    var body: some View {
        ScrollView {
            DashboardContent().padding(20)
        }
        .background(Theme.pageBackground)
    }
}

/// Everything on the dashboard, without a ScrollView (so it can also be rendered to an image).
struct DashboardContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let a = store.analyzer
        let current = store.current
        let previous = store.previous
        let total = Analyzer.total(current)
        let prevTotal = Analyzer.total(previous)
        let days = a.dayCount(for: store.interval, expenses: current)
        let perDay = total / Double(max(1, days))
        let projection = a.projection(for: store.period, expenses: current)
        let cats = a.byCategory(current)
        let insights = a.insights(all: store.expenses, period: store.period)

        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(spacing: 12) {
                KPICard(title: "Spent", value: Money.format(total), symbol: "indianrupeesign.circle",
                        footnote: prevTotal > 0
                            ? "\(((total - prevTotal) / prevTotal * 100).signedPercentText) vs \(store.period.comparisonLabel) (\(Money.format(prevTotal)))"
                            : nil,
                        footColor: prevTotal > 0 ? (total > prevTotal ? .orange : .green) : .secondary)
                KPICard(title: "Entries", value: "\(current.count)", symbol: "list.bullet.rectangle",
                        footnote: current.isEmpty ? nil : "Avg \(Money.format(total / Double(current.count))) per entry")
                KPICard(title: "Per day", value: Money.format(perDay), symbol: "calendar",
                        footnote: "Over \(days) day\(days == 1 ? "" : "s")")
                if let projection {
                    KPICard(title: "Month-end estimate", value: Money.format(projection), symbol: "chart.line.uptrend.xyaxis",
                            footnote: "At the current daily pace",
                            footColor: prevTotal > 0 && projection > prevTotal ? .orange : .secondary)
                } else if let top = cats.first {
                    KPICard(title: "Top category", value: top.key, symbol: "chart.pie",
                            footnote: "\(Money.format(top.total)) · \(total > 0 ? Money.percent(top.total / total * 100) : "0%")")
                }
            }

            if !insights.isEmpty {
                Card(title: "Highlights") {
                    VStack(spacing: 8) {
                        ForEach(insights.prefix(3)) { InsightRow(insight: $0) }
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "Spending by month", subtitle: "All data · selected month highlighted") {
                    MonthlyChart(points: a.monthly(store.expenses), period: store.period, analyzer: a)
                        .frame(height: 230)
                }
                Card(title: "By category", subtitle: store.period.label) {
                    CategoryBars(buckets: Array(cats.prefix(9)), total: total)
                }
            }

            Card(title: "Daily spending", subtitle: "\(store.period.label) · dashed line = daily average") {
                DailyChart(points: a.daily(current, in: store.interval), average: perDay)
                    .frame(height: 200)
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "By weekday", subtitle: store.period.label) {
                    WeekdayChart(buckets: a.weekday(current)).frame(height: 190)
                }
                Card(title: "Top items by spend", subtitle: store.period.label) {
                    TopItemsList(buckets: a.topProducts(current, limit: 8, by: .spend))
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.period.label).font(.largeTitle.weight(.bold))
            Spacer()
            if let lastSync = store.lastSync {
                Text("\(store.sourceNote) · \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MonthlyChart: View {
    let points: [MonthPoint]
    let period: Period
    let analyzer: Analyzer

    private func highlighted(_ p: MonthPoint) -> Bool {
        guard case .month = period else { return true }
        return analyzer.period(containing: p.month) == period
    }

    var body: some View {
        Chart(points) { p in
            BarMark(x: .value("Month", p.month, unit: .month), y: .value("Spent", p.total))
                .foregroundStyle(highlighted(p) ? Theme.accent : Theme.accent.opacity(0.3))
                .cornerRadius(4)
                .annotation(position: .top) {
                    if p.total > 0 {
                        Text(Money.compact(p.total)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Money.compact(d)) } }
            }
        }
    }
}

struct CategoryBars: View {
    let buckets: [Bucket]
    let total: Double

    var body: some View {
        if buckets.isEmpty {
            Text("No entries").foregroundStyle(.secondary)
        } else {
            Chart(buckets) { b in
                BarMark(x: .value("Spent", b.total), y: .value("Category", b.key))
                    .foregroundStyle(Theme.color(for: b.key))
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(Money.compact(b.total)) · \(total > 0 ? Money.percent(b.total / total * 100) : "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...((buckets.first?.total ?? 1) * 1.35))
            .frame(height: max(150, CGFloat(buckets.count) * 25))
        }
    }
}

struct DailyChart: View {
    let points: [DayPoint]
    let average: Double

    var body: some View {
        Chart {
            ForEach(points) { p in
                BarMark(x: .value("Day", p.day, unit: .day), y: .value("Spent", p.total))
                    .foregroundStyle(Theme.accent.gradient)
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("avg \(Money.compact(average))/day").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Money.compact(d)) } }
            }
        }
    }
}

struct WeekdayChart: View {
    let buckets: [Bucket]

    var body: some View {
        Chart(buckets) { b in
            BarMark(x: .value("Day", b.key), y: .value("Spent", b.total))
                .foregroundStyle(Theme.palette[1].gradient)
                .cornerRadius(3)
                .annotation(position: .top) {
                    if b.total > 0 { Text(Money.compact(b.total)).font(.caption2).foregroundStyle(.secondary) }
                }
        }
        .chartYAxis(.hidden)
    }
}

struct TopItemsList: View {
    let buckets: [Bucket]

    var body: some View {
        let maxTotal = buckets.first?.total ?? 1
        VStack(spacing: 9) {
            if buckets.isEmpty { Text("No entries").foregroundStyle(.secondary) }
            ForEach(buckets) { b in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(b.key).lineLimit(1)
                        Text("×\(b.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Money.format(b.total)).monospacedDigit()
                    }
                    .font(.callout)
                    ShareBar(fraction: maxTotal > 0 ? b.total / maxTotal : 0, color: Theme.accent.opacity(0.7))
                }
            }
        }
    }
}

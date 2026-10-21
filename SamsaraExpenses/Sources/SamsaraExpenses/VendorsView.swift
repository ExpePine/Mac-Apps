import SwiftUI
import Charts
import SamsaraCore

struct VendorsView: View {
    var body: some View {
        ScrollView {
            VendorsContent().padding(20)
        }
        .background(Theme.pageBackground)
    }
}

struct VendorsContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let a = store.analyzer
        let current = store.current
        let total = Analyzer.total(current)
        let vendors = a.byVendor(current)
        let people = a.byPerson(current)
        let topCats = Set(a.byCategory(current).prefix(7).map(\.key))
        let personCat = people.flatMap { p in
            a.group(current.filter { $0.personLabel == p.key }) { topCats.contains($0.category) ? $0.category : "Other" }
                .map { PersonCategory(person: p.key, category: $0.key, total: $0.total) }
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Vendors & People · \(store.period.label)").font(.largeTitle.weight(.bold))

            Card(title: "Spending by vendor", subtitle: "“Not set” = entries saved without a vendor (fuel, rides, eat-out…)") {
                Chart(vendors) { v in
                    BarMark(x: .value("Spent", v.total), y: .value("Vendor", v.key))
                        .foregroundStyle(Theme.color(for: v.key))
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text("\(Money.compact(v.total)) · \(v.count) items · avg \(Money.format(v.total / Double(max(1, v.count))))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...((vendors.first?.total ?? 1) * 1.6))
                .frame(height: max(140, CGFloat(vendors.count) * 26))
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "Who saved the entries") {
                    VStack(spacing: 10) {
                        ForEach(people) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: "person.crop.circle").foregroundStyle(Theme.color(for: p.key))
                                    Text(p.key).fontWeight(.medium)
                                    Spacer()
                                    Text(Money.format(p.total)).monospacedDigit()
                                }
                                Text("\(p.count) entries · \(total > 0 ? Money.percent(p.total / total * 100) : "0%")")
                                    .font(.caption).foregroundStyle(.secondary)
                                ShareBar(fraction: total > 0 ? p.total / total : 0, color: Theme.color(for: p.key))
                            }
                        }
                    }
                }
                .frame(maxWidth: 340)

                Card(title: "What each person spent on") {
                    Chart(personCat) { row in
                        BarMark(x: .value("Spent", row.total), y: .value("Person", row.person))
                            .foregroundStyle(by: .value("Category", row.category))
                    }
                    .chartForegroundStyleScale(domain: personCat.map(\.category).uniqued(),
                                               range: personCat.map(\.category).uniqued().map { Theme.color(for: $0) })
                    .chartXAxis {
                        AxisMarks { v in
                            AxisGridLine()
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Money.compact(d)) } }
                        }
                    }
                    .frame(height: max(120, CGFloat(people.count) * 50))
                }
            }
        }
    }
}

struct PersonCategory: Identifiable {
    var id: String { person + "|" + category }
    let person: String
    let category: String
    let total: Double
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

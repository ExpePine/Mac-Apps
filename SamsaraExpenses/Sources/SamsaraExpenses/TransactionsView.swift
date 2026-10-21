import SwiftUI
import SamsaraCore

struct TransactionsView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var category = "All"
    @State private var vendor = "All"
    @State private var person = "All"
    @State private var sortOrder = [KeyPathComparator(\Expense.sortDate, order: .reverse)]
    @State private var selection = Set<Expense.ID>()

    private var rows: [Expense] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var r = store.current.filter { e in
            (category == "All" || e.category == category)
            && (vendor == "All" || e.vendorLabel == vendor)
            && (person == "All" || e.personLabel == person)
            && (q.isEmpty
                || e.product.localizedCaseInsensitiveContains(q)
                || e.category.localizedCaseInsensitiveContains(q)
                || e.vendor.localizedCaseInsensitiveContains(q))
        }
        r.sort(using: sortOrder)
        return r
    }

    var body: some View {
        let rows = self.rows
        let selected = rows.filter { selection.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Category", selection: $category) {
                    Text("All categories").tag("All")
                    ForEach(store.analyzer.byCategory(store.current)) { Text($0.key).tag($0.key) }
                }
                .frame(maxWidth: 240)
                Picker("Vendor", selection: $vendor) {
                    Text("All vendors").tag("All")
                    ForEach(store.analyzer.byVendor(store.current)) { Text($0.key).tag($0.key) }
                }
                .frame(maxWidth: 220)
                Picker("Saved by", selection: $person) {
                    Text("Everyone").tag("All")
                    ForEach(store.analyzer.byPerson(store.current)) { Text($0.key).tag($0.key) }
                }
                .frame(maxWidth: 200)
                Spacer()
                Button {
                    store.exportWithPanel(rows, name: "samsara-\(store.period.tag.replacingOccurrences(of: ":", with: "-")).csv")
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.sortDate) { e in
                    Text(e.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No date")
                        .foregroundStyle(e.date == nil ? .secondary : .primary)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Product", value: \.product) { e in
                    Text(e.product).help(e.product)
                }
                .width(min: 160, ideal: 300)
                TableColumn("Category", value: \.category) { e in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(for: e.category)).frame(width: 8, height: 8)
                        Text(e.category)
                    }
                }
                .width(min: 100, ideal: 150)
                TableColumn("Vendor", value: \.vendorLabel) { e in
                    Text(e.vendorLabel).foregroundStyle(e.vendor.isEmpty ? .secondary : .primary)
                }
                .width(min: 80, ideal: 130)
                TableColumn("Saved by", value: \.personLabel)
                    .width(min: 60, ideal: 80)
                TableColumn("Qty", value: \.quantity)
                    .width(min: 50, ideal: 110)
                TableColumn("Amount", value: \.amount) { e in
                    Text(Money.exactFormat(e.amount))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
            }

            Divider()
            HStack {
                if selected.count > 1 {
                    Text("\(selected.count) selected · \(Money.exactFormat(Analyzer.total(selected)))")
                }
                Spacer()
                Text("\(rows.count) entries · \(Money.exactFormat(Analyzer.total(rows)))")
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .searchable(text: $search, prompt: "Search products, categories, vendors")
        .onChange(of: store.period) { _ in
            category = "All"; vendor = "All"; person = "All"; selection = []
        }
    }
}

import SwiftUI

/// Clicking a deal day on a delivery chart: all of that stock's deal days ranked by DEALSIZE (buy + sell ₹ Cr),
/// biggest first, with the clicked day highlighted — to see where it stands in the pecking order.
struct DealSizeRankView: View {
    let symbol: String
    let day: String
    @ObservedObject private var deals = DealsCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var last300 = false

    struct Row: Identifiable { let id: String; let buy: Double; let sell: Double; let count: Int; var total: Double { buy + sell } }

    private var rows: [Row] {
        let byDay = Dictionary(grouping: deals.bySymbol[symbol.uppercased()] ?? [], by: \.day)
        var r = byDay.map { d, list in
            Row(id: d, buy: list.filter(\.isBuy).reduce(0) { $0 + $1.valueCr },
                sell: list.filter { !$0.isBuy }.reduce(0) { $0 + $1.valueCr }, count: list.count)
        }
        if last300, let axis = DeliveryCenter.shared.book.series[symbol.uppercased()]?.days, let k = axis.firstIndex(of: day) {
            let from = axis[max(0, k - 300)]
            r = r.filter { $0.id >= from && $0.id <= day }
        }
        return r.sorted { $0.total > $1.total }
    }

    var body: some View {
        let list = rows
        let rank = (list.firstIndex { $0.id == day } ?? -1) + 1
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(symbol) — deal days by DEALSIZE").font(.headline)
                    Text(rank > 0 ? "\(day): #\(rank) of \(list.count) deal days" : "\(day) is not in this list")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Last 300 trading days", isOn: $last300).toggleStyle(.switch).controlSize(.small)
                    .help("Only the deal days in the 300 trading days up to the clicked day — the window DEAL_PRANK uses")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollViewReader { proxy in
                List {
                    HStack {
                        Text("#").frame(width: 34, alignment: .trailing)
                        Text("Day").frame(width: 92, alignment: .leading)
                        Text("DEALSIZE ₹ Cr").frame(width: 100, alignment: .trailing)
                        Text("Buy").frame(width: 80, alignment: .trailing)
                        Text("Sell").frame(width: 80, alignment: .trailing)
                        Text("Deals").frame(width: 46, alignment: .trailing)
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                        let me = r.id == day
                        HStack {
                            Text("\(i + 1)").frame(width: 34, alignment: .trailing)
                            Text(r.id).frame(width: 92, alignment: .leading)
                            Text(String(format: "%.1f", r.total)).bold().frame(width: 100, alignment: .trailing)
                            Text(String(format: "%.1f", r.buy)).foregroundStyle(.green).frame(width: 80, alignment: .trailing)
                            Text(String(format: "%.1f", r.sell)).foregroundStyle(.red).frame(width: 80, alignment: .trailing)
                            Text("\(r.count)").foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                        }
                        .font(.callout.monospacedDigit())
                        .padding(.vertical, 1)
                        .listRowBackground(me ? Color.yellow.opacity(0.28) : Color.clear)
                        .id(r.id)
                    }
                }
                .onAppear { proxy.scrollTo(day, anchor: .center) }
                .onChange(of: last300) { _ in proxy.scrollTo(day, anchor: .center) }
            }
        }
        .padding(14)
        .frame(width: 560, height: 520)
    }
}

/// Puts the DEALSIZE ranking sheet on a delivery chart.
struct DealRankPopup: ViewModifier {
    @ObservedObject var holder: LWChartHolder
    let symbol: String
    struct Pick: Identifiable { let id: String }
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { holder.dealDay.map { Pick(id: $0) } }, set: { if $0 == nil { holder.dealDay = nil } })) { p in
            DealSizeRankView(symbol: symbol, day: p.id)
        }
    }
}

extension View {
    func dealRankPopup(_ holder: LWChartHolder, symbol: String) -> some View { modifier(DealRankPopup(holder: holder, symbol: symbol)) }
}

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

/// Clicking a ▲ZP mark: the stock's days ranked by the Steep z (highest first) with Z_PRANK, the clicked day highlighted.
struct ZValueRankView: View {
    let symbol: String
    let day: String
    @Environment(\.dismiss) private var dismiss
    @State private var last300 = false
    @State private var onlyZP = false

    struct Row: Identifiable { let id: String; let z: Double; let pr: Double? }

    private var all: [Row] {
        guard let s = DeliveryCenter.shared.book.series[symbol.uppercased()] else { return [] }
        let r = Steep.series(s)
        let pr = Steep.zPRank(r.z)
        return s.days.indices.compactMap { i in
            guard i < r.z.count, let z = r.z[i] else { return nil }
            return Row(id: s.days[i], z: z, pr: i < pr.count ? pr[i] : nil)
        }
    }

    var body: some View {
        let base = all
        var list = base
        if last300, let k = base.firstIndex(where: { $0.id == day }) { list = Array(base[max(0, k - 300)...k]) }
        if onlyZP { list = list.filter { r in r.pr.map { ZPLevel.hit($0) } ?? false } }
        list.sort { $0.z > $1.z }
        let rank = (list.firstIndex { $0.id == day } ?? -1) + 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(symbol) — days by z (steepness of \(Steep.source == "delsma" ? "DELSMA" : "delivery value"))").font(.headline)
                    Text(rank > 0 ? "\(day): #\(rank) of \(list.count) days" : "\(day) is not in this list").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Last 300 days", isOn: $last300).toggleStyle(.switch).controlSize(.small)
                    .help("Only the 300 trading days up to the clicked day — the window Z_PRANK uses")
                Toggle("Only ▲ZP days", isOn: $onlyZP).toggleStyle(.switch).controlSize(.small)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollViewReader { proxy in
                List {
                    HStack {
                        Text("#").frame(width: 40, alignment: .trailing)
                        Text("Day").frame(width: 96, alignment: .leading)
                        Text("z").frame(width: 70, alignment: .trailing)
                        Text("Z_PRANK").frame(width: 80, alignment: .trailing)
                    }.font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                        HStack {
                            Text("\(i + 1)").frame(width: 40, alignment: .trailing)
                            Text(r.id).frame(width: 96, alignment: .leading)
                            Text(String(format: "%.2f", r.z)).bold().foregroundStyle(r.z > Steep.trig ? Color.green : Color.primary).frame(width: 70, alignment: .trailing)
                            Text(r.pr.map { String(format: "%.1f", $0) } ?? "—")
                                .foregroundStyle((r.pr ?? 0) >= 100 ? Color.yellow : Color.secondary).frame(width: 80, alignment: .trailing)
                        }
                        .font(.callout.monospacedDigit())
                        .listRowBackground(r.id == day ? Color.yellow.opacity(0.28) : Color.clear)
                        .id(r.id)
                    }
                }
                .onAppear { proxy.scrollTo(day, anchor: .center) }
                .onChange(of: last300) { _ in proxy.scrollTo(day, anchor: .center) }
                .onChange(of: onlyZP) { _ in proxy.scrollTo(day, anchor: .center) }
            }
        }
        .padding(14)
        .frame(width: 520, height: 520)
    }
}

/// Puts the DEALSIZE and z ranking sheets on a delivery chart (click B / S or ▲ZP).
struct DealRankPopup: ViewModifier {
    @ObservedObject var holder: LWChartHolder
    let symbol: String
    struct Pick: Identifiable { let id: String; let zp: Bool }
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: {
            if let d = holder.dealDay { return Pick(id: d, zp: false) }
            if let d = holder.zpDay { return Pick(id: d, zp: true) }
            return nil
        }, set: { if $0 == nil { holder.dealDay = nil; holder.zpDay = nil } })) { p in
            if p.zp { ZValueRankView(symbol: symbol, day: p.id) } else { DealSizeRankView(symbol: symbol, day: p.id) }
        }
    }
}

extension View {
    func dealRankPopup(_ holder: LWChartHolder, symbol: String) -> some View { modifier(DealRankPopup(holder: holder, symbol: symbol)) }
}

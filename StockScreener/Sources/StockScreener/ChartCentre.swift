import SwiftUI

/// One app-wide choice of where charts open centred — used by the Chart viewer, Chart Reel, Gainer Charts and chart
/// peeks until you change it (from the "Centre" menu on any of them).
///   • Last bar
///   • A Filter column whose value is "trading days ago" (D_Trigger = 3 → 3 trading days back; 0 = the data day)
///   • The stock's latest multibagger move: start of the month / day it crossed / peak / end of the month
/// A stock with no value in that column (or no multibagger move) falls back to the last bar.
/// Views with their own explicit centre (Event Scan, Studies, Chart Reel "value = days ago" / "day it started",
/// the Multibaggers reel) keep theirs.
enum ChartCentreKind: String { case last, column, mb }

enum ChartCentre {
    static let kindKey = "centre.kind", columnKey = "centre.column", mbKey = "mb.center"
    static var kind: ChartCentreKind { ChartCentreKind(rawValue: UserDefaults.standard.string(forKey: kindKey) ?? "") ?? .last }
    static var mbCenter: MBCenter { MBCenter(rawValue: UserDefaults.standard.string(forKey: mbKey) ?? "") ?? .start }
    static func column(_ vm: ScreenerViewModel) -> String {
        let c = UserDefaults.standard.string(forKey: columnKey) ?? ""
        return c.isEmpty ? vm.settings.triggerColumn : c
    }
    static func shortMB(_ c: MBCenter) -> String {
        switch c { case .start: return "start"; case .cross: return "cross day"; case .peak: return "peak"; case .end: return "end" }
    }
    @MainActor static func title(_ vm: ScreenerViewModel) -> String {
        switch kind {
        case .last: return "Last bar"
        case .column: return column(vm)
        case .mb: return "Multibagger \(shortMB(mbCenter))"
        }
    }
}

extension ScreenerViewModel {
    /// Builds the centring rule once (calendar, column, multibagger moves) → (symbol, row, fallback) → day to centre on.
    func centreResolver() -> @MainActor (String, SheetRow?, String?) -> String? {
        switch ChartCentre.kind {
        case .last:
            return { _, _, fb in fb }
        case .column:
            guard let ci = table.index(of: ChartCentre.column(self)) else { return { _, _, fb in fb } }
            let cal = ColumnCentre.calendar(self)
            let end = cal.lastIndex(where: { $0 <= displayedDayKey }) ?? cal.count - 1
            return { [weak self] sym, row, fb in
                guard end >= 0, let r = row ?? self?.row(for: sym), let v = r.number(ci), v >= 0 else { return fb }
                let k = end - Int(v.rounded())
                return k >= 0 ? cal[k] : fb
            }
        case .mb:
            let mbc = MultibaggerCenter.shared
            mbc.loadIfNeeded()
            let c = ChartCentre.mbCenter, upTo = displayedDayKey
            var latest: [String: MBEvent] = [:]
            for e in mbc.events where e.startDay <= upTo {
                if let old = latest[e.symbol], old.month >= e.month { continue }
                latest[e.symbol] = e
            }
            return { sym, _, fb in latest[sym.uppercased()].map { $0.day(for: c) } ?? fb }
        }
    }

    func centreDay(_ symbol: String, row: SheetRow? = nil, fallback: String? = nil) -> String? {
        centreResolver()(symbol, row, fallback)
    }
}

/// The "Centre" menu shown on chart windows. Changing it changes every chart's default.
struct ChartCentreMenu: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @AppStorage(ChartCentre.kindKey) private var kind = ChartCentreKind.last.rawValue
    @AppStorage(ChartCentre.columnKey) private var column = ""
    @AppStorage(ChartCentre.mbKey) private var mb = MBCenter.start.rawValue

    var body: some View {
        Menu {
            Button { kind = ChartCentreKind.last.rawValue } label: { check(kind == ChartCentreKind.last.rawValue, "Last bar") }
            Divider()
            Text("Column — value = trading days ago")
            let trig = vm.settings.triggerColumn
            let cur = column.isEmpty ? trig : column
            Button { column = ""; kind = ChartCentreKind.column.rawValue } label: { check(kind == ChartCentreKind.column.rawValue && cur == trig, trig) }
            if kind == ChartCentreKind.column.rawValue && cur != trig {
                Button {} label: { check(true, cur) }
            }
            Menu("Other column…") {
                ForEach(numericColumns, id: \.self) { h in
                    Button { column = h; kind = ChartCentreKind.column.rawValue } label: { check(kind == ChartCentreKind.column.rawValue && cur == h, h) }
                }
            }
            Divider()
            Text("Multibagger move (the stock's latest)")
            ForEach(MBCenter.allCases) { c in
                Button { mb = c.rawValue; kind = ChartCentreKind.mb.rawValue } label: { check(kind == ChartCentreKind.mb.rawValue && mb == c.rawValue, c.rawValue) }
            }
        } label: {
            Label("Centre: \(label)", systemImage: "scope")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Where every chart opens centred — stays until you change it. Stocks without a value (or a multibagger move) open at the last bar.")
    }

    private var label: String {
        _ = kind; _ = column; _ = mb
        return ChartCentre.title(vm)
    }

    @ViewBuilder private func check(_ on: Bool, _ t: String) -> some View {
        if on { Label(t, systemImage: "checkmark") } else { Text(t) }
    }

    /// Columns that hold numbers in today's sheet (checks the first rows).
    private var numericColumns: [String] {
        let rows = vm.table.rows.prefix(200)
        return vm.table.headers.enumerated().compactMap { i, h in
            rows.contains { $0.number(i) != nil } ? h : nil
        }
    }
}

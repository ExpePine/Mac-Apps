import SwiftUI

/// Where charts open centred — remembered separately for each place you look at charts from, so Daily Gainers
/// never inherit the Multibaggers choice (and the other way round):
///   • Daily gainers (Daily Gainers window, Gainer Charts, Chart Reel "Daily gainers")
///   • Filter (Filter table, chart peeks, Chart Reel "My Filter" / "Column filter" / "All stocks")
///   • Multibaggers (Multibaggers window, Chart Reel "Multibaggers")
///   • Other (charts opened from anywhere else)
/// Options: last bar · a Filter column whose value is "trading days ago" (D_Trigger = 3 → 3 trading days back) ·
/// the multibagger move (start / day it crossed / peak / end of the month).
/// A stock with no value in that column (or no multibagger move) falls back to the last bar.
/// Event Scan, Studies and the Chart Reel's "value = days ago" / "day it started" keep their own dates.
enum ChartCentreKind: String { case last, column, mb }

enum ChartContext: String, CaseIterable, Identifiable {
    case gainers, filter, multibaggers, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gainers: return "Daily gainers"
        case .filter: return "Filter"
        case .multibaggers: return "Multibaggers"
        case .other: return "Other charts"
        }
    }
    /// Multibagger dates make no sense for a day's gainers.
    var offersMB: Bool { self != .gainers }
}

enum ChartCentre {
    static func kindKey(_ c: ChartContext) -> String { "centre.kind." + c.rawValue }
    static func columnKey(_ c: ChartContext) -> String { "centre.column." + c.rawValue }
    /// The Multibaggers context shares its sub-option with the Multibaggers window's "Chart centre" picker.
    static func mbKey(_ c: ChartContext) -> String { c == .multibaggers ? "mb.center" : "centre.mb." + c.rawValue }

    static func kind(_ c: ChartContext) -> ChartCentreKind {
        if let k = UserDefaults.standard.string(forKey: kindKey(c)).flatMap(ChartCentreKind.init(rawValue:)) {
            return k == .mb && !c.offersMB ? .last : k
        }
        return c == .multibaggers ? .mb : .last
    }
    static func mbCenter(_ c: ChartContext) -> MBCenter { MBCenter(rawValue: UserDefaults.standard.string(forKey: mbKey(c)) ?? "") ?? .start }
    @MainActor static func column(_ c: ChartContext, _ vm: ScreenerViewModel) -> String {
        let s = UserDefaults.standard.string(forKey: columnKey(c)) ?? ""
        return s.isEmpty ? vm.settings.triggerColumn : s
    }
    static func shortMB(_ c: MBCenter) -> String {
        switch c { case .start: return "start"; case .cross: return "cross day"; case .peak: return "peak"; case .end: return "end" }
    }
    @MainActor static func title(_ c: ChartContext, _ vm: ScreenerViewModel) -> String {
        switch kind(c) {
        case .last: return "Last bar"
        case .column: return column(c, vm)
        case .mb: return "Multibagger \(shortMB(mbCenter(c)))"
        }
    }
}

extension ScreenerViewModel {
    /// The newest trading day up to the day on screen.
    var lastBarDay: String? { ColumnCentre.calendar(self).last(where: { $0 <= displayedDayKey }) }

    /// Builds the centring rule for a context once → (symbol, row, fallback) → day to centre on.
    /// "Last bar" = the fallback (e.g. the gainer day), else the newest trading day.
    func centreResolver(_ ctx: ChartContext) -> @MainActor (String, SheetRow?, String?) -> String? {
        let last = lastBarDay
        switch ChartCentre.kind(ctx) {
        case .last:
            return { _, _, fb in fb ?? last }
        case .column:
            guard let ci = table.index(of: ChartCentre.column(ctx, self)) else { return { _, _, fb in fb ?? last } }
            let cal = ColumnCentre.calendar(self)
            let end = cal.lastIndex(where: { $0 <= displayedDayKey }) ?? cal.count - 1
            return { [weak self] sym, row, fb in
                guard end >= 0, let r = row ?? self?.row(for: sym), let v = r.number(ci), v >= 0 else { return fb ?? last }
                let k = end - Int(v.rounded())
                return k >= 0 ? cal[k] : (fb ?? last)
            }
        case .mb:
            let mbc = MultibaggerCenter.shared
            mbc.loadIfNeeded()
            let c = ChartCentre.mbCenter(ctx), upTo = displayedDayKey
            var latest: [String: MBEvent] = [:]
            for e in mbc.events where e.startDay <= upTo {
                if let old = latest[e.symbol], old.month >= e.month { continue }
                latest[e.symbol] = e
            }
            return { sym, _, fb in latest[sym.uppercased()].map { $0.day(for: c) } ?? fb ?? last }
        }
    }

    func centreDay(_ symbol: String, _ ctx: ChartContext, row: SheetRow? = nil, fallback: String? = nil) -> String? {
        centreResolver(ctx)(symbol, row, fallback)
    }
}

/// The "Centre" menu on chart windows — changes the choice for that context only.
struct ChartCentreMenu: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let context: ChartContext
    @AppStorage private var kind: String
    @AppStorage private var column: String
    @AppStorage private var mb: String

    init(context: ChartContext) {
        self.context = context
        _kind = AppStorage(wrappedValue: "", ChartCentre.kindKey(context))
        _column = AppStorage(wrappedValue: "", ChartCentre.columnKey(context))
        _mb = AppStorage(wrappedValue: MBCenter.start.rawValue, ChartCentre.mbKey(context))
    }

    var body: some View {
        let current = ChartCentre.kind(context)
        Menu {
            Text("Centre \(context.title) charts on")
            Button { kind = ChartCentreKind.last.rawValue } label: { check(current == .last, "Last bar") }
            Divider()
            Text("Column — value = trading days ago")
            let trig = vm.settings.triggerColumn
            let cur = column.isEmpty ? trig : column
            Button { column = ""; kind = ChartCentreKind.column.rawValue } label: { check(current == .column && cur == trig, trig) }
            if current == .column && cur != trig {
                Button {} label: { check(true, cur) }
            }
            Menu("Other column…") {
                ForEach(numericColumns, id: \.self) { h in
                    Button { column = h; kind = ChartCentreKind.column.rawValue } label: { check(current == .column && cur == h, h) }
                }
            }
            if context.offersMB {
                Divider()
                Text(context == .multibaggers ? "Multibagger move" : "Multibagger move (the stock's latest)")
                ForEach(MBCenter.allCases) { c in
                    Button { mb = c.rawValue; kind = ChartCentreKind.mb.rawValue } label: { check(current == .mb && mb == c.rawValue, c.rawValue) }
                }
            }
        } label: {
            Label("Centre: \(label)", systemImage: "scope")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Where \(context.title) charts open centred — kept for \(context.title) only, until you change it. Stocks without a value open at the last bar.")
    }

    private var label: String {
        _ = kind; _ = column; _ = mb
        return ChartCentre.title(context, vm)
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

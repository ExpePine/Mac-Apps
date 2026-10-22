import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Timing Lab
//
// A special experiment: a sheet with one row per stock, an as-of date, a SHORTLIST column and one or more
// BUY-TRIGGER columns, each holding "trading days ago" (Pine ta.barssince style) counted back from the as-of date.
// For every trigger it finds the real day on the stock's Yahoo bars, keeps it only if it fired on / after the
// shortlist day, buys at that day's close and measures:
//   • the return and peak gain 5 / 21 / 63 trading days later (only trades old enough for the window),
//   • the return from the trigger to the latest close.
// The shortlist day itself is shown as a reference entry, and triggers are compared head to head.

struct TLInputRow {
    let symbol: String
    let asOf: String          // yyyy-MM-dd
    let shortlist: Int?       // trading days ago
    let triggers: [Int?]      // trading days ago, one per trigger column
}

struct TLTrade: Identifiable {
    let id = UUID()
    let symbol: String
    let entryName: String     // "Shortlist day" or the trigger's name
    let shortlistDay: String
    let day: String
    let wait: Int             // trading days after the shortlist
    let entry: Double
    var ret: [Int: Double] = [:]      // window → % return
    var peak: [Int: Double] = [:]     // window → highest % gain at a close within it
    let toToday: Double
    let held: Int                     // trading days from the trigger to the latest bar
}

struct TLWindowStat { var n = 0; var avg = 0.0; var median = 0.0; var win = 0.0; var avgPeak = 0.0 }

struct TLStat: Identifiable {
    var id: String { name }
    let name: String
    let isReference: Bool
    var trades = 0
    var beforeShortlist = 0       // ignored: fired before the shortlist
    var blank = 0                 // no value in the sheet
    var noPrice = 0               // no Yahoo bars far enough back
    var medianWait: Double?
    var windows: [Int: TLWindowStat] = [:]
    var today = TLWindowStat()
    var avgHeld = 0.0
}

struct TLHeadToHead: Identifiable {
    var id: String { a + "|" + b }
    let a: String, b: String
    let window: Int
    let both: Int
    let aBetter: Int
    let bBetter: Int
    let aFirst: Int               // stocks where a fired earlier than b
}

struct TLResult {
    var stats: [TLStat] = []
    var trades: [TLTrade] = []
    var h2h: [TLHeadToHead] = []
    var rows = 0
    var notes: [String] = []
}

enum TLEngine {
    static let windows = [5, 21, 63]

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func stat(_ r: [Double], peaks: [Double] = []) -> TLWindowStat {
        guard !r.isEmpty else { return TLWindowStat() }
        return TLWindowStat(n: r.count, avg: r.reduce(0, +) / Double(r.count), median: median(r),
                            win: Double(r.filter { $0 > 0 }.count) / Double(r.count) * 100,
                            avgPeak: peaks.isEmpty ? 0 : peaks.reduce(0, +) / Double(peaks.count))
    }

    /// One entry at bar `e` of series `s`.
    static func trade(_ s: PriceSeries, e: Int, symbol: String, name: String, shortlistDay: String, wait: Int) -> TLTrade {
        let entry = s.closes[e]
        var t = TLTrade(symbol: symbol, entryName: name, shortlistDay: shortlistDay, day: s.days[e], wait: wait, entry: entry,
                        toToday: (s.closes[s.closes.count - 1] / entry - 1) * 100, held: s.closes.count - 1 - e)
        for w in windows where e + w < s.closes.count {
            t.ret[w] = (s.closes[e + w] / entry - 1) * 100
            t.peak[w] = ((s.closes[(e + 1)...(e + w)].max() ?? entry) / entry - 1) * 100
        }
        return t
    }

    static func run(_ rows: [TLInputRow], names: [String], series: [String: PriceSeries], onlyAfterShortlist: Bool = true) -> TLResult {
        var res = TLResult()
        res.rows = rows.count
        var stats = [TLStat(name: "Shortlist day", isReference: true)] + names.map { TLStat(name: $0, isReference: false) }
        var trades: [TLTrade] = []
        var waits: [[Double]] = Array(repeating: [], count: names.count)
        // per stock, per trigger: (entry index, trade) for head-to-head
        var perStock: [String: [Int: (Int, TLTrade)]] = [:]

        for r in rows {
            guard let s = series[r.symbol], s.closes.count > 1, let i0 = s.index(onOrBefore: r.asOf) else {
                stats[0].noPrice += 1
                for k in names.indices { stats[k + 1].noPrice += 1 }
                continue
            }
            guard let sl = r.shortlist else {
                stats[0].blank += 1
                for k in names.indices { stats[k + 1].blank += 1 }
                continue
            }
            let si = i0 - sl
            guard si >= 0, s.closes[si] > 0 else {
                stats[0].noPrice += 1
                for k in names.indices { stats[k + 1].noPrice += 1 }
                continue
            }
            trades.append(trade(s, e: si, symbol: r.symbol, name: "Shortlist day", shortlistDay: s.days[si], wait: 0))
            for k in names.indices {
                guard k < r.triggers.count, let n = r.triggers[k] else { stats[k + 1].blank += 1; continue }
                let ti = i0 - n
                guard ti >= 0, s.closes[ti] > 0 else { stats[k + 1].noPrice += 1; continue }
                if onlyAfterShortlist && ti < si { stats[k + 1].beforeShortlist += 1; continue }
                let t = trade(s, e: ti, symbol: r.symbol, name: names[k], shortlistDay: s.days[si], wait: ti - si)
                trades.append(t)
                waits[k].append(Double(ti - si))
                perStock[r.symbol, default: [:]][k] = (ti, t)
            }
        }
        for (k, var st) in stats.enumerated() {
            let mine = trades.filter { $0.entryName == st.name }
            st.trades = mine.count
            for w in windows {
                let have = mine.filter { $0.ret[w] != nil }
                st.windows[w] = stat(have.map { $0.ret[w]! }, peaks: have.map { $0.peak[w]! })
            }
            st.today = stat(mine.map(\.toToday))
            st.avgHeld = mine.isEmpty ? 0 : Double(mine.map(\.held).reduce(0, +)) / Double(mine.count)
            if k > 0, !waits[k - 1].isEmpty { st.medianWait = median(waits[k - 1]) }
            stats[k] = st
        }
        // Head to head: stocks where both triggers count, compared on the 21-day return
        for a in names.indices { for b in names.indices where b > a {
            var both = 0, aB = 0, bB = 0, aF = 0
            for (_, m) in perStock {
                guard let x = m[a], let y = m[b], let ra = x.1.ret[21], let rb = y.1.ret[21] else { continue }
                both += 1
                if ra > rb { aB += 1 } else if rb > ra { bB += 1 }
                if x.0 < y.0 { aF += 1 }
            }
            res.h2h.append(TLHeadToHead(a: names[a], b: names[b], window: 21, both: both, aBetter: aB, bBetter: bB, aFirst: aF))
        } }
        res.stats = stats
        res.trades = trades
        return res
    }

    /// Plain-English lines (computed here — no AI).
    static func verdict(_ r: TLResult) -> [String] {
        var out: [String] = []
        guard let ref = r.stats.first(where: \.isReference) else { return out }
        for w in [21, 63, 5] {
            let refW = ref.windows[w] ?? TLWindowStat()
            let cands = r.stats.filter { !$0.isReference && ($0.windows[w]?.n ?? 0) >= 10 }
            guard !cands.isEmpty, refW.n >= 10 else { continue }
            for c in cands {
                let cw = c.windows[w]!
                let diff = cw.avg - refW.avg
                out.append(String(format: "%@ · %d trading days: average %+.1f%% (median %+.1f%%, %.0f%% winners, %d trades) — %@ buying on the shortlist day (%+.1f%%) by %.1f points.",
                                  c.name, w, cw.avg, cw.median, cw.win, cw.n, diff >= 0 ? "beats" : "trails", refW.avg, abs(diff)))
            }
            if cands.count >= 2 {
                let best = cands.max { ($0.windows[w]?.median ?? 0) < ($1.windows[w]?.median ?? 0) }!
                out.append("Best median at \(w) days: \(best.name).")
            }
            break
        }
        for h in r.h2h where h.both >= 10 {
            out.append(String(format: "Head to head on %d stocks where both fired after the shortlist: %@ did better over 21 days in %d (%.0f%%), %@ in %d (%.0f%%). %@ fired first in %d of them.",
                              h.both, h.a, h.aBetter, Double(h.aBetter) / Double(h.both) * 100, h.b, h.bBetter, Double(h.bBetter) / Double(h.both) * 100, h.a, h.aFirst))
        }
        for s in r.stats where !s.isReference && s.beforeShortlist > 0 {
            out.append("\(s.name): \(s.beforeShortlist) trigger\(s.beforeShortlist == 1 ? "" : "s") fired before the shortlist and were ignored.")
        }
        if out.isEmpty { out.append("Not enough trades old enough to judge yet (needs ≥ 10 trades with 5+ trading days after the trigger).") }
        return out
    }
}

// MARK: - Sheet reading

enum TLSheet {
    /// yyyy-MM-dd from a sheet date. `monthFirst` decides 05/06/2026 (detected per column).
    static func day(_ s: String, monthFirst: Bool) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." }).map(String.init)
        if parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), var y = Int(parts[2].prefix(4)) {
            if parts[0].count == 4 { return String(format: "%04d-%02d-%02d", a, b, y) }     // yyyy-MM-dd
            if y < 100 { y += 2000 }
            let (m, d) = monthFirst ? (a, b) : (b, a)
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        guard let d = DateParser.parse(t) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Month-first when some value's second number is > 12 (e.g. 10/22/2026); day-first when the first is > 12.
    static func monthFirst(_ values: [String]) -> Bool {
        var mf = 0, df = 0
        for v in values.prefix(2000) {
            let p = v.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." })
            guard p.count == 3, p[0].count <= 2, let a = Int(p[0]), let b = Int(p[1]) else { continue }
            if b > 12 { mf += 1 } else if a > 12 { df += 1 }
        }
        return mf > df
    }

    /// "bars ago" cell: a non-negative whole number; blank / ∅ / text = nil.
    static func bars(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let v = Double(t), v >= 0, v.isFinite else { return nil }
        return Int(v.rounded())
    }

    static func rows(_ t: SheetTable, symbol: Int, date: Int?, shortlist: Int, triggers: [Int], fallbackDay: String) -> [TLInputRow] {
        let mf = date.map { c in monthFirst(t.rows.map { $0.text(c) }) } ?? false
        return t.rows.compactMap { r in
            let sym = r.text(symbol).trimmingCharacters(in: .whitespaces).uppercased()
            guard !sym.isEmpty else { return nil }
            let d = date.flatMap { day(r.text($0), monthFirst: mf) } ?? fallbackDay
            return TLInputRow(symbol: sym, asOf: d, shortlist: bars(r.text(shortlist)), triggers: triggers.map { bars(r.text($0)) })
        }
    }
}

// MARK: - State

@MainActor final class TimingLabCenter: ObservableObject {
    static let shared = TimingLabCenter()
    @Published var table: SheetTable?
    @Published var result: TLResult?
    @Published var status: String?
    @Published var busy = false
    @Published var progress: (Int, Int) = (0, 0)
    private var prices: [String: PriceSeries] = [:]

    func importLink(_ link: String) {
        guard let url = SheetService.csvURL(from: link) else { status = "That doesn't look like a Google Sheet / CSV link."; return }
        busy = true; status = "Downloading the sheet…"
        Task {
            do { table = try await SheetService.fetch(from: url).table; status = "Sheet: \(table?.rows.count ?? 0) rows" }
            catch { status = "Couldn't download: \(error.localizedDescription)" }
            busy = false
        }
    }

    func importFile(_ url: URL) {
        do { table = try SheetService.parse(try Data(contentsOf: url)).table; status = "File: \(table?.rows.count ?? 0) rows" }
        catch { status = "Couldn't read the file (CSV needed): \(error.localizedDescription)" }
    }

    /// Fetches Yahoo history long enough for the oldest event (+ 63 days), then runs the engine.
    func run(rows: [TLInputRow], names: [String], book: PriceBook) {
        guard !busy else { return }
        busy = true
        let maxBars = rows.map { max($0.shortlist ?? 0, $0.triggers.compactMap { $0 }.max() ?? 0) }.max() ?? 0
        let need = maxBars + 70
        let symbols = Array(Set(rows.map(\.symbol)))
        let missing = symbols.filter { s in (prices[s] ?? book.series(for: s)).map { $0.closes.count < need } ?? true }
        let range = need > 1000 ? "10y" : (need > 480 ? "5y" : "2y")
        Task {
            if !missing.isEmpty {
                status = "Yahoo prices for \(missing.count) stocks (\(range))…"
                let (b, failed) = await YahooClient.fetchAll(missing, range: range, width: 8) { [weak self] d, t in self?.progress = (d, t) }
                for (k, v) in b.series { prices[k] = v }
                if !failed.isEmpty { status = "\(failed.count) symbols not found on Yahoo" }
            }
            var series: [String: PriceSeries] = [:]
            for s in symbols {
                // long Yahoo history, topped up with the price book's newer (live) days
                let b = book.series(for: s)
                if let a = prices[s] { series[s] = b.map { a.merged(with: $0) } ?? a } else { series[s] = b }
            }
            let ready = series
            let r = await Task.detached(priority: .userInitiated) { TLEngine.run(rows, names: names, series: ready) }.value
            result = r
            busy = false
            status = "Done: \(r.trades.count) entries from \(r.rows) rows"
        }
    }
}

// MARK: - Window

struct TimingLabView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var lab = TimingLabCenter.shared
    @AppStorage("tl.link") private var link = ""
    @AppStorage("tl.symbol") private var symbolCol = ""
    @AppStorage("tl.date") private var dateCol = ""
    @AppStorage("tl.shortlist") private var shortlistCol = ""
    @AppStorage("tl.triggers") private var triggersRaw = ""          // column names joined by "|"
    @State private var tradeFilter = "All"
    @State private var selTrade: TLTrade.ID?
    @State private var showFileImporter = false

    private var headers: [String] { lab.table?.headers ?? [] }
    private var triggers: [String] { triggersRaw.split(separator: "|").map(String.init).filter { headers.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            source
            Divider()
            if lab.table != nil { mapping; Divider() }
            if let r = lab.result { results(r) } else {
                VStack(spacing: 8) {
                    Image(systemName: "timer").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Timing Lab").font(.title2.bold())
                    Text("Import a sheet with a Symbol column, a date, a SHORTLIST column and BUY-TRIGGER columns — each holding trading days ago (like Pine's ta.barssince). The lab finds each day on Yahoo's bars, keeps triggers that fired on / after the shortlist, buys at that day's close and measures the 5 / 21 / 63-day results and the return to today.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 640)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Timing Lab")
        .onChange(of: lab.table?.headers ?? []) { _ in autoMap() }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { r in
            if case .success(let url) = r { let ok = url.startAccessingSecurityScopedResource(); lab.importFile(url); if ok { url.stopAccessingSecurityScopedResource() } }
        }
    }

    private var source: some View {
        HStack(spacing: 8) {
            TextField("Google Sheet link (shared: anyone with the link can view)", text: $link).textFieldStyle(.roundedBorder)
            Button("Import") { lab.importLink(link) }.disabled(link.isEmpty || lab.busy)
            Button("CSV file…") { showFileImporter = true }
            if lab.busy { ProgressView().controlSize(.small); if lab.progress.1 > 0 { Text("\(lab.progress.0)/\(lab.progress.1)").font(.caption.monospacedDigit()) } }
            if let s = lab.status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .controlSize(.small)
        .padding(10)
    }

    private var mapping: some View {
        FlowLayout(spacing: 14, lineSpacing: 8) {
            picker("Symbol", $symbolCol)
            picker("As-of date", $dateCol, allowNone: true)
            picker("Shortlist (days ago)", $shortlistCol)
            HStack(spacing: 6) {
                Text("Buy triggers (days ago):").font(.caption.bold())
                ForEach(headers.filter { $0 != symbolCol && $0 != dateCol && $0 != shortlistCol }, id: \.self) { h in
                    Toggle(h, isOn: Binding(get: { triggers.contains(h) }, set: { on in
                        var t = triggers; if on { t.append(h) } else { t.removeAll { $0 == h } }
                        triggersRaw = t.joined(separator: "|")
                    })).toggleStyle(.checkbox)
                }
            }.fixedSize()
            Button { run() } label: { Label("Run experiment", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(lab.busy || symbolCol.isEmpty || shortlistCol.isEmpty || triggers.isEmpty)
            Text("Days ago are counted on each stock's own trading days back from the as-of date (Pine ta.barssince); entry = that day's close.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
        .controlSize(.small)
        .padding(10)
    }

    private func picker(_ title: String, _ sel: Binding<String>, allowNone: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption.bold())
            Picker("", selection: sel) {
                if allowNone { Text("— (latest day)").tag("") } else if sel.wrappedValue.isEmpty { Text("Pick…").tag("") }
                ForEach(headers, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().fixedSize()
        }.fixedSize()
    }

    /// Guesses the columns: Symbol, a *date* column, the first numeric column = shortlist, the rest = triggers.
    private func autoMap() {
        let h = headers
        guard !h.isEmpty, let t = lab.table else { return }
        if !h.contains(symbolCol) { symbolCol = h.first { $0.lowercased().contains("symbol") } ?? h[0] }
        if !dateCol.isEmpty && !h.contains(dateCol) { dateCol = "" }
        if dateCol.isEmpty { dateCol = h.first { $0.lowercased().contains("date") } ?? "" }
        let numeric = h.enumerated().filter { i, name in
            name != symbolCol && name != dateCol && t.rows.prefix(200).compactMap { $0.number(i) }.count >= max(1, min(20, t.rows.count / 3))
                && !t.rows.prefix(200).compactMap { $0.number(i) }.allSatisfy { $0 == 1 }       // skip constant flags like "dum"
        }.map(\.element)
        if !h.contains(shortlistCol) { shortlistCol = numeric.first ?? "" }
        if triggers.isEmpty { triggersRaw = numeric.filter { $0 != shortlistCol }.joined(separator: "|") }
    }

    private func run() {
        guard let t = lab.table, let sc = t.index(of: symbolCol), let sl = t.index(of: shortlistCol) else { return }
        let tc = triggers.compactMap { t.index(of: $0) }
        let fallback = HistoryStore.dayKey(Date())
        let rows = TLSheet.rows(t, symbol: sc, date: t.index(of: dateCol), shortlist: sl, triggers: tc, fallbackDay: fallback)
        lab.run(rows: rows, names: triggers, book: vm.priceBook)
    }

    // MARK: Results

    private func fmt(_ v: Double) -> String { String(format: "%+.1f%%", v) }

    private func results(_ r: TLResult) -> some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(TLEngine.verdict(r).enumerated()), id: \.offset) { _, l in
                            Text("• " + l).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    summaryGrid(r)
                    Text("Returns are close-to-close from the entry day; “peak” = highest close within the window. Only trades old enough for a window count in it. Trades on the same days move together, so treat small differences as noise. Past results don't promise future ones.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
            .frame(minHeight: 260)
            tradesTable(r).frame(minHeight: 200)
        }
    }

    private func summaryGrid(_ r: TLResult) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Entry").bold().gridColumnAlignment(.leading)
                Text("Trades").bold(); Text("Ignored*").bold(); Text("Blank / no price").bold(); Text("Wait").bold()
                ForEach(TLEngine.windows, id: \.self) { w in Text("\(w)d avg · med · win · peak").bold() }
                Text("→ today avg · med · win").bold(); Text("Held").bold()
            }
            .font(.caption)
            Divider()
            ForEach(r.stats) { s in
                GridRow {
                    Text(s.isReference ? "\(s.name) (reference)" : s.name).fontWeight(s.isReference ? .regular : .semibold)
                        .foregroundStyle(s.isReference ? Color.secondary : Color.primary).gridColumnAlignment(.leading)
                    Text("\(s.trades)")
                    Text(s.isReference ? "—" : "\(s.beforeShortlist)")
                    Text("\(s.blank) / \(s.noPrice)")
                    Text(s.medianWait.map { String(format: "%.0f d", $0) } ?? "—")
                    ForEach(TLEngine.windows, id: \.self) { w in
                        let x = s.windows[w] ?? TLWindowStat()
                        Text(x.n == 0 ? "—" : "\(fmt(x.avg)) · \(fmt(x.median)) · \(Int(x.win))% · \(fmt(x.avgPeak))  (\(x.n))")
                            .foregroundStyle(x.avg >= 0 ? Color.green : Color.red)
                    }
                    Text(s.today.n == 0 ? "—" : "\(fmt(s.today.avg)) · \(fmt(s.today.median)) · \(Int(s.today.win))%")
                        .foregroundStyle(s.today.avg >= 0 ? Color.green : Color.red)
                    Text(String(format: "%.0f d", s.avgHeld))
                }
                .font(.callout.monospacedDigit())
            }
        }
        .padding(.top, 4)
        .help("* Ignored = the trigger fired before the shortlist day. Wait = median trading days from shortlist to trigger. Held = average trading days from entry to the latest bar.")
    }

    private func tradesTable(_ r: TLResult) -> some View {
        let names = ["All"] + r.stats.map(\.name)
        let list = tradeFilter == "All" ? r.trades : r.trades.filter { $0.entryName == tradeFilter }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("", selection: $tradeFilter) { ForEach(names, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
                Text("\(list.count) entries · double-click = chart").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV…") { export(r) }
            }
            .controlSize(.small).padding(.horizontal, 10).padding(.top, 6)
            Table(list, selection: $selTrade) {
                TableColumn("Symbol") { t in Text(t.symbol).bold() }.width(min: 80, ideal: 100)
                TableColumn("Entry") { t in Text(t.entryName) }.width(min: 80, ideal: 100)
                TableColumn("Shortlist") { t in Text(t.shortlistDay).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Bought") { t in Text(t.day).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Wait") { t in Text("\(t.wait) d").monospacedDigit() }.width(min: 40, ideal: 50)
                TableColumn("Price") { t in Text(String(format: "%.2f", t.entry)).monospacedDigit() }.width(min: 60, ideal: 70)
                TableColumn("5d") { t in cell(t.ret[5]) }.width(min: 50, ideal: 60)
                TableColumn("21d") { t in cell(t.ret[21]) }.width(min: 50, ideal: 60)
                TableColumn("63d") { t in cell(t.ret[63]) }.width(min: 50, ideal: 60)
                TableColumn("→ today") { t in cell(t.toToday) }.width(min: 60, ideal: 70)
            }
            .contextMenu(forSelectionType: TLTrade.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let t = list.first(where: { $0.id == id }) { vm.openChart(t.symbol, queue: list.map(\.symbol), openWindow: openWindow) }
            }
        }
    }

    private func cell(_ v: Double?) -> some View {
        Text(v.map { fmt($0) } ?? "—").monospacedDigit().foregroundStyle(v.map { $0 >= 0 ? Color.green : Color.red } ?? Color.secondary)
    }

    private func export(_ r: TLResult) {
        let p = NSSavePanel(); p.nameFieldStringValue = "timing-lab.csv"; p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        var s = "symbol,entry,shortlist_day,bought,wait_days,price,ret_5d,ret_21d,ret_63d,peak_21d,to_today,held_days\n"
        func n(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        for t in r.trades {
            s += "\(t.symbol),\(t.entryName),\(t.shortlistDay),\(t.day),\(t.wait),\(n(t.entry)),\(n(t.ret[5])),\(n(t.ret[21])),\(n(t.ret[63])),\(n(t.peak[21])),\(n(t.toToday)),\(t.held)\n"
        }
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}

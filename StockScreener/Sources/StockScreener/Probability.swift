import SwiftUI
import AppKit

// MARK: - Count & Probability
//
// "If count = 5 today, how likely is a top gainer?" For every stored daily snapshot (stock × day) the outcome is
// read from Yahoo prices: DAILY top gainer = next trading day's close ≥ +5% vs that day; MONTHLY top gainer =
// highest close within the next 21 trading days ≥ +30%. Then for every value of every discrete Filter column
// (count = 0…5, Long_Green = 1 …) and every pair / triple of them, it counts the stock-days and how many were
// followed by a top gainer → probability, lift vs all stocks, and a 95% range (Wilson).

struct ProbRow: Identifiable {
    var id: String { name }
    let name: String
    let parts: [(col: Int, value: Double)]
    let size: Int
    let n: Int
    let nDaily: Int, hitDaily: Int
    let nMonthly: Int, hitMonthly: Int
    var today = 0
    var pDaily: Double? { nDaily > 0 ? Double(hitDaily) / Double(nDaily) : nil }
    var pMonthly: Double? { nMonthly > 0 ? Double(hitMonthly) / Double(nMonthly) : nil }
}

struct ProbResult {
    var rows: [ProbRow] = []
    var stockDays = 0
    var days = 0
    var baseDaily = 0.0, baseMonthly = 0.0
    var nDaily = 0, nMonthly = 0
    var columns: [String] = []
    var note = ""
}

enum ProbEngine {
    /// Columns worth enumerating: numeric with 2…12 distinct values (flags, counts, small scores).
    static func discreteColumns(_ t: SheetTable, skip: Int?) -> [Int] {
        t.headers.indices.filter { c in
            guard c != skip else { return false }
            var seen = Set<Double>()
            var numeric = 0
            for r in t.rows.prefix(3000) {
                guard let v = r.number(c) else { continue }
                numeric += 1
                seen.insert(v)
                if seen.count > 12 { return false }
            }
            return seen.count >= 2 && numeric >= max(5, min(t.rows.count, 3000) / 3)
        }
    }

    struct Day { let day: String; let table: SheetTable }

    static func run(days: [Day], label: Int, columns: [Int], names: [String], book: PriceBook, current: SheetTable,
                    dailyMin: Double, monthlyMin: Double, maxSize: Int, minN: Int) -> ProbResult {
        var res = ProbResult()
        res.columns = columns.map { names[$0] }
        // 1. rows with outcomes
        var vals: [[Double?]] = []          // per row, per column
        var dOK: [Bool] = [], dHit: [Bool] = [], mOK: [Bool] = [], mHit: [Bool] = []
        for d in days {
            for r in d.table.rows {
                let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                guard let s = book.series(for: sym), let i = s.index(onOrBefore: d.day), s.closes[i] > 0 else { continue }
                var dk = false, dh = false, mk = false, mh = false
                if i + 1 < s.closes.count { dk = true; dh = (s.closes[i + 1] / s.closes[i] - 1) * 100 >= dailyMin }
                if let f = s.forward(21, from: d.day) { mk = true; mh = f.maxGain >= monthlyMin }
                guard dk || mk else { continue }
                vals.append(columns.map { r.number($0) })
                dOK.append(dk); dHit.append(dh); mOK.append(mk); mHit.append(mh)
            }
        }
        res.stockDays = vals.count
        res.days = days.count
        guard vals.count >= 50 else {
            res.note = "Needs stored daily snapshots that are followed by Yahoo prices (at least a day for daily, 21 trading days for monthly). Now: \(vals.count) usable stock-days."
            return res
        }
        let W = (vals.count + 63) / 64
        func bits(_ f: (Int) -> Bool) -> [UInt64] {
            var b = [UInt64](repeating: 0, count: W)
            for k in vals.indices where f(k) { b[k >> 6] |= 1 << UInt64(k & 63) }
            return b
        }
        let DK = bits { dOK[$0] }, DH = bits { dHit[$0] }, MK = bits { mOK[$0] }, MH = bits { mHit[$0] }
        res.nDaily = CombiEngine.count(DK); res.nMonthly = CombiEngine.count(MK)
        res.baseDaily = res.nDaily > 0 ? Double(CombiEngine.count(DH)) / Double(res.nDaily) : 0
        res.baseMonthly = res.nMonthly > 0 ? Double(CombiEngine.count(MH)) / Double(res.nMonthly) : 0

        // 2. single conditions: column == value
        var singles: [(col: Int, ci: Int, value: Double, bits: [UInt64])] = []
        for (ci, c) in columns.enumerated() {
            var values = Set<Double>()
            for v in vals { if let x = v[ci] { values.insert(x) } }
            for v in values.sorted() {
                let b = bits { vals[$0][ci] == v }
                if CombiEngine.count(b) >= minN { singles.append((c, ci, v, b)) }
            }
        }
        func row(_ parts: [(Int, Double)], _ b: [UInt64]) -> ProbRow {
            let name = parts.map { "\(names[$0.0]) = \(CombiEngine.fmt($0.1))" }.joined(separator: " & ")
            return ProbRow(name: name, parts: parts.map { (col: $0.0, value: $0.1) }, size: parts.count, n: CombiEngine.count(b),
                           nDaily: CombiEngine.andCount(b, DK), hitDaily: CombiEngine.andCount(b, DH),
                           nMonthly: CombiEngine.andCount(b, MK), hitMonthly: CombiEngine.andCount(b, MH))
        }
        var out: [ProbRow] = singles.map { row([($0.col, $0.value)], $0.bits) }
        // 3. pairs and triples (different columns)
        if maxSize >= 2 {
            var budget = 400_000
            for a in singles.indices {
                for b in (a + 1)..<singles.count where singles[b].ci != singles[a].ci {
                    let ab = CombiEngine.andBits(singles[a].bits, singles[b].bits)
                    guard CombiEngine.count(ab) >= minN else { continue }
                    out.append(row([(singles[a].col, singles[a].value), (singles[b].col, singles[b].value)], ab))
                    guard maxSize >= 3, budget > 0 else { continue }
                    for c in (b + 1)..<singles.count where singles[c].ci != singles[a].ci && singles[c].ci != singles[b].ci {
                        budget -= 1
                        let abc = CombiEngine.andBits(ab, singles[c].bits)
                        guard CombiEngine.count(abc) >= minN else { continue }
                        out.append(row([(singles[a].col, singles[a].value), (singles[b].col, singles[b].value), (singles[c].col, singles[c].value)], abc))
                    }
                }
            }
        }
        // 4. how many stocks match each condition today
        for k in out.indices {
            out[k].today = current.rows.filter { r in out[k].parts.allSatisfy { r.number($0.col) == $0.value } }.count
        }
        res.rows = out
        return res
    }
}

@MainActor final class ProbCenter: ObservableObject {
    static let shared = ProbCenter()
    @Published var result: ProbResult?
    @Published var running = false
    @Published var status: String?

    func run(vm: ScreenerViewModel, dailyMin: Double, monthlyMin: Double, maxSize: Int, minN: Int, columns chosen: [String]) {
        guard !running else { return }
        guard let label = vm.labelIndex, vm.hasData else { status = "Import data first."; return }
        guard !vm.priceBook.series.isEmpty else { status = "Fetch Yahoo prices first (Daily Gainers) — outcomes come from them."; return }
        let current = vm.table
        let auto = ProbEngine.discreteColumns(current, skip: label)
        let cols = chosen.isEmpty ? auto : chosen.compactMap { current.index(of: $0) }
        guard !cols.isEmpty else { status = "No discrete columns (like count, Long_Green) found."; return }
        let stored = Array(HistoryStore.days().filter { $0 < HistoryStore.dayKey(vm.dataDay(of: current)) }.suffix(300))
        let book = vm.priceBook, names = current.headers
        running = true; status = "Reading \(stored.count) stored days…"
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> ProbResult in
                let days = stored.compactMap { d in HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) }.map { ProbEngine.Day(day: d, table: $0) } }
                return ProbEngine.run(days: days, label: label, columns: cols, names: names, book: book, current: current,
                                      dailyMin: dailyMin, monthlyMin: monthlyMin, maxSize: maxSize, minN: minN)
            }.value
            result = r; running = false; status = r.note.isEmpty ? nil : r.note
        }
    }
}

struct ProbabilityView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var pc = ProbCenter.shared
    @AppStorage("prob.daily") private var dailyMin = 5.0
    @AppStorage("prob.monthly") private var monthlyMin = 30.0
    @AppStorage("prob.size") private var maxSize = 2
    @AppStorage("prob.minN") private var minN = 30
    @AppStorage("prob.sort") private var sort = "Monthly %"
    @AppStorage("prob.show") private var show = "All"
    @AppStorage("prob.cols") private var colsRaw = ""
    @State private var search = ""
    @State private var showCols = false

    private var chosen: [String] { colsRaw.split(separator: "|").map(String.init) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let r = pc.result, !r.rows.isEmpty { results(r) } else {
                VStack(spacing: 8) {
                    Image(systemName: "percent").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Count & Probability").font(.title2.bold())
                    Text(pc.status ?? "For every value of your Filter's discrete columns (count = 5, Long_Green = 1 …) and their combinations: how often a stock-day was followed by a daily top gainer (next day ≥ \(CombiEngine.fmt(dailyMin))%) or a monthly top gainer (≥ \(CombiEngine.fmt(monthlyMin))% within 21 trading days). Press Calculate.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 620)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Count & Probability")
    }

    private var header: some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            HStack(spacing: 4) {
                Text("Daily top gainer: next day ≥").font(.caption)
                TextField("", value: $dailyMin, format: .number).frame(width: 40).multilineTextAlignment(.trailing)
                Text("%").font(.caption)
            }.fixedSize()
            HStack(spacing: 4) {
                Text("Monthly: ≥").font(.caption)
                TextField("", value: $monthlyMin, format: .number).frame(width: 40).multilineTextAlignment(.trailing)
                Text("% within 21 days").font(.caption)
            }.fixedSize()
            Picker("", selection: $maxSize) { Text("Single values").tag(1); Text("+ pairs").tag(2); Text("+ triples").tag(3) }
                .labelsHidden().fixedSize()
            HStack(spacing: 4) {
                Text("min").font(.caption)
                Picker("", selection: $minN) { ForEach([10, 30, 50, 100, 300], id: \.self) { Text("\($0) stock-days").tag($0) } }.labelsHidden().fixedSize()
            }.fixedSize()
            Button { showCols = true } label: { Label(chosen.isEmpty ? "Columns: auto" : "Columns: \(chosen.count)", systemImage: "rectangle.split.3x1") }
                .fixedSize()
                .popover(isPresented: $showCols, arrowEdge: .bottom) { columnsPicker }
            Button { pc.run(vm: vm, dailyMin: dailyMin, monthlyMin: monthlyMin, maxSize: maxSize, minN: minN, columns: chosen) } label: {
                Label(pc.running ? "Calculating…" : "Calculate", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent).disabled(pc.running).fixedSize()
            if pc.running { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var columnsPicker: some View {
        let auto = Set(ProbEngine.discreteColumns(vm.table, skip: vm.labelIndex).map { vm.headers[$0] })
        return VStack(alignment: .leading, spacing: 6) {
            Text("Columns to test").font(.headline)
            Text("None ticked = automatic: every column with 2–12 distinct values (counts, 0/1 flags).").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.headers, id: \.self) { h in
                        Toggle(h + (auto.contains(h) ? "  ·auto" : ""), isOn: Binding(get: { chosen.contains(h) }, set: { on in
                            var c = chosen; if on { c.append(h) } else { c.removeAll { $0 == h } }; colsRaw = c.joined(separator: "|")
                        })).toggleStyle(.checkbox)
                    }
                }
            }
            .frame(width: 280, height: 340)
            Button("Back to automatic") { colsRaw = "" }.controlSize(.small)
        }
        .padding(12)
    }

    private func pct(_ v: Double?) -> String { v.map { String(format: $0 < 0.1 ? "%.1f%%" : "%.0f%%", $0 * 100) } ?? "—" }

    private func lift(_ p: Double?, _ base: Double) -> String {
        guard let p, base > 0 else { return "—" }
        return String(format: "%.1f×", p / base)
    }

    private func range(_ k: Int, _ n: Int) -> String {
        guard n > 0 else { return "" }
        let lo = CombiEngine.wilsonLower(k, n), hi = 1 - CombiEngine.wilsonLower(n - k, n)
        return "\(pct(lo))–\(pct(hi))"
    }

    private func results(_ r: ProbResult) -> some View {
        var rows = r.rows
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { rows = rows.filter { $0.name.lowercased().contains(q) } }
        switch show {
        case "Singles": rows = rows.filter { $0.size == 1 }
        case "Combinations": rows = rows.filter { $0.size > 1 }
        case "Today": rows = rows.filter { $0.today > 0 }
        default: break
        }
        switch sort {
        case "Daily %": rows.sort { ($0.pDaily ?? 0) > ($1.pDaily ?? 0) }
        case "Stock-days": rows.sort { $0.n > $1.n }
        case "Name": rows.sort { $0.name < $1.name }
        default: rows.sort { ($0.pMonthly ?? 0) > ($1.pMonthly ?? 0) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 12, lineSpacing: 6) {
                Text("All stocks: daily top gainer \(pct(r.baseDaily)) · monthly \(pct(r.baseMonthly)) — from \(r.stockDays) stock-days on \(r.days) stored days")
                    .font(.callout.bold()).fixedSize()
                TextField("Find e.g. count = 5", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Picker("", selection: $show) { ForEach(["All", "Singles", "Combinations", "Today"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Sort", selection: $sort) { ForEach(["Monthly %", "Daily %", "Stock-days", "Name"], id: \.self) { Text($0).tag($0) } }.fixedSize()
                Button("Export CSV…") { export(rows, r) }.fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Table(rows) {
                TableColumn("Condition") { x in Text(x.name).bold(x.size == 1) }.width(min: 200, ideal: 320)
                TableColumn("Stock-days") { x in Text("\(x.n)").monospacedDigit() }.width(min: 60, ideal: 75)
                TableColumn("Daily top gainer") { x in
                    HStack(spacing: 6) {
                        Text(pct(x.pDaily)).monospacedDigit().bold()
                        Text("\(x.hitDaily)/\(x.nDaily)").font(.caption).foregroundStyle(.secondary)
                    }
                    .help("95% range: \(range(x.hitDaily, x.nDaily))")
                }.width(min: 110, ideal: 140)
                TableColumn("× all") { x in Text(lift(x.pDaily, r.baseDaily)).monospacedDigit().foregroundStyle((x.pDaily ?? 0) > r.baseDaily ? Color.green : Color.secondary) }.width(min: 45, ideal: 55)
                TableColumn("Monthly top gainer") { x in
                    HStack(spacing: 6) {
                        Text(pct(x.pMonthly)).monospacedDigit().bold()
                        Text("\(x.hitMonthly)/\(x.nMonthly)").font(.caption).foregroundStyle(.secondary)
                    }
                    .help("95% range: \(range(x.hitMonthly, x.nMonthly))")
                }.width(min: 110, ideal: 140)
                TableColumn("× all ") { x in Text(lift(x.pMonthly, r.baseMonthly)).monospacedDigit().foregroundStyle((x.pMonthly ?? 0) > r.baseMonthly ? Color.green : Color.secondary) }.width(min: 45, ideal: 55)
                TableColumn("95% range (monthly)") { x in Text(range(x.hitMonthly, x.nMonthly)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }.width(min: 90, ideal: 110)
                TableColumn("Today") { x in Text(x.today == 0 ? "—" : "\(x.today)").monospacedDigit() }.width(min: 40, ideal: 50)
            }
            Text("Probability = share of stock-days with this condition that were followed by a top gainer. “× all” compares it with every stock. Small samples swing a lot — check the 95% range (hover). Past frequencies, not promises.")
                .font(.caption2).foregroundStyle(.secondary).padding(8)
        }
    }

    private func export(_ rows: [ProbRow], _ r: ProbResult) {
        let p = NSSavePanel(); p.nameFieldStringValue = "count-probability.csv"; p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        var s = "condition,stock_days,daily_hits,daily_n,daily_p,monthly_hits,monthly_n,monthly_p,today\n"
        for x in rows {
            s += "\"\(x.name)\",\(x.n),\(x.hitDaily),\(x.nDaily),\(x.pDaily.map { String(format: "%.4f", $0) } ?? ""),\(x.hitMonthly),\(x.nMonthly),\(x.pMonthly.map { String(format: "%.4f", $0) } ?? ""),\(x.today)\n"
        }
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}

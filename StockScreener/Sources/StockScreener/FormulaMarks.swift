import SwiftUI

/// "F" marks on the delivery charts: the days one or two of your stored formulas (My formulas, note formulas,
/// F alerts, F combinations, Filter conditions) were true for the stock on the chart.
/// Judged on the sheet snapshots the app keeps (History), so marks only go back as far as those snapshots.
@MainActor final class FormulaMarks: ObservableObject {
    static let shared = FormulaMarks()

    @Published private(set) var revision = 0
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var coverage = ""          // "120 days · 2026-05-02 → today"

    var f1: String { UserDefaults.standard.string(forKey: "fmarks.f1") ?? "" }
    var f2: String { UserDefaults.standard.string(forKey: "fmarks.f2") ?? "" }
    var freshAll: Bool { UserDefaults.standard.bool(forKey: "fmarks.fresh") }
    /// All stored formulas are matched automatically (default); off = only the one or two you pick.
    var auto: Bool { UserDefaults.standard.object(forKey: "fmarks.auto") as? Bool ?? true }
    /// Formula keys of the last run, by formula number.
    private(set) var active: [String] = []

    /// formula key → day → symbols true that day (after the "just became true" rule when chosen)
    private var hits: [String: [String: Set<String>]] = [:]
    private var names: [String: String] = [:]
    private var labels: [String: String] = [:]
    func label(_ key: String) -> String { labels[key] ?? "F" }
    private var signature = ""
    private var task: Task<Void, Never>?
    weak var vm: ScreenerViewModel?

    /// Computes the marks if the chosen formulas or the stored days changed. Cheap to call often.
    func ensure(_ vm: ScreenerViewModel, force: Bool = false) {
        self.vm = vm
        let fs: [FFormula]
        if auto {
            fs = FormulaDaysCenter.shared.formulas(vm).sorted { $0.num < $1.num }
        } else {
            let all = FormulaDaysCenter.shared.formulas(vm, includeHidden: true)
            fs = [f1, f2].filter { !$0.isEmpty }.compactMap { k in all.first { $0.key == k } }
        }
        let chosen = fs.map(\.key)
        guard !chosen.isEmpty else { if !hits.isEmpty { hits = [:]; active = []; revision += 1 }; signature = ""; return }
        let liveKey = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        let stored = HistoryStore.days().filter { $0 < liveKey }
        let sig = chosen.joined(separator: "|") + "#\(freshAll)#\(stored.count)#\(stored.last ?? "")#\(liveKey)#\(vm.table.rows.count)"
        guard force || sig != signature else { return }
        signature = sig
        task?.cancel()
        guard let label = vm.labelIndex, !fs.isEmpty else { hits = [:]; revision += 1; return }
        let days = stored + [liveKey]
        let fresh = freshAll
        running = true
        task = Task { @MainActor in
            var out: [String: [String: Set<String>]] = [:]
            let current = vm.table
            for (k, d) in days.enumerated() {
                if Task.isCancelled { return }
                progress = "\(k + 1)/\(days.count) days"
                let isLive = k == days.count - 1
                var table: SheetTable? = isLive ? current : await Task.detached(priority: .utility) {
                    HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) }
                }.value
                if !isLive, let tt = table {
                    let del = tt.headers.filter { ScreenerViewModel.isDeliveryColumn($0) }
                    if fs.contains(where: { f in del.contains { f.key.contains($0) } }) { table = vm.withDeliveryValues(tt, asOf: d) }
                }
                guard let t = table else { continue }
                for f in fs {
                    if let syms = FormulaDaysCenter.evaluate(f, table: t, label: label) { out[f.key, default: [:]][d] = Set(syms) }
                }
                if k % 10 == 0 { await Task.yield() }
            }
            // "only when it just became true": drop a stock on a day it was already true the stored day before
            for f in fs where fresh || f.fresh {
                guard let m = out[f.key] else { continue }
                var n: [String: Set<String>] = [:]
                for (k, d) in days.enumerated() where k > 0 {
                    guard let cur = m[d], let prev = m[days[k - 1]] else { continue }
                    n[d] = cur.subtracting(prev)
                }
                out[f.key] = n
            }
            hits = out
            active = fs.map(\.key)
            names = Dictionary(fs.map { ($0.key, $0.titled) }, uniquingKeysWith: { a, _ in a })
            labels = Dictionary(fs.map { ($0.key, $0.label) }, uniquingKeysWith: { a, _ in a })
            coverage = days.count > 1 ? "\(days.count) days · from \(days.first!)" : "only today (no stored days yet)"
            running = false; progress = ""
            revision += 1
            MemoryRelief.giveBack()
        }
    }

    func name(_ key: String) -> String { names[key] ?? key }

    /// The other stocks the formula(s) true for `symbol` on `day` were also true for.
    func others(_ symbol: String, _ day: String) -> (title: String, symbols: [String]) {
        let sym = symbol.uppercased()
        var set = Set<String>(), which: [String] = []
        for k in active {
            guard let s = hits[k]?[day], s.contains(sym) else { continue }
            set.formUnion(s); which.append(name(k))
        }
        set.remove(sym)
        return (which.joined(separator: " · "), set.sorted())
    }

    /// One marker per day above the candle: every formula true that day with how many other stocks it was true for — "1F11 3F4".
    func markers(_ symbol: String, from: String = "") -> [LWChartData.Marker] {
        let sym = symbol.uppercased()
        var byDay: [String: [String]] = [:]          // day → formula keys true for this stock
        for k in active {
            for (day, s) in hits[k] ?? [:] where day >= from && s.contains(sym) { byDay[day, default: []].append(k) }
        }
        var out: [LWChartData.Marker] = []
        for day in byDay.keys.sorted() {
            let ks = active.filter { byDay[day]!.contains($0) }
            let parts = ks.map { k -> String in let n = (hits[k]?[day]?.count ?? 1) - 1; return label(k) + (n > 0 ? "\(n)" : "") }
            let text = parts.prefix(4).joined(separator: " ") + (parts.count > 4 ? " +\(parts.count - 4)" : "")
            let color = ks.count > 1 ? "#FFD600" : "#E040FB"
            let info = ks.map { k in let n = (hits[k]?[day]?.count ?? 1) - 1; return name(k) + " (\(n) other\(n == 1 ? "" : "s"))" }.joined(separator: "  ·  ")
                + " — click to see the other stocks"
            out.append(LWChartData.Marker(time: day, text: text, position: "aboveBar", color: color, shape: "arrowDown", info: info, id: "fm|" + day))
        }
        return out
    }
}

/// The F-marks menu in the delivery chart's header: pick one or two stored formulas.
struct FormulaMarkControl: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var fm = FormulaMarks.shared
    @AppStorage("fmarks.f1") private var f1 = ""
    @AppStorage("fmarks.f2") private var f2 = ""
    @AppStorage("fmarks.fresh") private var fresh = false
    @AppStorage("fmarks.auto") private var auto = true

    var body: some View {
        let fs = FormulaDaysCenter.shared.formulas(vm, includeHidden: true)
        Menu {
            Toggle("Match all my formulas automatically", isOn: $auto)
            Divider()
            Picker("Or just this formula", selection: $f1) {
                Text("None").tag("")
                ForEach(fs) { f in Text(short(f.titled) + "  — " + String(f.source.prefix(30))).tag(f.key) }
            }
            Picker("…and this one", selection: $f2) {
                Text("None").tag("")
                ForEach(fs) { f in Text(short(f.titled) + "  — " + String(f.source.prefix(30))).tag(f.key) }
            }
            Toggle("Only when it just became true", isOn: $fresh)
            Divider()
            Text(fm.running ? "Working… \(fm.progress)" : (fm.coverage.isEmpty ? "Nothing matched yet" : "Judged on \(fm.coverage)"))
            Button("Recalculate") { fm.ensure(vm, force: true) }
        } label: {
            HStack(spacing: 3) {
                if fm.running { ProgressView().controlSize(.mini) }
                Text(label).font(.caption2).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("F marks: on each day, every formula that was true for this stock — 1F11 = formula 1, true for 11 other stocks that day (click to see them in Quick). Gold when more than one formula was true. Matches all your formulas automatically, or just one or two you pick. Judged on the sheet snapshots the app has stored, so marks only go back as far as those days.")
        .onAppear { fm.ensure(vm) }
        .onChange(of: f1) { v in if !v.isEmpty && auto { auto = false } else { fm.ensure(vm) } }
        .onChange(of: f2) { v in if !v.isEmpty && auto { auto = false } else { fm.ensure(vm) } }
        .onChange(of: fresh) { _ in fm.ensure(vm, force: true) }
        .onChange(of: auto) { _ in fm.ensure(vm, force: true) }
    }

    private var label: String {
        if auto { return "all formulas" }
        let n = [f1, f2].filter { !$0.isEmpty }.count
        return n == 0 ? "pick formula" : (n == 1 ? short(fm.name(f1.isEmpty ? f2 : f1), 22) : fm.label(f1) + " · " + fm.label(f2))
    }
    private func short(_ s: String, _ n: Int = 48) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
}

/// Permanent formula numbers: 1F, 2F, … given once and kept (shown in Formula counts, F marks, Quick, Lead-time).
enum FormulaNumbers {
    private static let key = "fnum.map"
    private static var map: [String: Int] = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    static func number(_ identity: String) -> Int {
        if let n = map[identity] { return n }
        let n = (map.values.max() ?? 0) + 1
        map[identity] = n
        UserDefaults.standard.set(map, forKey: key)
        return n
    }
}

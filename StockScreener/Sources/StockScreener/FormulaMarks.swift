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

    /// formula key → day → symbols true that day (after the "just became true" rule when chosen)
    private var hits: [String: [String: Set<String>]] = [:]
    private var names: [String: String] = [:]
    private var signature = ""
    private var task: Task<Void, Never>?
    weak var vm: ScreenerViewModel?

    /// Computes the marks if the chosen formulas or the stored days changed. Cheap to call often.
    func ensure(_ vm: ScreenerViewModel, force: Bool = false) {
        self.vm = vm
        let chosen = [f1, f2].filter { !$0.isEmpty }
        guard !chosen.isEmpty else { if !hits.isEmpty { hits = [:]; revision += 1 }; signature = ""; return }
        let all = FormulaDaysCenter.shared.formulas(vm, includeHidden: true)
        let fs = chosen.compactMap { k in all.first { $0.key == k } }
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
            names = Dictionary(fs.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
            coverage = days.count > 1 ? "\(days.count) days · from \(days.first!)" : "only today (no stored days yet)"
            running = false; progress = ""
            revision += 1
            MemoryRelief.giveBack()
        }
    }

    func name(_ key: String) -> String { names[key] ?? key }

    /// Markers for one stock: F (one formula) or F1 / F2 / F1+2 above the candle.
    func markers(_ symbol: String, from: String = "") -> [LWChartData.Marker] {
        let sym = symbol.uppercased()
        let k1 = f1, k2 = f2
        let two = !k1.isEmpty && !k2.isEmpty
        let d1 = Set((hits[k1] ?? [:]).filter { $0.value.contains(sym) }.keys)
        let d2 = Set((hits[k2] ?? [:]).filter { $0.value.contains(sym) }.keys)
        var out: [LWChartData.Marker] = []
        for day in d1.union(d2).sorted() where day >= from {
            let a = d1.contains(day), b = d2.contains(day)
            let text = !two ? "F" : (a && b ? "F1+2" : (a ? "F1" : "F2"))
            let color = a && b ? "#FFD600" : (a ? "#E040FB" : "#00B8D4")
            let info = [a ? "F1 · \(name(k1))" : nil, b ? "F2 · \(name(k2))" : nil].compactMap { $0 }.joined(separator: "  ·  ")
            out.append(LWChartData.Marker(time: day, text: text, position: "aboveBar", color: color, shape: "arrowDown", info: info))
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

    var body: some View {
        let fs = FormulaDaysCenter.shared.formulas(vm, includeHidden: true)
        Menu {
            Picker("Formula 1 (F1)", selection: $f1) {
                Text("None").tag("")
                ForEach(fs) { f in Text(short(f.name) + "  — " + String(f.source.prefix(30))).tag(f.key) }
            }
            Picker("Formula 2 (F2)", selection: $f2) {
                Text("None").tag("")
                ForEach(fs) { f in Text(short(f.name) + "  — " + String(f.source.prefix(30))).tag(f.key) }
            }
            Toggle("Only when it just became true", isOn: $fresh)
            Divider()
            Text(fm.running ? "Working… \(fm.progress)" : (fm.coverage.isEmpty ? "Pick a formula" : "Judged on \(fm.coverage)"))
            Button("Recalculate") { fm.ensure(vm, force: true) }
        } label: {
            HStack(spacing: 3) {
                if fm.running { ProgressView().controlSize(.mini) }
                Text(label).font(.caption2).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("F marks: days the chosen formula(s) were true for this stock. One formula → F; two → F1 (pink), F2 (cyan), F1+2 (gold). Judged on the sheet snapshots the app has stored, so marks only go back as far as those days.")
        .onAppear { fm.ensure(vm) }
        .onChange(of: f1) { _ in fm.ensure(vm) }
        .onChange(of: f2) { _ in fm.ensure(vm) }
        .onChange(of: fresh) { _ in fm.ensure(vm, force: true) }
    }

    private var label: String {
        let n = [f1, f2].filter { !$0.isEmpty }.count
        return n == 0 ? "pick formula" : (n == 1 ? short(fm.name(f1.isEmpty ? f2 : f1), 18) : "F1 · F2")
    }
    private func short(_ s: String, _ n: Int = 48) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
}

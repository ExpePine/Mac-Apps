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

    /// Formulas you ticked (by their permanent identity), used when "all" is off.
    var picked: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "fmarks.picked") ?? []) }
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
            let p = picked
            fs = FormulaDaysCenter.shared.formulas(vm, includeHidden: true).filter { p.contains($0.identity) }.sorted { $0.num < $1.num }
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

/// The Formula-marks button in the delivery chart's header: all formulas, or tick the ones to match.
struct FormulaMarkControl: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var fm = FormulaMarks.shared
    @AppStorage("fmarks.fresh") private var fresh = false
    @AppStorage("fmarks.auto") private var auto = true
    @State private var picked: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "fmarks.picked") ?? [])
    @State private var open = false
    @State private var search = ""

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                if fm.running { ProgressView().controlSize(.mini) }
                Text(label).font(.caption2).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
        }
        .buttonStyle(.borderless).fixedSize()
        .help("Formula marks: on each day, every chosen formula that was true for this stock — 1F11 = formula 1, true for 11 other stocks that day (click the mark to see them in Quick). Gold when more than one formula was true. Judged on the sheet snapshots the app has stored, so marks only go back as far as those days.")
        .popover(isPresented: $open, arrowEdge: .bottom) { panel }
        .onAppear { fm.ensure(vm) }
        .onChange(of: fresh) { _ in fm.ensure(vm, force: true) }
        .onChange(of: auto) { _ in fm.ensure(vm, force: true) }
        .onChange(of: picked) { p in UserDefaults.standard.set(Array(p), forKey: "fmarks.picked"); fm.ensure(vm, force: true) }
    }

    private var panel: some View {
        let fs = FormulaDaysCenter.shared.formulas(vm, includeHidden: true).sorted { $0.num < $1.num }
        let q = search.lowercased()
        let shown = q.isEmpty ? fs : fs.filter { $0.titled.lowercased().contains(q) || $0.source.lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Formulas to match").font(.headline)
            Picker("", selection: $auto) {
                Text("All my formulas").tag(true)
                Text("Only the ones I tick").tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if !auto {
                HStack {
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                    Button("All") { picked.formUnion(shown.map(\.identity)) }
                    Button("None") { picked.subtract(shown.map(\.identity)) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shown) { f in
                            Toggle(isOn: Binding(get: { picked.contains(f.identity) },
                                                 set: { on in if on { picked.insert(f.identity) } else { picked.remove(f.identity) } })) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(f.titled).font(.caption.monospaced()).lineLimit(1)
                                    Text(f.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(360, CGFloat(max(1, shown.count)) * 34))
                Text("\(picked.intersection(fs.map(\.identity)).count) of \(fs.count) ticked").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Only when it just became true", isOn: $fresh).toggleStyle(.checkbox)
            HStack {
                Text(fm.running ? "Working… \(fm.progress)" : (fm.coverage.isEmpty ? "Nothing matched yet" : "Judged on \(fm.coverage)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Recalculate") { fm.ensure(vm, force: true) }
            }
        }
        .padding(12)
        .frame(width: 460)
    }

    private var label: String {
        if auto { return "all formulas" }
        let n = picked.count
        return n == 0 ? "tick formulas" : "\(n) formula\(n == 1 ? "" : "s")"
    }
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

import SwiftUI
import Combine
import AppKit

/// Formula marks on the delivery charts: the days your stored formulas (My formulas, note formulas, F alerts,
/// F combinations, Filter conditions) were true for the stock on the chart.
/// Uses Formula counts' results (same days, same "Also require"), so it costs nothing extra once those are counted.
@MainActor final class FormulaMarks: ObservableObject {
    static let shared = FormulaMarks()

    @Published private(set) var revision = 0
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var coverage = ""
    /// The stock on the delivery chart (the floating Formulas window follows it).
    @Published var chartSymbol = ""

    /// Formulas you ticked (by their permanent identity), used when "all" is off.
    var picked: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "fmarks.picked") ?? []) }
    var freshAll: Bool { UserDefaults.standard.bool(forKey: "fmarks.fresh") }
    /// All stored formulas are matched automatically (default); off = only the ones you tick.
    var auto: Bool { UserDefaults.standard.object(forKey: "fmarks.auto") as? Bool ?? true }
    /// Formula keys shown, by formula number.
    private(set) var active: [String] = []

    /// formula key → day → symbols true that day
    private var hits: [String: [String: Set<String>]] = [:]
    private var names: [String: String] = [:]
    private var labels: [String: String] = [:]
    func label(_ key: String) -> String { labels[key] ?? "F" }
    private var wanted: [FFormula] = []
    /// Trace-back for the stock on the chart: formula key → (first counted day of a run → the day the run really began).
    private var traced: [String: [String: String]] = [:]
    private var tracedSymbol = ""
    private var traceTask: Task<Void, Never>?
    @Published private(set) var tracing = false
    /// Marks go on the day each run began (gaps up to `runGap` days don't end a run), traced back day by day.
    static var originMode: Bool { UserDefaults.standard.object(forKey: "fmarks.origin") as? Bool ?? true }
    static var runGap: Int { UserDefaults.standard.object(forKey: "fmarks.gap") as? Int ?? 2 }
    private var bag = Set<AnyCancellable>()
    weak var vm: ScreenerViewModel?

    private init() {
        let fc = FormulaDaysCenter.shared
        fc.$running.removeDuplicates().sink { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                self.running = r
                if !r { self.rebuild() }
            }
        }.store(in: &bag)
        fc.$progress.sink { [weak self] p in
            Task { @MainActor in self?.progress = fc.running ? "Formula counts \(Int(p * 100))%" : "" }
        }.store(in: &bag)
    }

    /// Full formula mode: judge formulas on every stored day (all the candles the chart shows that have a stored sheet),
    /// not just Formula counts' Days.
    static var full: Bool { UserDefaults.standard.bool(forKey: "fmarks.full") }
    /// Days Formula counts should count: its Days setting, or every stored day in Full mode.
    static var countDays: Int {
        let n = UserDefaults.standard.object(forKey: "fdays.last") as? Int ?? 60
        return full ? max(n, HistoryStore.days().count, DeliveryCenter.shared.book.days.count) : n
    }

    /// Picks the formulas to show; asks Formula counts to count if it hasn't counted them yet.
    func ensure(_ vm: ScreenerViewModel, force: Bool = false) {
        self.vm = vm
        let fc = FormulaDaysCenter.shared
        if auto {
            wanted = fc.formulas(vm).sorted { $0.num < $1.num }
        } else {
            let p = picked
            wanted = fc.formulas(vm, includeHidden: true).filter { p.contains($0.identity) }.sorted { $0.num < $1.num }
        }
        let missing = wanted.contains { fc.counts[$0.key] == nil }
        // Full mode: every stored day must be counted (Formula counts' window is widened to all of them)
        let short = fc.days.count < min(Self.countDays, max(HistoryStore.days().count, DeliveryCenter.shared.book.days.count)) && Self.full
        if (force || missing || short || fc.days.isEmpty) && !fc.running && !wanted.isEmpty {
            let n = FormulaMarks.countDays
            fc.run(vm, lastDays: max(1, n))
        }
        rebuild()
    }

    /// Reads Formula counts' results for the wanted formulas.
    func rebuild() {
        let fc = FormulaDaysCenter.shared
        let days = fc.days
        var out: [String: [String: Set<String>]] = [:]
        for f in wanted {
            guard let m = fc.counts[f.key] else { continue }
            var per: [String: Set<String>] = [:]
            for (d, v) in m { if let v { per[d] = Set(v) } }
            // "only when it just became true" for every formula (a formula's own tick is already applied by Formula counts)
            if (freshAll || Self.originMode) && !f.fresh {
                let all = Array(Set(m.keys)).sorted()
                let starts = Self.originMode
                    ? FormulaDaysCenter.runStarts(m, days: all, mode: 1, gap: Self.runGap)
                    : FormulaDaysCenter.runStarts(m, days: all, mode: FormulaDaysCenter.freshMode, gap: FormulaDaysCenter.freshGap)
                per = [:]
                for (d, v) in starts { if let v, !v.isEmpty { per[d] = Set(v) } }
            }
            out[f.key] = per
        }
        hits = out
        active = wanted.map(\.key).filter { out[$0] != nil }
        names = Dictionary(wanted.map { ($0.key, $0.titled) }, uniquingKeysWith: { a, _ in a })
        labels = Dictionary(wanted.map { ($0.key, $0.label) }, uniquingKeysWith: { a, _ in a })
        coverage = days.isEmpty ? "" : "Formula counts' \(days.count) days · from \(days.first!)"
        traced = [:]; tracedSymbol = ""
        revision += 1
        if Self.originMode, !chartSymbol.isEmpty { trace(chartSymbol) }
    }

    // Traced starts never change for past days: kept (memory + disk) so a chart shows them instantly next time.
    private static var traceURL: URL { AppFolders.base.appendingPathComponent("formula_trace_cache.json") }
    static var traceCache: [String: String] = {
        guard let d = try? Data(contentsOf: traceURL), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }()
    static var traceDirty = false
    static func saveTrace() {
        guard traceDirty else { return }
        traceDirty = false
        if traceCache.count > 50_000 { traceCache = [:] }
        let snap = traceCache, url = traceURL
        Task.detached(priority: .background) { if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) } }
    }

    /// Walks each of this stock's runs back, one NSE trading day at a time (not only the days with a stored sheet),
    /// while the formula keeps being true — gaps of up to `runGap` days allowed — and moves the mark to that first day.
    /// Delivery columns are recomputed for each earlier day; other columns come from the nearest stored sheet on or
    /// before that day (or the run's first counted day when there is none).
    func trace(_ symbol: String) {
        let sym = symbol.uppercased()
        guard let vm, let label = vm.labelIndex, !sym.isEmpty else { return }
        traceTask?.cancel()
        let fs = wanted.filter { active.contains($0.key) }
        // (key shown, formula as Formula counts judges it — with "Also require", counted day)
        let starts: [(String, FFormula, String)] = fs.flatMap { f in
            (hits[f.key] ?? [:]).filter { $0.value.contains(sym) }.keys.map { (f.key, FormulaDaysCenter.shared.effective(f), $0) }
        }
        guard !starts.isEmpty else { return }
        let dc = DeliveryCenter.shared
        let cal = (dc.calendar.isEmpty ? dc.book.days : dc.calendar)
        let storedDays = Set(HistoryStore.days())
        let current = vm.table
        tracing = true
        traceTask = Task { @MainActor in
            var sheets: [String: SheetTable] = [:]      // day → this stock's one-row sheet
            func row(on d: String) async -> SheetTable? {
                if let t = sheets[d] { return t }
                let t: SheetTable? = await Task.detached(priority: .utility) {
                    HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) }
                }.value
                guard let t else { return nil }
                let one = SheetTable(headers: t.headers, rows: t.rows.filter { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() == sym }, originalHeaders: t.originalHeaders)
                sheets[d] = one
                return one
            }
            var out: [String: [String: String]] = [:]
            for (key, f, d0) in starts {
                let ck = "\(sym)|\(key)|\(d0)|\(Self.runGap)"
                if let o = Self.traceCache[ck] { if !o.isEmpty { out[key, default: [:]][d0] = o }; continue }
                if Task.isCancelled { return }
                guard var k = cal.firstIndex(of: d0) ?? cal.lastIndex(where: { $0 < d0 }).map({ $0 + 1 }) else { continue }
                guard let base0 = await row(on: d0), !base0.rows.isEmpty else { continue }
                var base = base0, origin = d0, misses = 0, steps = 0
                while k > 0 && misses <= Self.runGap && steps < 250 {
                    k -= 1; steps += 1
                    let d = cal[k]
                    if storedDays.contains(d), let r = await row(on: d), !r.rows.isEmpty { base = r }
                    let t = vm.withDeliveryValues(base, asOf: d)
                    let ok = FormulaDaysCenter.evaluate(f, table: t, label: label)?.isEmpty == false
                    if ok { origin = d; misses = 0 } else { misses += 1 }
                    if steps % 20 == 0 { await Task.yield() }
                }
                if origin != d0 { out[key, default: [:]][d0] = origin }
                Self.traceCache[ck] = origin != d0 ? origin : ""
                Self.traceDirty = true
            }
            traced = out; tracedSymbol = sym
            Self.saveTrace()
            tracing = false
            revision += 1
        }
    }

    func name(_ key: String) -> String { names[key] ?? key }

    /// Days (newest first) a formula was true for a stock, in the counted days.
    func days(_ key: String, _ symbol: String) -> [String] {
        let sym = symbol.uppercased()
        return (hits[key] ?? [:]).filter { $0.value.contains(sym) }.keys.sorted(by: >)
    }

    /// The other stocks the formula(s) true for `symbol` on `day` were also true for.
    func others(_ symbol: String, _ day0: String) -> (title: String, symbols: [String]) {
        let sym = symbol.uppercased()
        let day = countedDay(sym, day0)
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
        let tr = sym == tracedSymbol ? traced : [:]
        // shown day → [(formula key, counted day)]
        var byDay: [String: [(String, String)]] = [:]
        for k in active {
            for (day, s) in hits[k] ?? [:] where s.contains(sym) {
                let shown = tr[k]?[day] ?? day
                if shown >= from { byDay[shown, default: []].append((k, day)) }
            }
        }
        var out: [LWChartData.Marker] = []
        for day in byDay.keys.sorted() {
            let items = byDay[day]!.sorted { (active.firstIndex(of: $0.0) ?? 0) < (active.firstIndex(of: $1.0) ?? 0) }
            let parts = items.map { (k, d0) -> String in let n = (hits[k]?[d0]?.count ?? 1) - 1; return label(k) + (n > 0 ? " \(n)" : "") }
            let text = parts.prefix(3).joined(separator: " · ") + (parts.count > 3 ? " +\(parts.count - 3)" : "")
            let color = items.count > 1 ? "#FFC400" : "#E040FB"
            let info = items.map { (k, d0) -> String in
                let n = (hits[k]?[d0]?.count ?? 1) - 1
                return name(k) + " (\(n) other\(n == 1 ? "" : "s") on \(d0))" + (d0 != day ? " — traced back: true since \(day)" : "")
            }.joined(separator: "  ·  ") + " — click to see the other stocks"
            out.append(LWChartData.Marker(time: day, text: text, position: "aboveBar", color: color, shape: "arrowDown", info: info, id: "fpill"))
        }
        return out
    }

    /// A clicked badge's day may be a traced-back day: the counted day it stands for.
    func countedDay(_ symbol: String, _ day: String) -> String {
        guard symbol.uppercased() == tracedSymbol else { return day }
        for (_, m) in traced { if let d0 = m.first(where: { $0.value == day })?.key { return d0 } }
        return day
    }
}

/// The Formula-marks button in the delivery chart's header: all formulas, or tick the ones to match.
struct FormulaMarkControl: View {
    var symbol: String = ""
    @EnvironmentObject var vm: ScreenerViewModel
    @State private var workbench = false
    @ObservedObject private var fm = FormulaMarks.shared
    @AppStorage("fmarks.fresh") private var fresh = false
    @AppStorage("fmarks.auto") private var auto = true
    @AppStorage("fmarks.full") private var full = false
    @AppStorage("fmarks.origin") private var origin = true
    @AppStorage("fmarks.gap") private var gap = 2
    @State private var picked: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "fmarks.picked") ?? [])
    @State private var open = false
    @State private var search = ""

    var body: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $full) { Text("Full").font(.caption2.bold()) }
                .toggleStyle(.button)
                .help("Full formula mode: every selected formula on every day the app has a stored sheet for — all the way back on this chart, not just Formula counts' last \(UserDefaults.standard.object(forKey: "fdays.last") as? Int ?? 60) days. Turning it on widens Formula counts to the same days.")
                .onChange(of: full) { _ in fm.ensure(vm, force: true) }
            menuButton
            Button { fm.chartSymbol = symbol; FormulaWorkbenchPanel.shared.show(vm) } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("Formulas in a floating window: keep it open over the chart while you change or add formulas — the marks update on this chart")

        }
        .fixedSize()
    }

    private var menuButton: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                if fm.running || fm.tracing { ProgressView().controlSize(.mini) }
                Text(label).font(.caption2).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
        }
        .buttonStyle(.borderless).fixedSize()
        .help("Formula marks: on each day, every chosen formula that was true for this stock — 1F11 = formula 1, true for 11 other stocks that day (click the mark to see them in Quick). Gold when more than one formula was true. Uses Formula counts' results: the same days (its Days setting) and its \"Also require\".")
        .popover(isPresented: $open, arrowEdge: .bottom) { panel }
        .onAppear { if !symbol.isEmpty { fm.chartSymbol = symbol }; fm.ensure(vm) }
        .onChange(of: symbol) { s in if !s.isEmpty { fm.chartSymbol = s; fm.trace(s) } }
        .onChange(of: fresh) { _ in fm.ensure(vm, force: true) }
        .onChange(of: auto) { _ in fm.ensure(vm, force: true) }
        .onChange(of: origin) { _ in fm.rebuild() }
        .onChange(of: gap) { _ in fm.rebuild() }
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
            FreshModePicker { fm.ensure(vm, force: true) }
            Divider()
            Toggle("Mark where each run began (traced back day by day)", isOn: $origin).toggleStyle(.checkbox)
                .help("A formula true for days 1–10 gets one mark, on day 1 — walked back on every NSE trading day, not just days with a stored sheet")
            if origin {
                Stepper("Gaps of up to \(gap) day\(gap == 1 ? "" : "s") don't end a run", value: $gap, in: 0...10).font(.caption)
            }
            HStack {
                Text(fm.running ? "Counting… \(fm.progress)" : (fm.coverage.isEmpty ? "Nothing counted yet" : "Uses \(fm.coverage) (set Days in Formula counts)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Recalculate") { fm.ensure(vm, force: true) }
                Button("From scratch") {
                    FormulaDaysCenter.shared.clearCache()
                    FormulaMarks.traceCache = [:]; FormulaMarks.traceDirty = true; FormulaMarks.saveTrace()
                    fm.ensure(vm, force: true)
                }
                .help("Past days' results are kept so marks show at once. Use this after re-downloading NSE delivery history, to judge every day again.")
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

/// Edit formulas without leaving the chart: every formula with its number, whether it's true for this stock
/// (today / last time), Edit or New — saving recounts and the chart's marks update.
struct FormulaWorkbench: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = FormulaDaysCenter.shared
    @ObservedObject private var fm = FormulaMarks.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: FFormula?
    @State private var adding = false
    @State private var search = ""
    private var symbol: String { fm.chartSymbol }

    var body: some View {
        let fs = c.formulas(vm, includeHidden: true).sorted { $0.num < $1.num }
        let q = search.lowercased()
        let shown = q.isEmpty ? fs : fs.filter { $0.titled.lowercased().contains(q) || ($0.quick ?? "").lowercased().contains(q) }
        let today = c.days.last ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Formulas" + (symbol.isEmpty ? "" : " · \(symbol.uppercased())")).font(.headline)
                if c.running { ProgressView().controlSize(.small); Text("recounting \(Int(c.progress * 100))%").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Button { editing = nil; adding = true } label: { Label("New formula", systemImage: "plus") }
                Button("Close") { FormulaWorkbenchPanel.shared.close() }
            }
            if adding || editing != nil {
                FormulaEditor(start: editing, saved: { recount() }, onClose: { editing = nil; adding = false })
                    .id(editing?.key ?? "new")
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            List(shown) { f in
                let ds = symbol.isEmpty ? [] : fm.days(f.key, symbol)
                HStack(spacing: 8) {
                    Circle().fill(ds.first == today && !today.isEmpty ? Color.green : (ds.isEmpty ? Color.secondary.opacity(0.3) : Color.orange))
                        .frame(width: 8, height: 8)
                        .help(ds.first == today ? "True for \(symbol) today" : (ds.first.map { "Last true for \(symbol) on \($0)" } ?? "Not true for \(symbol) in the counted days"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.titled).font(.callout.monospaced()).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(f.source).lineLimit(1)
                            if !ds.isEmpty { Text("· true \(ds.count)× for \(symbol.uppercased()), last \(ds.first!)") }
                            if let n = c.counts[f.key]?[today], let n { Text("· \(n.count) stocks today") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { adding = false; editing = f }
                }
            }
            Text("Saving recounts Formula counts; the marks on the chart update when it finishes. Edited note / Filter formulas are saved as new My formulas.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 600, minHeight: 360)
    }

    private func recount() {
        let n = FormulaMarks.countDays
        c.run(vm, lastDays: max(1, n))
        fm.ensure(vm)
    }
}

/// The Formulas window floats above the charts (stays on top, doesn't hide when you click the chart).
@MainActor final class FormulaWorkbenchPanel {
    static let shared = FormulaWorkbenchPanel()
    private var panel: NSPanel?

    func show(_ vm: ScreenerViewModel) {
        if panel == nil {
            let host = NSHostingController(rootView: FormulaWorkbench().environmentObject(vm))
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            p.title = "Formulas"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.isReleasedWhenClosed = false
            p.contentViewController = host
            p.setContentSize(NSSize(width: 720, height: 520))
            p.setFrameAutosaveName("FormulaWorkbenchPanel")
            if !p.setFrameUsingName("FormulaWorkbenchPanel"), let s = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: s.maxX - 740, y: s.maxY - 40))
            }
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }
}

/// What "just became true" means — shared by Formula counts and the Formula marks.
struct FreshModePicker: View {
    var changed: () -> Void = {}
    @EnvironmentObject var vm: ScreenerViewModel
    @AppStorage("fresh.mode") private var mode = 0
    @AppStorage("fresh.gap") private var gap = 5
    @AppStorage("fdir.forward") private var forward = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Direction")
                LookDirectionPicker { recount() }
                if forward { Text("from \(FormulaMarks.countDays) days ago").foregroundStyle(.secondary) }
            }
            Picker("\"Just became true\" =", selection: $mode) {
                Text("true that day, not the day before").tag(0)
                Text("the original first day of the run").tag(1)
            }
            .help("The first: a stock that drops out for a day and comes back is marked again (often late in a rise). The second walks back while the condition kept being true and marks the day it originally became true.")
            .disabled(forward)
            if mode == 1 {
                Stepper("A run survives gaps of up to \(gap) day\(gap == 1 ? "" : "s")", value: $gap, in: 0...30)
                    .help("Days the condition may be false in between and still count as the same run")
            }
        }
        .font(.caption)
        .onChange(of: mode) { _ in recount() }
        .onChange(of: gap) { _ in recount() }
    }

    private func recount() {
        changed()
        let n = FormulaMarks.countDays
        FormulaDaysCenter.shared.run(vm, lastDays: max(1, n))
    }
}

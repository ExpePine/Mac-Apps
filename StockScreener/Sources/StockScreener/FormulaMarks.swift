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
        if (force || missing || fc.days.isEmpty) && !fc.running && !wanted.isEmpty {
            let n = UserDefaults.standard.object(forKey: "fdays.last") as? Int ?? 60
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
            if freshAll && !f.fresh {
                let all = Array(Set(m.keys)).sorted()
                let starts = FormulaDaysCenter.runStarts(m, days: all, mode: FormulaDaysCenter.freshMode, gap: FormulaDaysCenter.freshGap)
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
        revision += 1
    }

    func name(_ key: String) -> String { names[key] ?? key }

    /// Days (newest first) a formula was true for a stock, in the counted days.
    func days(_ key: String, _ symbol: String) -> [String] {
        let sym = symbol.uppercased()
        return (hits[key] ?? [:]).filter { $0.value.contains(sym) }.keys.sorted(by: >)
    }

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
            let parts = ks.map { k -> String in let n = (hits[k]?[day]?.count ?? 1) - 1; return label(k) + (n > 0 ? " \(n)" : "") }
            let text = parts.prefix(3).joined(separator: " · ") + (parts.count > 3 ? " +\(parts.count - 3)" : "")
            let color = ks.count > 1 ? "#FFC400" : "#E040FB"
            let info = ks.map { k in let n = (hits[k]?[day]?.count ?? 1) - 1; return name(k) + " (\(n) other\(n == 1 ? "" : "s"))" }.joined(separator: "  ·  ")
                + " — click to see the other stocks"
            out.append(LWChartData.Marker(time: day, text: text, position: "aboveBar", color: color, shape: "arrowDown", info: info, id: "fpill"))
        }
        return out
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
    @State private var picked: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "fmarks.picked") ?? [])
    @State private var open = false
    @State private var search = ""

    var body: some View {
        HStack(spacing: 4) {
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
                if fm.running { ProgressView().controlSize(.mini) }
                Text(label).font(.caption2).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
        }
        .buttonStyle(.borderless).fixedSize()
        .help("Formula marks: on each day, every chosen formula that was true for this stock — 1F11 = formula 1, true for 11 other stocks that day (click the mark to see them in Quick). Gold when more than one formula was true. Uses Formula counts' results: the same days (its Days setting) and its \"Also require\".")
        .popover(isPresented: $open, arrowEdge: .bottom) { panel }
        .onAppear { fm.ensure(vm); if !symbol.isEmpty { fm.chartSymbol = symbol } }
        .onChange(of: symbol) { s in if !s.isEmpty { fm.chartSymbol = s } }
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
            FreshModePicker { fm.ensure(vm, force: true) }
            HStack {
                Text(fm.running ? "Counting… \(fm.progress)" : (fm.coverage.isEmpty ? "Nothing counted yet" : "Uses \(fm.coverage) (set Days in Formula counts)"))
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
        let n = UserDefaults.standard.object(forKey: "fdays.last") as? Int ?? 60
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("\"Just became true\" =", selection: $mode) {
                Text("true that day, not the day before").tag(0)
                Text("the original first day of the run").tag(1)
            }
            .help("The first: a stock that drops out for a day and comes back is marked again (often late in a rise). The second walks back while the condition kept being true and marks the day it originally became true.")
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
        let n = UserDefaults.standard.object(forKey: "fdays.last") as? Int ?? 60
        FormulaDaysCenter.shared.run(vm, lastDays: max(1, n))
    }
}

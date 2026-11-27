import SwiftUI
import AppKit

/// "Days since" on chosen columns: a condition per column (e.g. DELSMAC > 80) and a gap allowance. Each cell of that
/// column gets a small tag in front of its value:
///   • condition true today → "12d": trading days since the current run began (false days of up to `gap` in a row
///     don't break the run);
///   • false today → "5d ago": trading days since it was last true (blank if not within the look-back).
/// Delivery columns (DELSMAC, M_ / W_ …) walk the NSE delivery history; sheet columns walk the stored daily sheets.
struct DaysSinceRule: Codable, Equatable {
    var op = ">"            // >, ≥, <, ≤
    var value = 80.0
    var gap = 5             // false days in a row allowed inside a run
    var on = true

    func holds(_ v: Double) -> Bool {
        switch op {
        case "≥": return v >= value
        case "<": return v < value
        case "≤": return v <= value
        default: return v > value
        }
    }
    var text: String { "\(op) \(value.formatted(.number.precision(.fractionLength(0...2))))" }
}

@MainActor final class DaysSinceCenter: ObservableObject {
    static let shared = DaysSinceCenter()

    /// The toggle: tags shown at all.
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "dsince.on") {
        didSet { UserDefaults.standard.set(enabled, forKey: "dsince.on") }
    }
    /// column name → rule
    @Published var rules: [String: DaysSinceRule] = DaysSinceCenter.load() {
        didSet { if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: "dsince.rules") } }
    }
    /// column → SYMBOL → days (≥ 0: true now, run length; < 0: false now, last true −n days ago)
    @Published private(set) var result: [String: [String: Int]] = [:]
    @Published private(set) var version = 0
    @Published private(set) var running = false

    static let lookBack = 250
    private var task: Task<Void, Never>?
    private var lastKey = ""

    private static func load() -> [String: DaysSinceRule] {
        (UserDefaults.standard.data(forKey: "dsince.rules")).flatMap { try? JSONDecoder().decode([String: DaysSinceRule].self, from: $0) } ?? [:]
    }

    var activeRules: [String: DaysSinceRule] { rules.filter { $0.value.on } }

    /// The tag for a cell, or nil.
    func tag(column: String, symbol: String) -> (String, NSColor)? {
        guard enabled, let n = result[column]?[symbol.uppercased()] else { return nil }
        return n >= 0 ? ("\(n)d", .systemTeal) : ("\(-n)d ago", .tertiaryLabelColor)
    }

    /// Recount when the data day, the rules or the toggle changed (cheap no-op otherwise).
    func refresh(_ vm: ScreenerViewModel, force: Bool = false) {
        guard enabled, !activeRules.isEmpty, let label = vm.labelIndex else { return }
        let liveKey = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        let key = liveKey + "|" + (String(data: (try? JSONEncoder().encode(activeRules.sorted { $0.key < $1.key }.map { [$0.key, $0.value.text, "\($0.value.gap)"] })) ?? Data(), encoding: .utf8) ?? "")
            + "|\(vm.table.rows.count)|\(DeliveryCenter.shared.book.days.count)"
        guard force || key != lastKey else { return }
        lastKey = key
        task?.cancel()
        let rs = activeRules
        let current = vm.table
        running = true
        task = Task { @MainActor in
            var out: [String: [String: Int]] = [:]
            for (col, rule) in rs {
                if Task.isCancelled { break }
                guard let ci = current.index(of: col) else { continue }
                out[col] = await walk(vm, col: col, ci: ci, rule: rule, current: current, label: label, liveKey: liveKey)
                result[col] = out[col]; version &+= 1
            }
            if !Task.isCancelled { result = out; version &+= 1 }
            running = false
        }
    }

    /// Walks back day by day from today until every stock's answer is settled (or the look-back runs out).
    private func walk(_ vm: ScreenerViewModel, col: String, ci: Int, rule: DaysSinceRule, current: SheetTable,
                      label: Int, liveKey: String) async -> [String: Int] {
        let delivery = ScreenerViewModel.isDeliveryColumn(col)
        let past = (delivery ? DeliveryCenter.shared.book.days : HistoryStore.days()).filter { $0 < liveKey }.suffix(Self.lookBack).reversed()
        let days = [liveKey] + Array(past)

        struct State { var trueNow: Bool; var lastTrue: Int; var falseRun: Int; var done: Bool }
        var st: [String: State] = [:]
        for (k, d) in days.enumerated() {
            if Task.isCancelled { return [:] }
            var t: SheetTable? = nil
            if k == 0 { t = current }
            else if delivery { t = vm.withDeliveryValues(current, asOf: d, only: [col]) }
            else {
                t = await Task.detached(priority: .userInitiated) {
                    HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) }
                }.value
            }
            guard let t, let idx = t.index(of: col) ?? (k == 0 ? ci : nil) else { continue }
            var open = 0
            for r in t.rows {
                let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                guard !sym.isEmpty else { continue }
                let ok = r.number(idx).map(rule.holds) ?? false
                if k == 0 { st[sym] = State(trueNow: ok, lastTrue: ok ? 0 : -1, falseRun: 0, done: false); open += 1; continue }
                guard var s = st[sym], !s.done else { continue }
                if s.trueNow {
                    if ok { s.lastTrue = k; s.falseRun = 0 }
                    else { s.falseRun += 1; if s.falseRun > rule.gap { s.done = true } }
                } else if ok { s.lastTrue = k; s.done = true }
                st[sym] = s
                if !s.done { open += 1 }
            }
            if k > 0 && open == 0 { break }
            if k % 5 == 0 { await Task.yield() }
        }
        var out: [String: Int] = [:]
        for (sym, s) in st {
            if s.trueNow { out[sym] = s.lastTrue } else if s.lastTrue > 0 { out[sym] = -s.lastTrue }
        }
        return out
    }
}

/// The per-column settings, shown in a column's ▼ panel (Filter and Daily gainers).
struct DaysSinceEditor: View {
    let column: String
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = DaysSinceCenter.shared

    private var rule: Binding<DaysSinceRule> {
        Binding(get: { c.rules[column] ?? DaysSinceRule(on: false) },
                set: { c.rules[column] = $0; c.refresh(vm) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Days since", isOn: rule.on).toggleStyle(.checkbox).font(.subheadline.bold())
                Spacer()
                if c.running { ProgressView().controlSize(.mini) }
            }
            .help("A small tag in front of each value: how many trading days the condition has held (12d), or how long ago it last held (5d ago)")
            if rule.wrappedValue.on {
                HStack(spacing: 6) {
                    Text(column).font(.caption.monospaced()).lineLimit(1)
                    Picker("", selection: rule.op) { ForEach([">", "≥", "<", "≤"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().fixedSize()
                    TextField("", value: rule.value, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Text("Allow gaps of up to")
                    TextField("", value: rule.gap, format: .number).frame(width: 36).textFieldStyle(.roundedBorder)
                    Stepper("", value: rule.gap, in: 0...60).labelsHidden()
                    Text("days")
                }
                .font(.caption)
                .help("A run of true days isn't broken by this many false days in a row")
                if !c.enabled {
                    Button("Turn on Days since tags") { c.enabled = true; c.refresh(vm, force: true) }.controlSize(.small)
                }
            }
        }
    }
}

/// Toolbar toggle for the tags.
struct DaysSinceToggle: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = DaysSinceCenter.shared

    var body: some View {
        Toggle(isOn: Binding(get: { c.enabled }, set: { c.enabled = $0; if $0 { c.refresh(vm, force: true) } })) {
            Label("Days since", systemImage: "calendar.badge.clock")
        }
        .help(c.activeRules.isEmpty
              ? "Days since: set a condition on a column first (its header ▼ → Days since)"
              : "Days since on " + c.activeRules.keys.sorted().map { "\($0) \(c.rules[$0]!.text) (gaps ≤ \(c.rules[$0]!.gap))" }.joined(separator: ", "))
        .onAppear { c.refresh(vm) }
        .onChange(of: vm.filterVersion) { _ in c.refresh(vm) }
    }
}

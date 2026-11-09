import SwiftUI

// MARK: - Shortlist alerts
//
// "D_Trigger is the shortlist; alert me when MS > 99 or DS > 99." A stock is on the shortlist while its shortlist
// column has any value. The alert fires when one of the conditions BECOMES true — it wasn't true for that stock
// on the previous stored day (or the stock wasn't in that day's data) — once per stock per data day, in the
// Alerts window (and the in-app banner).

struct ShortlistCond: Codable, Equatable, Identifiable {
    var id = UUID()
    var column = "MS"
    var op = ">"                 // > ≥ < ≤ =
    var value = 99.0
    func passes(_ v: Double?) -> Bool {
        guard let v else { return false }
        switch op {
        case "≥": return v >= value
        case "<": return v < value
        case "≤": return v <= value
        case "=": return v == value
        default: return v > value
        }
    }
    var text: String { "\(column) \(op) \(CombiEngine.fmt(value))" }
}

struct ShortlistAlert: Codable, Equatable, Identifiable {
    var id = UUID()
    var isEnabled = true
    var shortlistColumn = "D_Trigger"
    var conditions: [ShortlistCond] = [ShortlistCond(column: "MS"), ShortlistCond(column: "DS")]
    var becomes = true           // false = every day it is true
    var streakDays: Int? = nil           // with becomes: fire on day N of being true in a row (1 = the day it became true)
    var n: Int { max(1, streakDays ?? 1) }
    /// What this alert checks (for caching day results).
    var signature: String { "\(shortlistText)|\(conditions.map(\.text).joined(separator: ","))|\(all)" }
    var fireText: String {
        guard becomes else { return "every day it is true" }
        return n == 1 ? "just became true (false the day before)" : "true \(n) days in a row (false the day before that)"
    }
    var matchAll: Bool? = nil            // true = ALL conditions (and), else ANY (or)
    var customName: String? = nil        // your own name for the alert
    var shortlistOp: String? = nil       // nil / "has a value", or > ≥ < ≤ =
    var shortlistValue: Double? = nil
    var shortlistText: String {
        guard let op = shortlistOp, op != "has a value", let v = shortlistValue else { return shortlistColumn }
        return "\(shortlistColumn) \(op) \(CombiEngine.fmt(v))"
    }
    var all: Bool { matchAll ?? false }
    var rule: String { "\(shortlistText) → " + conditions.map(\.text).joined(separator: all ? " and " : " or ") }
    var name: String {
        if let n = customName?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return "Shortlist " + rule
    }
    /// Is this row on the shortlist?
    func onShortlist(_ r: SheetRow, column sc: Int) -> Bool {
        let s = r.text(sc).trimmingCharacters(in: .whitespaces)
        guard let op = shortlistOp, op != "has a value", let v = shortlistValue else { return r.number(sc) != nil || (!s.isEmpty && s != "∅") }
        return ShortlistCond(column: shortlistColumn, op: op, value: v).passes(r.number(sc))
    }
}

enum ShortlistStore {
    static let key = "shortlistAlerts.v1"
    /// D_Trigger → DELSMA > 99, i.e. ta.percentrank(ta.sma(DELIV_QTY*close, 22|66), 300) > 99.
    static let delsmaAlert = ShortlistAlert(id: UUID(uuidString: "D5A1E7C3-0B2F-4E6D-8A91-2C3B4D5E6F70")!,
                                            conditions: [ShortlistCond(column: "DELSMA", op: ">", value: 99)])
    static let msdsAlert = ShortlistAlert(id: UUID(uuidString: "5B0A7C1E-3D2F-4A9B-8C7D-6E5F4A3B2C10")!)
    static var all: [ShortlistAlert] {
        get {
            var l: [ShortlistAlert] = [msdsAlert]                  // D_Trigger → MS > 99 or DS > 99
            if let d = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([ShortlistAlert].self, from: d) { l = saved }
            if UserDefaults.standard.data(forKey: key) == nil {           // save once, so the ids never change
                UserDefaults.standard.set(true, forKey: "shortlist.delsmaAdded")
                l.append(delsmaAlert)
                UserDefaults.standard.set(try? JSONEncoder().encode(l), forKey: key)
                return l
            }
            if !UserDefaults.standard.bool(forKey: "shortlist.delsmaAdded") {
                UserDefaults.standard.set(true, forKey: "shortlist.delsmaAdded")
                if !l.contains(where: { $0.id == delsmaAlert.id }) { l.append(delsmaAlert); UserDefaults.standard.set(try? JSONEncoder().encode(l), forKey: key) }
            }
            return l
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

extension ScreenerViewModel {
    private static var prevCache: (day: String, rows: [String: SheetRow], headers: [String])?

    /// Previous day's text when a cell's value differs from it (the Filter shades its border); nil = unchanged / unknown.
    func previousValue(_ row: SheetRow, column c: Int) -> String? {
        guard timelineIndex == nil, let label = labelIndex, c != label, let prev = previousDayRows() else { return nil }
        guard let old = prev.rows[row.text(label).trimmingCharacters(in: .whitespaces).uppercased()], c < old.cells.count else { return nil }
        let now = row.text(c).trimmingCharacters(in: .whitespaces), was = old.text(c).trimmingCharacters(in: .whitespaces)
        if let a = row.number(c), let b = old.number(c) { return abs(a - b) > 1e-9 * max(1, abs(a)) ? was : nil }
        return now == was ? nil : was
    }

    /// Day the comparison is made against (for the status line).
    var previousStoredDay: String? {
        let liveKey = HistoryStore.dayKey(dataDay(of: table))
        return HistoryStore.days().filter { $0 < liveKey }.last
    }

    /// The previous stored day's rows by symbol (aligned to today's columns, with that day's delivery columns).
    func previousDayRows() -> (rows: [String: SheetRow], table: SheetTable)? {
        guard let label = labelIndex else { return nil }
        let liveKey = HistoryStore.dayKey(dataDay(of: table))
        guard let prev = HistoryStore.days().filter({ $0 < liveKey }).last else { return nil }
        if let c = Self.prevCache, c.day == prev, c.headers == table.headers {
            return (c.rows, table)
        }
        guard let data = HistoryStore.load(prev), let aligned = ScreenerViewModel.align(data, to: table) else { return nil }
        let t = withDeliveryValues(aligned, asOf: prev)
        var map: [String: SheetRow] = [:]
        for r in t.rows { map[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] = r }
        Self.prevCache = (prev, map, table.headers)
        return (map, t)
    }

    /// Columns the app recomputes for stored days (delivery analysis).
    static let deliveryNames = ["DLVR", "Safety", "DQ_PRANK", "JUMP", "DELSMA", "STREAK", "t3Color", "HI/T3"]
    private static var truthCache: [String: Set<String>] = [:]

    /// Symbols for which the whole formula (shortlist AND the conditions) holds in `t`.
    nonisolated static func holdsSet(_ a: ShortlistAlert, t: SheetTable, label: Int) -> Set<String> {
        guard let sc = t.index(of: a.shortlistColumn) else { return [] }
        let conds = a.conditions.compactMap { c in t.index(of: c.column).map { (c, $0) } }
        guard !conds.isEmpty else { return [] }
        var out = Set<String>()
        for r in t.rows where a.onShortlist(r, column: sc) {
            let ok = a.all ? conds.allSatisfy { c, i in c.passes(r.number(i)) } : conds.contains { c, i in c.passes(r.number(i)) }
            if ok { out.insert(r.text(label).trimmingCharacters(in: .whitespaces).uppercased()) }
        }
        return out
    }

    private func needsDelivery(_ a: ShortlistAlert) -> Bool {
        ([a.shortlistColumn] + a.conditions.map(\.column)).contains { c in Self.deliveryNames.contains { c.hasPrefix($0) } }
    }

    /// The formula on a stored day (cached).
    func storedTruth(_ a: ShortlistAlert, day: String) -> Set<String> {
        let key = a.signature + "|" + day + "|\(table.headers.count)"
        if let c = Self.truthCache[key] { return c }
        guard let label = labelIndex, let data = HistoryStore.load(day), var t = ScreenerViewModel.align(data, to: table) else { return [] }
        if needsDelivery(a) { t = withDeliveryValues(t, asOf: day) }
        let s = Self.holdsSet(a, t: t, label: label)
        if Self.truthCache.count > 600 { Self.truthCache.removeAll() }
        Self.truthCache[key] = s
        return s
    }

    /// Stored days before the live data day, oldest first.
    var storedDaysBeforeLive: [String] {
        let liveKey = HistoryStore.dayKey(dataDay(of: table))
        return HistoryStore.days().filter { $0 < liveKey }
    }

    /// Stocks for which the alert fires today: the whole formula is true today and — with "became true" — has been
    /// true exactly N stored days in a row (it was false, or the stock was missing, on the day before the run).
    func shortlistMatches(_ alert: ShortlistAlert) -> [SheetRow] {
        guard alert.isEnabled, let label = labelIndex else { return [] }
        var hit = Self.holdsSet(alert, t: table, label: label)
        if alert.becomes, !hit.isEmpty {
            let back = Array(storedDaysBeforeLive.suffix(alert.n).reversed())        // most recent first
            if !back.isEmpty {                                                       // no stored day yet: everything is new
                for k in 0..<(alert.n - 1) {
                    guard k < back.count else { hit = []; break }
                    hit.formIntersection(storedTruth(alert, day: back[k]))
                }
                if alert.n - 1 < back.count { hit.subtract(storedTruth(alert, day: back[alert.n - 1])) }
            }
        }
        guard !hit.isEmpty else { return [] }
        return table.rows.filter { hit.contains($0.text(label).trimmingCharacters(in: .whitespaces).uppercased()) }
    }

    /// Every past time the alert would have fired on your stored days, and what the stock did afterwards.
    func shortlistBacktest(_ a: ShortlistAlert, progress: @escaping (Double) -> Void) async -> ShortlistBacktest {
        guard let label = labelIndex else { return ShortlistBacktest(fires: [], days: 0) }
        let days = storedDaysBeforeLive
        let liveKey = HistoryStore.dayKey(dataDay(of: table))
        var truths: [Set<String>] = []
        for (i, d) in days.enumerated() {
            let key = a.signature + "|" + d + "|\(table.headers.count)"
            if let c = Self.truthCache[key] { truths.append(c) }
            else {
                let current = table
                let t0 = await Task.detached(priority: .userInitiated) { HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) } }.value
                guard var t = t0 else { truths.append([]); continue }
                if needsDelivery(a) { t = withDeliveryValues(t, asOf: d) }
                let s = Self.holdsSet(a, t: t, label: label)
                Self.truthCache[key] = s
                truths.append(s)
            }
            if i % 5 == 0 { progress(Double(i) / Double(max(1, days.count))); await Task.yield() }
        }
        truths.append(Self.holdsSet(a, t: table, label: label))
        let allDays = days + [liveKey]
        var fires: [ShortlistFire] = []
        let n = a.becomes ? a.n : 1
        for i in allDays.indices where i >= n {
            var hit = truths[i]
            if a.becomes {
                for k in 1..<n { hit.formIntersection(truths[i - k]) }
                hit.subtract(truths[i - n])
            }
            for sym in hit.sorted() { fires.append(fire(sym, day: allDays[i])) }
        }
        progress(1)
        return ShortlistBacktest(fires: fires.sorted { $0.day == $1.day ? $0.symbol < $1.symbol : $0.day > $1.day }, days: allDays.count)
    }

    /// % moves after `day` from the stock's close that day (Yahoo closes, else NSE's).
    private func fire(_ sym: String, day: String) -> ShortlistFire {
        var f = ShortlistFire(day: day, symbol: sym)
        let days: [String], closes: [Double]
        if let p = priceBook.series(for: sym), !p.days.isEmpty { days = p.days; closes = p.closes }
        else if let s = DeliveryCenter.shared.book.series[SymbolBook.clean(sym)], !s.days.isEmpty { days = s.days; closes = s.close }
        else { return f }
        guard let i = days.firstIndex(where: { $0 >= day }), closes[i] > 0 else { return f }
        let base = closes[i]
        f.close = base
        func after(_ k: Int) -> Double? { i + k < closes.count ? closes[i + k] / base - 1 : nil }
        f.r5 = after(5); f.r10 = after(10); f.r22 = after(22)
        let rest = closes[i...]
        f.now = closes.last.map { $0 / base - 1 }
        f.best = rest.max().map { $0 / base - 1 }
        f.worst = rest.min().map { $0 / base - 1 }
        f.bars = closes.count - 1 - i
        return f
    }

    /// In-app alerts for every enabled shortlist alert (records them in the Alerts window).
    func shortlistInAppAlerts() -> [InAppAlert] {
        ShortlistStore.all.compactMap { a in
            let rows = shortlistMatches(a)
            guard !rows.isEmpty else { return nil }
            var rule = BuyTrigger(isEnabled: true, name: a.name)
            rule.id = a.id
            var any = FilterGroup(mode: a.all ? .all : .any)
            any.conditions = a.conditions.map { c in
                FilterCondition(column: c.column, op: RuleOperator(rawValue: c.op) ?? .greaterThan, value: CombiEngine.fmt(c.value))
            }
            let sl: FilterCondition = (a.shortlistOp.flatMap { RuleOperator(rawValue: $0) }).map { op in
                FilterCondition(column: a.shortlistColumn, op: op, value: CombiEngine.fmt(a.shortlistValue ?? 0))
            } ?? FilterCondition(column: a.shortlistColumn, op: .hasValue)
            rule.filter = FilterGroup(mode: .all, conditions: [sl], groups: [any])
            recordAlertEvents(rule: rule, rows: rows, kind: .alert)
            if TrackerCenter.shared.autoAdd { TrackerCenter.shared.add(rows.map { rowKey($0) }, source: a.name, vm: self) }   // → Alert Tracker
            let when = !a.becomes ? "" : (a.n == 1 ? " (became true today)" : " (true \(a.n) days in a row)")
            return InAppAlert(triggerID: a.id, name: a.name + when, stocks: rows.map { rowKey($0) })
        }
    }
}

struct ShortlistFire: Identifiable {
    var id: String { day + "|" + symbol }
    let day: String
    let symbol: String
    var close: Double?
    var r5: Double?, r10: Double?, r22: Double?
    var now: Double?, best: Double?, worst: Double?
    var bars = 0
}

struct ShortlistBacktest {
    let fires: [ShortlistFire]
    let days: Int
    private func avg(_ k: KeyPath<ShortlistFire, Double?>) -> Double? {
        let v = fires.compactMap { $0[keyPath: k] }; return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    private func up(_ k: KeyPath<ShortlistFire, Double?>) -> Double? {
        let v = fires.compactMap { $0[keyPath: k] }; return v.isEmpty ? nil : Double(v.filter { $0 > 0 }.count) / Double(v.count)
    }
    var summary: [(String, String)] {
        func p(_ v: Double?) -> String { v.map { String(format: "%+.1f%%", $0 * 100) } ?? "—" }
        func w(_ v: Double?) -> String { v.map { String(format: "%.0f%% up", $0 * 100) } ?? "" }
        return [("After 5 days", p(avg(\.r5)) + "  " + w(up(\.r5))),
                ("After 10 days", p(avg(\.r10)) + "  " + w(up(\.r10))),
                ("After 22 days", p(avg(\.r22)) + "  " + w(up(\.r22))),
                ("Till today", p(avg(\.now)) + "  " + w(up(\.now))),
                ("Best close after", p(avg(\.best))),
                ("Worst close after", p(avg(\.worst)))]
    }
}

/// Alerts window → "Shortlist alerts…": edit / add alerts like "D_Trigger → MS > 99 or DS > 99".
struct ShortlistAlertsEditor: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var alerts: [ShortlistAlert] = ShortlistStore.all
    @State private var preview: [UUID: [String]] = [:]
    @State private var tests: [UUID: ShortlistBacktest] = [:]
    @State private var testing: [UUID: Double] = [:]
    @State private var showFires: UUID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortlist alerts").font(.title2.bold())
            Text("A stock is on the shortlist while its shortlist column has a value (or meets its comparison). With ✓ Only when it just became true, the alert fires when the whole formula — shortlist and conditions — is true today but wasn't on the stored day before (or has been true exactly N days in a row). Once per stock per day, in the Alerts window.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($alerts) { $a in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Name").font(.callout).frame(width: 80, alignment: .trailing)
                                TextField("e.g. D_Trigger + Short_Green", text: Binding(get: { a.customName ?? "" }, set: { a.customName = $0.isEmpty ? nil : $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 300)
                                Text(a.customName == nil ? "(automatic: \(a.rule))" : a.rule).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            HStack {
                                Toggle("", isOn: $a.isEnabled).labelsHidden()
                                Text("Shortlist =").font(.callout)
                                Picker("", selection: $a.shortlistColumn) { ForEach(vm.headers, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 160)
                                Picker("", selection: Binding(get: { a.shortlistOp ?? "has a value" },
                                                              set: { a.shortlistOp = $0 == "has a value" ? nil : $0; if a.shortlistValue == nil { a.shortlistValue = 20 } })) {
                                    ForEach(["has a value", "≤", "<", "=", "≥", ">"], id: \.self) { Text($0).tag($0) }
                                }.labelsHidden().fixedSize()
                                if a.shortlistOp != nil {
                                    TextField("", value: Binding(get: { a.shortlistValue ?? 20 }, set: { a.shortlistValue = $0 }), format: .number)
                                        .frame(width: 60).textFieldStyle(.roundedBorder)
                                }
                                Spacer()
                                Button(role: .destructive) { alerts.removeAll { $0.id == a.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                            ForEach($a.conditions) { $c in
                                HStack {
                                    if a.conditions.first?.id == c.id {
                                        Text("Alert when").font(.callout).frame(width: 80, alignment: .trailing)
                                    } else {
                                        Picker("", selection: Binding(get: { a.all }, set: { a.matchAll = $0 })) {
                                            Text("or").tag(false); Text("and").tag(true)
                                        }
                                        .labelsHidden().frame(width: 80, alignment: .trailing)
                                        .help("or = any condition fires the alert · and = all of them must be true")
                                    }
                                    Picker("", selection: $c.column) { ForEach(vm.headers, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 150)
                                    Picker("", selection: $c.op) { ForEach([">", "≥", "<", "≤", "="], id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
                                    TextField("", value: $c.value, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                                    Button { a.conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                        .disabled(a.conditions.count <= 1)
                                }
                            }
                            HStack {
                                Button { a.conditions.append(ShortlistCond(column: a.conditions.last?.column ?? "MS", op: ">", value: 99)) } label: { Label(a.all ? "and …" : "or …", systemImage: "plus") }
                                Toggle("Only when it just became true", isOn: $a.becomes).toggleStyle(.checkbox)
                                    .help("✓ = fire once, when the whole formula is true but wasn't on the stored day before · off = every day it is true")
                                if a.becomes {
                                    Text("· true").font(.callout)
                                    Picker("", selection: Binding(get: { a.n }, set: { a.streakDays = $0 == 1 ? nil : $0 })) {
                                        ForEach([1, 2, 3, 5, 7, 10, 15, 20, 30], id: \.self) { d in Text(d == 1 ? "1 day (today)" : "\(d) days").tag(d) }
                                    }.labelsHidden().fixedSize()
                                    Text("in a row").font(.callout)
                                }
                                Spacer()
                                if let p = preview[a.id] {
                                    Text(p.isEmpty ? "No stock today" : "Today: " + p.prefix(8).joined(separator: ", ") + (p.count > 8 ? " +\(p.count - 8)" : ""))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .controlSize(.small)
                            Text("Fires when the formula is \(a.fireText).").font(.caption).foregroundStyle(.secondary)
                            historyRow(a)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
            }
            HStack {
                Button { alerts.append(ShortlistAlert()) } label: { Label("New shortlist alert", systemImage: "plus") }
                Button("Preview today") { for a in alerts { preview[a.id] = vm.shortlistMatches(a).map { vm.rowKey($0) } } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & check now") {
                    ShortlistStore.all = alerts
                    vm.raiseInAppAlerts(asPopup: false, force: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 860, idealWidth: 920, minHeight: 600, idealHeight: 720)
    }

    /// "Test on history": every past firing on your stored days and the % move after it.
    @ViewBuilder private func historyRow(_ a: ShortlistAlert) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { test(a) } label: { Label("How did it do after? (test on stored days)", systemImage: "chart.line.uptrend.xyaxis") }
                    .controlSize(.small).disabled(testing[a.id] != nil)
                if let p = testing[a.id] { ProgressView(value: p).frame(width: 120) }
                if let t = tests[a.id] {
                    Text("\(t.fires.count) time\(t.fires.count == 1 ? "" : "s") in \(t.days) stored days").font(.caption.bold())
                    Spacer()
                    if !t.fires.isEmpty {
                        Button(showFires == a.id ? "Hide list" : "Show each") { showFires = showFires == a.id ? nil : a.id }.controlSize(.small)
                    }
                }
            }
            if let t = tests[a.id], !t.fires.isEmpty {
                HStack(spacing: 14) {
                    ForEach(t.summary, id: \.0) { item in
                        let k = item.0, v = item.1
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k).font(.caption2).foregroundStyle(.secondary)
                            Text(v).font(.caption.monospacedDigit().bold()).foregroundStyle(v.hasPrefix("+") ? Color.green : (v.hasPrefix("-") ? Color.red : Color.primary))
                        }
                    }
                }
                if showFires == a.id {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            HStack { col("Day", 86); col("Stock", 110); col("Close", 70); col("5d", 60); col("10d", 60); col("22d", 60); col("Best", 60); col("Worst", 60); col("Now", 60) }
                                .font(.caption2.bold()).foregroundStyle(.secondary)
                            ForEach(t.fires) { f in
                                HStack {
                                    col(f.day, 86)
                                    Button(f.symbol) {
                                        vm.openChart(f.symbol, queue: t.fires.map(\.symbol), goTo: f.day, openWindow: openWindow)
                                    }.buttonStyle(.link).frame(width: 110, alignment: .leading)
                                    col(f.close.map { String(format: "%.2f", $0) } ?? "—", 70)
                                    pct(f.r5); pct(f.r10); pct(f.r22); pct(f.best); pct(f.worst); pct(f.now)
                                }
                                .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                Text("% from the close on the day it fired (Yahoo closes, else NSE). Only days the app stored are tested; recent fires have no 22-day result yet.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if let t = tests[a.id], t.fires.isEmpty {
                Text("Never fired on your \(t.days) stored days.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func col(_ s: String, _ w: CGFloat) -> some View { Text(s).frame(width: w, alignment: .leading).lineLimit(1) }
    private func pct(_ v: Double?) -> some View {
        Text(v.map { String(format: "%+.1f%%", $0 * 100) } ?? "—").frame(width: 60, alignment: .leading)
            .foregroundStyle((v ?? 0) > 0 ? Color.green : ((v ?? 0) < 0 ? Color.red : Color.secondary))
    }

    private func test(_ a: ShortlistAlert) {
        var a = a; a.isEnabled = true
        testing[a.id] = 0
        Task {
            let r = await vm.shortlistBacktest(a) { p in testing[a.id] = p }
            tests[a.id] = r
            testing[a.id] = nil
            if !r.fires.isEmpty { showFires = a.id }
        }
    }
}

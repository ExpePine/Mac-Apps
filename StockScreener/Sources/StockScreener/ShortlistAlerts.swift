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
    var shortlistOp: String? = nil       // nil / "has a value", or > ≥ < ≤ =
    var shortlistValue: Double? = nil
    var shortlistText: String {
        guard let op = shortlistOp, op != "has a value", let v = shortlistValue else { return shortlistColumn }
        return "\(shortlistColumn) \(op) \(CombiEngine.fmt(v))"
    }
    var name: String { "Shortlist \(shortlistText) → " + conditions.map(\.text).joined(separator: " or ") }
    /// Is this row on the shortlist?
    func onShortlist(_ r: SheetRow, column sc: Int) -> Bool {
        let s = r.text(sc).trimmingCharacters(in: .whitespaces)
        guard let op = shortlistOp, op != "has a value", let v = shortlistValue else { return r.number(sc) != nil || (!s.isEmpty && s != "∅") }
        return ShortlistCond(column: shortlistColumn, op: op, value: v).passes(r.number(sc))
    }
}

enum ShortlistStore {
    static let key = "shortlistAlerts.v1"
    static var all: [ShortlistAlert] {
        get {
            if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([ShortlistAlert].self, from: d) { return l }
            return [ShortlistAlert()]          // the one you asked for: D_Trigger → MS > 99 or DS > 99
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

    /// Stocks on the shortlist whose condition became true today, per alert.
    func shortlistMatches(_ alert: ShortlistAlert) -> [SheetRow] {
        guard alert.isEnabled, let label = labelIndex, let sc = table.index(of: alert.shortlistColumn) else { return [] }
        let conds = alert.conditions.compactMap { c in table.index(of: c.column).map { (c, $0) } }
        guard !conds.isEmpty else { return [] }
        let prev = alert.becomes ? previousDayRows() : nil
        return table.rows.filter { r in
            guard alert.onShortlist(r, column: sc) else { return false }                       // on the shortlist
            let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            let old = prev?.rows[sym]
            return conds.contains { c, i in
                guard c.passes(r.number(i)) else { return false }
                guard alert.becomes, prev != nil else { return true }
                guard let old else { return true }                 // new on the list today
                return !c.passes(old.number(i))                    // wasn't true the previous day
            }
        }
    }

    /// In-app alerts for every enabled shortlist alert (records them in the Alerts window).
    func shortlistInAppAlerts() -> [InAppAlert] {
        ShortlistStore.all.compactMap { a in
            let rows = shortlistMatches(a)
            guard !rows.isEmpty else { return nil }
            var rule = BuyTrigger(isEnabled: true, name: a.name)
            rule.id = a.id
            var any = FilterGroup(mode: .any)
            any.conditions = a.conditions.map { c in
                FilterCondition(column: c.column, op: RuleOperator(rawValue: c.op) ?? .greaterThan, value: CombiEngine.fmt(c.value))
            }
            let sl: FilterCondition = (a.shortlistOp.flatMap { RuleOperator(rawValue: $0) }).map { op in
                FilterCondition(column: a.shortlistColumn, op: op, value: CombiEngine.fmt(a.shortlistValue ?? 0))
            } ?? FilterCondition(column: a.shortlistColumn, op: .hasValue)
            rule.filter = FilterGroup(mode: .all, conditions: [sl], groups: [any])
            recordAlertEvents(rule: rule, rows: rows, kind: .alert)
            return InAppAlert(triggerID: a.id, name: a.name + (a.becomes ? " (became true today)" : ""), stocks: rows.map { rowKey($0) })
        }
    }
}

/// Alerts window → "Shortlist alerts…": edit / add alerts like "D_Trigger → MS > 99 or DS > 99".
struct ShortlistAlertsEditor: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var alerts: [ShortlistAlert] = ShortlistStore.all
    @State private var preview: [UUID: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortlist alerts").font(.title2.bold())
            Text("A stock is on the shortlist while its shortlist column has a value. The alert fires when ANY of the conditions becomes true (it wasn't true on the previous stored day) — once per stock per day, in the Alerts window.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($alerts) { $a in
                        VStack(alignment: .leading, spacing: 6) {
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
                                    Text(a.conditions.first?.id == c.id ? "Alert when" : "or").font(.callout).frame(width: 80, alignment: .trailing)
                                    Picker("", selection: $c.column) { ForEach(vm.headers, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 150)
                                    Picker("", selection: $c.op) { ForEach([">", "≥", "<", "≤", "="], id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
                                    TextField("", value: $c.value, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                                    Button { a.conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                        .disabled(a.conditions.count <= 1)
                                }
                            }
                            HStack {
                                Button { a.conditions.append(ShortlistCond(column: vm.headers.first ?? "", value: 0)) } label: { Label("or …", systemImage: "plus") }
                                Picker("", selection: $a.becomes) {
                                    Text("fire when it becomes true").tag(true)
                                    Text("fire every day it is true").tag(false)
                                }.labelsHidden().fixedSize()
                                Spacer()
                                if let p = preview[a.id] {
                                    Text(p.isEmpty ? "No stock today" : "Today: " + p.prefix(8).joined(separator: ", ") + (p.count > 8 ? " +\(p.count - 8)" : ""))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .controlSize(.small)
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
                    vm.raiseInAppAlerts(asPopup: false)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
    }
}

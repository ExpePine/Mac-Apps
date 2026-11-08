import SwiftUI
import AppKit
import WebKit
import UserNotifications

// MARK: - Formula alerts from F notes
//
// The pieces F recognises in a note (the chips: count=5, Long_Green=1.00, DELSMA>70, C/DL2C>1 …) become one formula,
// joined with AND. "Alert" saves it as an Email & Rules rule (in-app alert on, email off until you tick it), so it is
// checked with your other rules — once a day after the close by default — and shows in the Alerts pop-up, history
// and a macOS notification. The bell also lists the stocks that meet the formula right now.

@MainActor enum NoteAlerts {
    static let prefix = "F alert · "
    /// Opens a window by id (set by the F toolbar button — the floating F box has no SwiftUI window of its own).
    static var open: ((String) -> Void)?

    /// The note's recognised pieces in F syntax: "count=5 + Long_Green=1.00 + DELSMA>70".
    static func quick(_ text: String, headers: [String]) -> String {
        NoteChecker.pieces(text, columns: headers, values: [:]).map(\.canonical).joined(separator: " + ")
    }

    static func formula(_ quick: String, vm: ScreenerViewModel) -> Result<String, Error> {
        Result { try QuickF.formula(quick, headers: vm.headers) }
    }

    /// Stocks meeting the formula in today's data.
    static func matches(_ formula: String, vm: ScreenerViewModel) -> [String] {
        guard let p = try? Formula.compile(formula, table: vm.table).predicate else { return [] }
        return vm.rows.filter(p).map { vm.rowKey($0) }
    }

    static func ruleIndex(_ formula: String, vm: ScreenerViewModel) -> Int? {
        vm.settings.buyTriggers.firstIndex { t in
            t.filter.groups.isEmpty && t.filter.conditions.count == 1
                && t.filter.conditions[0].kind == .formula && t.filter.conditions[0].formula == formula
        }
    }

    static func add(quick: String, formula: String, vm: ScreenerViewModel) {
        guard ruleIndex(formula, vm: vm) == nil else { return }
        var r = BuyTrigger(isEnabled: true, name: prefix + quick)
        r.filter = FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: formula)])
        r.sendEmail = false
        r.alertInApp = true
        vm.settings.buyTriggers.append(r)
    }

    /// All F alerts (rules made here).
    static func rules(_ vm: ScreenerViewModel) -> [BuyTrigger] { vm.settings.buyTriggers.filter { $0.name.hasPrefix(prefix) } }

    /// The Filter shows exactly these stocks (and the reel can play them).
    static func showInFilter(_ formula: String, vm: ScreenerViewModel) {
        vm.settings.filterGroup = FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: formula)])
        open?("filter")
    }

    static func charts(_ formula: String, vm: ScreenerViewModel, startAt: String = "") {
        vm.settings.filterGroup = FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: formula)])
        let d = UserDefaults.standard
        d.set("List order", forKey: "reel.sort")
        d.set("", forKey: "reel.centre")
        d.set(ReelSource.filter.rawValue, forKey: "reel.source")
        d.set(UUID().uuidString + "|" + startAt, forKey: "reel.jump")
        open?("reel")
    }

    /// macOS notification for F alerts that fired (called with the fresh in-app alerts).
    static func notify(_ alerts: [InAppAlert]) {
        let mine = alerts.filter { $0.name.hasPrefix(prefix) }
        guard !mine.isEmpty, Bundle.main.bundleIdentifier != nil else { return }
        let body = mine.prefix(4).map { a in
            "\(a.name.dropFirst(prefix.count)): \(a.stocks.prefix(6).joined(separator: ", "))\(a.stocks.count > 6 ? " +\(a.stocks.count - 6)" : "")"
        }.joined(separator: "\n")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            let n = mine.reduce(0) { $0 + $1.stocks.count }
            c.title = "F formulas: \(n) stock\(n == 1 ? "" : "s") triggered"
            c.body = body
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "f-alerts-" + AlertSchedule.today(), content: c, trigger: nil))
        }
    }
}

// MARK: - Chart 1's crosshair → the F box's formula date

enum TVCursor {
    /// While the F box is open: read TradingView's crosshair day on this page and hand it to F.
    @MainActor static func poll(_ web: WKWebView?, symbol: String?) {
        guard QuickFPanel.shared.isOpen, let web, !web.isLoading, let symbol, !symbol.isEmpty else { return }
        TVRange.run(web, TVRange.crossBody) { r in
            guard let t = Int(r), t > 0 else { return }
            MBNoteFocus.shared.setCursor(symbol, day: TVRange.day(t))
        }
    }
}

// MARK: - The bell

struct NoteAlertButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let text: String
    var compact = false
    @State private var open = false
    @State private var quick = ""
    @State private var found: [String] = []
    @State private var error: String?
    @State private var formula = ""

    var body: some View {
        let q = NoteAlerts.quick(text, headers: vm.headers)
        let on = (try? QuickF.formula(q, headers: vm.headers)).flatMap { NoteAlerts.ruleIndex($0, vm: vm) }.map { vm.settings.buyTriggers[$0].isEnabled } ?? false
        Button { quick = q; open = true } label: {
            Label(compact ? "" : "Alert", systemImage: on ? "bell.fill" : "bell")
                .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .foregroundStyle(on ? Color.orange : Color.accentColor)
        }
        .buttonStyle(.link).font(.caption2)
        .disabled(q.isEmpty)
        .help(q.isEmpty ? "No Filter columns recognised in this note yet" : "Formula alert: \(q) — see which stocks meet it now, and get alerted when stocks trigger it")
        .popover(isPresented: $open, arrowEdge: .bottom) { pop }
    }

    private var pop: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Formula alert").font(.headline)
            TextField("count>5 + DELSMA>70", text: $quick, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced()).lineLimit(1...4)
            Text("Pieces are joined with AND · edit freely (| = OR, NOT col)").font(.caption2).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            else {
                HStack {
                    Text("Triggering now: \(found.count) stock\(found.count == 1 ? "" : "s")").font(.callout.bold())
                    Spacer()
                    Button("Filter") { NoteAlerts.showInFilter(formula, vm: vm); open = false }.disabled(found.isEmpty)
                    Button("Charts") { NoteAlerts.charts(formula, vm: vm); open = false }.disabled(found.isEmpty)
                }
                if !found.isEmpty {
                    ScrollView {
                        FlowLayout(spacing: 4, lineSpacing: 3) {
                            ForEach(found, id: \.self) { s in
                                Button(s) { NoteAlerts.charts(formula, vm: vm, startAt: s); open = false }
                                    .buttonStyle(.plain).font(.caption.monospaced())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.green.opacity(0.15)))
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
                Divider()
                alertRow
            }
        }
        .padding(12).frame(width: 380)
        .task(id: quick) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            switch NoteAlerts.formula(quick, vm: vm) {
            case .success(let f): formula = f; error = nil; found = NoteAlerts.matches(f, vm: vm)
            case .failure(let e): error = (e as? FormulaError)?.message ?? e.localizedDescription; found = []
            }
        }
    }

    @ViewBuilder private var alertRow: some View {
        if let i = NoteAlerts.ruleIndex(formula, vm: vm) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Alert me when stocks trigger this", isOn: $vm.settings.buyTriggers[i].isEnabled)
                Toggle("Email too", isOn: $vm.settings.buyTriggers[i].sendEmail)
                HStack {
                    Text("Checked \(AlertSchedule.describe) with your other rules").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { vm.settings.buyTriggers.remove(at: i) }.controlSize(.small)
                }
            }
            .toggleStyle(.checkbox)
        } else {
            HStack {
                Button { NoteAlerts.add(quick: quick.trimmingCharacters(in: .whitespacesAndNewlines), formula: formula, vm: vm) } label: {
                    Label("Create alert", systemImage: "bell.badge")
                }
                .buttonStyle(.borderedProminent)
                Text("In-app alert + notification \(AlertSchedule.describe); email off (tick it after)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Type-erased label style (icon only in tight places).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - All F alerts and what triggers them today (F Notes window)

struct NoteAlertsList: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @State private var counts: [UUID: [String]] = [:]
    @State private var expanded: UUID?

    var body: some View {
        let rules = NoteAlerts.rules(vm)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Formula alerts (\(rules.count))").font(.headline)
                Spacer()
                Button { recount() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Re-check on today's data")
            }
            if rules.isEmpty {
                Text("Press the 🔔 Alert button under a note to turn its formula into an alert.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rules) { r in
                let f = r.filter.conditions.first?.formula ?? ""
                let hits = counts[r.id] ?? []
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: r.isEnabled ? "bell.fill" : "bell.slash").foregroundStyle(r.isEnabled ? .orange : .secondary)
                        Text(r.name.dropFirst(NoteAlerts.prefix.count)).font(.callout.monospaced()).lineLimit(2)
                        Spacer()
                        Button("\(hits.count) now") { expanded = expanded == r.id ? nil : r.id }
                            .buttonStyle(.link).font(.caption.bold()).foregroundStyle(hits.isEmpty ? Color.secondary : Color.green)
                        Button("Charts") { NoteAlerts.charts(f, vm: vm) }.controlSize(.small).disabled(hits.isEmpty)
                        if let i = vm.settings.buyTriggers.firstIndex(where: { $0.id == r.id }) {
                            Toggle("", isOn: $vm.settings.buyTriggers[i].isEnabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .help("Alert on / off")
                        }
                    }
                    if expanded == r.id, !hits.isEmpty {
                        FlowLayout(spacing: 4, lineSpacing: 3) {
                            ForEach(hits, id: \.self) { s in
                                Button(s) { NoteAlerts.charts(f, vm: vm, startAt: s) }.buttonStyle(.plain).font(.caption.monospaced())
                                    .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.15)))
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(rules.count)|\(vm.table.rows.count)") { recount() }
    }

    private func recount() {
        var c: [UUID: [String]] = [:]
        for r in NoteAlerts.rules(vm) { if let f = r.filter.conditions.first?.formula { c[r.id] = NoteAlerts.matches(f, vm: vm) } }
        counts = c
    }
}

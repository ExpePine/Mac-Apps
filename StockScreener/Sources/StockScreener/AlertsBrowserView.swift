import SwiftUI
import AppKit

/// "Alerts" window: browse every alert that fired (in-app alerts and emails).
struct AlertsBrowserView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days", all = "All"
        var id: String { rawValue }
        var start: Date? {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }
    }

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", alerts = "Alerts", emails = "Emails", auto = "AUTO-PREDICT"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var period: Period = .week
    @State private var kind: KindFilter = .all
    @State private var rule = "All rules"
    @State private var selection: AlertEvent.ID?
    @State private var sortOrder = [KeyPathComparator(\AlertEvent.date, order: .reverse)]
    @State private var showShortlist = false
    @AppStorage("alerts.endOfDay") private var endOfDay = true
    @AppStorage("alerts.at") private var alertAt = 15 * 60 + 45
    static let alertTimes: [Int] = [935, 945, 960, 990, 1020, 1080, 1200]       // minutes after midnight IST
    static func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            if shown.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(vm.alertEvents.isEmpty ? "No alerts yet" : "No alerts match these filters").font(.title3.bold())
                    Text("Alerts appear here when an Email / Alert rule is met — set rules with the E buttons on the Filter screen.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    table.frame(minWidth: 520)
                    detail.frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                }
            }
            Divider()
            footer
        }
        .navigationTitle("Alerts")
        .sheet(isPresented: $showShortlist) { ShortlistAlertsEditor().environmentObject(vm) }
        .onAppear { vm.markAlertsSeen() }
        .onDisappear { vm.markAlertsSeen() }
    }

    private var filters: some View {
        FlowLayout(spacing: 10, lineSpacing: 8) {
            Button { showShortlist = true } label: { Label("Shortlist alerts…", systemImage: "list.bullet.rectangle") }
                .buttonStyle(.borderedProminent).fixedSize()
                .help("Edit alerts like D_Trigger → MS > 99 or DS > 99 — change > 99 to = 100 etc.")
            TextField("Search stock, rule or value", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("", selection: $kind) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Rule", selection: $rule) {
                Text("All rules").tag("All rules")
                ForEach(ruleNames, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 260)
            Picker("", selection: $endOfDay) {
                Text("Alert once a day").tag(true)
                Text("Alert as data arrives").tag(false)
            }
            .labelsHidden().fixedSize()
            .help("Once a day: every rule, shortlist alert and tracker watch is checked on the day's final data after the close and shown together. As data arrives: checked on every sheet update.")
            if endOfDay {
                Picker("at", selection: $alertAt) {
                    ForEach(Self.alertTimes, id: \.self) { (m: Int) in
                        Text(Self.hhmm(m)).tag(m)
                    }
                }
                .fixedSize()
                .help("IST, Monday–Friday. If the app is closed then, it runs when you next open it that day.")
            }
            Button { openWindow(id: "tracker") } label: { Label("Tracker", systemImage: "binoculars") }.fixedSize()
                .help("Every stock a shortlist alert fired on — % change since, chosen Filter columns, watches like count = 5 (⌥⌘J)")
            Button { openWindow(id: "autopredict") } label: { Label("AUTO-PREDICT…", systemImage: "wand.and.stars") }.fixedSize()
                .help("Stocks AUTO-PREDICT expects to gain ≥ 30% within a month — turn “Show predictions in Alerts” on there")
        }
        .padding(10)
    }

    private var table: some View {
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Stock", value: \.stock) { e in SymbolWithDots(symbol: e.stock, bold: false) }
                .width(min: 80, ideal: 110)
            TableColumn("Rule", value: \.ruleName)
                .width(min: 100, ideal: 150)
            TableColumn("Type", value: \.kind.rawValue) { e in
                Label(e.kind == .email ? "Email" : "Alert", systemImage: e.kind == .email ? "envelope.fill" : "bell.fill")
                    .foregroundStyle(e.kind == .email ? Color.blue : Color.orange)
            }
            .width(70)
            TableColumn("Values") { e in
                Text(e.values.dropFirst().joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn("Since alert") { e in
                if let c = vm.alertChange(e) {
                    Text(String(format: "%+.1f%%", c)).monospacedDigit().bold().foregroundStyle(c >= 0 ? Color.green : Color.red)
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 60, ideal: 75)
            TableColumn("When", value: \.date) { e in
                HStack(spacing: 4) {
                    if e.date > vm.alertsLastSeen { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Text(Self.short(e.date)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: AlertEvent.ID.self) { ids in
            if let id = ids.first, let e = vm.alertEvents.first(where: { $0.id == id }) {
                Button("Open chart") { vm.openChart(e.stock, queue: shown.map(\.stock), openWindow: openWindow) }
                Button("Open Filter screen") { vm.selectedStock = e.stock; openWindow(id: "filter") }
                Divider()
                Button("Delete this alert") { vm.deleteAlertEvents { ids.contains($0.id) } }
                Button("Delete all “\(e.ruleName)” alerts") { vm.deleteAlertEvents { $0.ruleName == e.ruleName } }
            }
        } primaryAction: { ids in
            if let id = ids.first, let e = vm.alertEvents.first(where: { $0.id == id }) {
                vm.openChart(e.stock, queue: shown.map(\.stock), openWindow: openWindow)      // double-click = chart
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let e = vm.alertEvents.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(e.stock).font(.title2.bold())
                    Label(e.kind == .email ? "Emailed" : "In-app alert",
                          systemImage: e.kind == .email ? "envelope.fill" : "bell.fill")
                        .foregroundStyle(e.kind == .email ? Color.blue : Color.orange)
                    Text(e.date.formatted(date: .complete, time: .standard)).font(.callout)
                    Text("Data of \(e.dataDay)").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Rule").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(e.ruleName).font(.headline)
                    Text(e.conditions).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Divider()
                    Text("Values at that moment").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(e.values, id: \.self) { v in
                        Text(v).font(.callout.monospacedDigit()).textSelection(.enabled)
                    }
                    Divider()
                    HStack {
                        Button {
                            vm.openChart(e.stock, queue: shown.map(\.stock), openWindow: openWindow)
                        } label: {
                            Label("Open chart", systemImage: "chart.xyaxis.line")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            vm.selectedStock = e.stock
                            openWindow(id: "filter")
                        } label: {
                            Label("Open Filter screen", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select an alert to see its details.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Per rule: how the stocks did after their alerts (close on the alert's data day → latest close).
    private var ruleStats: [(rule: String, n: Int, avg: Double, up: Double)] {
        let groups = Dictionary(grouping: shown.filter { $0.kind == .alert }, by: \.ruleName)
        return groups.compactMap { name, ev in
            let ch = ev.compactMap { vm.alertChange($0) }
            guard !ch.isEmpty else { return nil }
            return (name, ch.count, ch.reduce(0, +) / Double(ch.count), Double(ch.filter { $0 > 0 }.count) / Double(ch.count) * 100)
        }.sorted { $0.n > $1.n }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
        if !ruleStats.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Text("Track record:").font(.caption.bold())
                    ForEach(ruleStats, id: \.rule) { r in
                        Text("\(r.rule): \(r.n) alerts · avg \(String(format: "%+.1f%%", r.avg)) · \(Int(r.up))% up")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill((r.avg >= 0 ? Color.green : Color.red).opacity(0.12)))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        HStack {
            Text("\(shown.count) of \(vm.alertEvents.count) alerts · checked \(endOfDay ? "once a day at " + Self.hhmm(alertAt) + " IST" : "as data arrives") · double-click = chart")
            Spacer()
            Button("Clear all…") { confirmClear() }
                .disabled(vm.alertEvents.isEmpty)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        }
    }

    /// "17:21" today, "Thu 17:21" this week, else "23 Oct".
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let w = cal.dateComponents([.day], from: d, to: Date()).day, w < 6 { return d.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    private var ruleNames: [String] {
        Array(Set(vm.alertEvents.map(\.ruleName))).sorted()
    }

    private var shown: [AlertEvent] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let start = period.start
        return vm.alertEvents.filter { e in
            if let start, e.date < start { return false }
            if kind == .alerts && e.kind != .alert { return false }
            if kind == .emails && e.kind != .email { return false }
            if kind == .auto && e.ruleID != AutoPredictCenter.alertRuleID { return false }
            if rule != "All rules" && e.ruleName != rule { return false }
            if !q.isEmpty {
                let hay = ([e.stock, e.ruleName, e.conditions] + e.values).joined(separator: " ")
                if hay.range(of: q, options: .caseInsensitive) == nil { return false }
            }
            return true
        }.sorted(using: sortOrder)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all alerts?"
        alert.informativeText = "This removes the alert history. Your rules are not changed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { vm.clearAlertEvents() }
    }
}

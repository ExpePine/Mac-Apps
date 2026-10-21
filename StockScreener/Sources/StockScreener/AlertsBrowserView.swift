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
        .onAppear { vm.markAlertsSeen() }
        .onDisappear { vm.markAlertsSeen() }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            TextField("Search stock, rule or value", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
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
            .fixedSize()
            Spacer()
            Button { openWindow(id: "autopredict") } label: { Label("AUTO-PREDICT…", systemImage: "wand.and.stars") }
                .help("Stocks AUTO-PREDICT expects to gain ≥ 30% within a month — turn “Show predictions in Alerts” on there")
        }
        .padding(10)
    }

    private var table: some View {
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("When", value: \.date) { e in
                HStack(spacing: 4) {
                    if e.date > vm.alertsLastSeen { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Text(e.date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .width(min: 120, ideal: 140)
            TableColumn("Stock", value: \.stock) { e in Text(e.stock).fontWeight(.semibold) }
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
                    Button {
                        vm.selectedStock = e.stock
                        openWindow(id: "filter")
                    } label: {
                        Label("Open Filter screen", systemImage: "line.3.horizontal.decrease.circle")
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

    private var footer: some View {
        HStack {
            Text("\(shown.count) of \(vm.alertEvents.count) alerts")
            Spacer()
            Button("Clear all…") { confirmClear() }
                .disabled(vm.alertEvents.isEmpty)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

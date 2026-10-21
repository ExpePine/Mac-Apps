import SwiftUI
import Charts

/// AUTO-PREDICT: what combinations of Filter columns came before a ≥ 30% monthly move, today's stocks that
/// match the proven ones, and how past predictions turned out.
struct AutoPredictView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var ap = AutoPredictCenter.shared

    @AppStorage("ap.threshold") private var threshold = 30.0
    @AppStorage("ap.auto") private var autoRun = true
    @AppStorage("ap.alerts") private var toAlerts = true
    @AppStorage("ap.tab") private var tab = "Today"
    @State private var selRule: String?
    @State private var selPred: String?

    private var s: APState { ap.state }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            readiness
            Divider()
            Picker("", selection: $tab) {
                ForEach(["Today", "Combinations", "Track record", "Progress"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(8)
            switch tab {
            case "Combinations": rulesTable
            case "Track record": trackRecord
            case "Progress": progress
            default: today
            }
        }
        .navigationTitle("AUTO-PREDICT")
        .onAppear { ap.runIfDue(vm) }
    }

    // MARK: Header

    private var header: some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            Text("AUTO-PREDICT").font(.title2.bold()).fixedSize()
            phaseBadge.fixedSize()
            HStack(spacing: 4) {
                Text("Monthly gainer = peak gain ≥").font(.caption)
                TextField("", value: $threshold, format: .number).frame(width: 40).multilineTextAlignment(.trailing)
                Text("% within the next 21 trading days").font(.caption)
            }.fixedSize()
            Toggle("Re-learn on each new day", isOn: $autoRun).toggleStyle(.checkbox).fixedSize()
            Toggle("Show predictions in Alerts", isOn: $toAlerts).toggleStyle(.checkbox).fixedSize()
                .help("Each day's predicted stocks appear in the Alerts window as “AUTO-PREDICT” (filter: AUTO-PREDICT)")
            Button { ap.run(vm) } label: { Label(ap.running ? "Learning…" : "Re-learn now", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(ap.running).fixedSize()
            Button { openWindow(id: "alertlog") } label: { Label("Alerts", systemImage: "bell") }.fixedSize()
            if ap.running { ProgressView().controlSize(.small) }
            if let st = ap.status { Text(st).font(.caption).foregroundStyle(.orange).fixedSize() }
            else if let t = s.ranAt { Text("Learned \(t.formatted(date: .abbreviated, time: .shortened)) · data day \(s.lastRunDay)").font(.caption).foregroundStyle(.secondary).fixedSize() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var phaseBadge: some View {
        let c: Color = s.phase == .active ? .green : (s.phase == .learning ? .orange : .secondary)
        return Text(s.phase.rawValue).font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(c.opacity(0.2), in: Capsule()).foregroundStyle(c)
    }

    private var readiness: some View {
        let usable = s.rules.filter(\.usable).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 22) {
                meter("Labelled days", s.labeledDays, APEngine.minDays,
                      help: "Stored snapshot days that are 21+ trading days old (so their outcome is known)")
                meter("30% movers seen", s.gainers, APEngine.minGainers,
                      help: "Stock-days on the learning days that were followed by a ≥ \(CombiEngine.fmt(threshold))% move")
                meter("Proven combinations", usable, 1,
                      help: "Combinations that also beat chance on later days they were not learned from, and haven't failed live")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live track record").font(.caption).foregroundStyle(.secondary)
                    if let h = s.liveHitRate {
                        Text("\(s.resolved.filter { $0.hit == true }.count) of \(s.resolved.count) came true (\(pct(h)))").font(.callout.bold())
                    } else { Text("none checked yet").font(.callout) }
                    Text("vs \(pct(s.baseRate)) of all stocks (chance)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(phaseText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func meter(_ title: String, _ v: Int, _ need: Int, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ProgressView(value: Double(min(v, need)), total: Double(max(need, 1))).frame(width: 90)
                Text("\(v) / \(need)").font(.callout.monospacedDigit().bold()).foregroundStyle(v >= need ? Color.green : Color.primary)
            }
        }
        .help(help)
    }

    private var phaseText: String {
        switch s.phase {
        case .collecting:
            return (s.note.isEmpty ? "" : s.note + " ") + "AUTO-PREDICT waits until it has at least \(APEngine.minDays) labelled days and \(APEngine.minGainers) real ≥ \(CombiEngine.fmt(threshold))% moves to learn from. Every daily snapshot adds data; it re-learns by itself."
        case .learning:
            return "Enough data to look, but no combination has held up on later days yet — so nothing is predicted (better no prediction than a lucky one). \(s.testMethod)"
        case .active:
            return "Predicts only with combinations that worked on days they never saw. \(s.testMethod) Every prediction is checked 21 trading days later; combinations that keep failing are retired automatically."
        }
    }

    // MARK: Today

    private var todays: [APPrediction] { s.predictions.filter { $0.day == s.lastRunDay } }

    private var today: some View {
        let list = todays
        return Group {
            if list.isEmpty {
                Text(s.phase == .active ? "No stock matches a proven combination on \(s.lastRunDay)." : "No predictions until AUTO-PREDICT is Active.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(list, selection: $selPred) {
                    TableColumn("Symbol") { p in Text(p.symbol).bold() }.width(min: 80, ideal: 100)
                    TableColumn("Chance (≥)") { p in Text(pct(p.chance)).monospacedDigit() }.width(min: 60, ideal: 70)
                    TableColumn("Combos") { p in Text("\(p.rules.count)").monospacedDigit() }.width(min: 45, ideal: 50)
                    TableColumn("Close") { p in Text(p.close.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit() }.width(min: 60, ideal: 70)
                    TableColumn("Best combination") { p in Text(p.rules.first ?? "").lineLimit(1).help(p.rules.joined(separator: "\n")) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Open chart") { open(ids.first, list.map(\.symbol)) }
                    Button("Copy symbols") { copy(list.map(\.symbol)) }
                } primaryAction: { ids in open(ids.first, list.map(\.symbol)) }
            }
        }
    }

    // MARK: Combinations

    private var rulesTable: some View {
        Table(s.rules, selection: $selRule) {
            TableColumn("Status") { r in
                Text(r.retired ? "Retired" : (r.heldUp == true ? "Proven" : (r.heldUp == false ? "Faded later" : "Unchecked")))
                    .foregroundStyle(r.retired ? Color.red : (r.usable ? Color.green : Color.secondary)).font(.caption.bold())
            }.width(min: 70, ideal: 80)
            TableColumn("Combination") { r in Text(r.text).lineLimit(2).help(r.text) }.width(min: 220, ideal: 380)
            TableColumn("Learned on") { r in Text("\(r.trainGainers)/\(r.trainTotal) · \(pct(r.trainHit))").monospacedDigit() }.width(min: 90, ideal: 120)
            TableColumn("Later days") { r in Text(r.testHit.map { "\(r.testGainers)/\(r.testTotal) · \(pct($0))" } ?? "—").monospacedDigit() }.width(min: 90, ideal: 120)
            TableColumn("× chance") { r in Text(r.testLift.map { String(format: "%.1f×", $0) } ?? String(format: "%.1f×", r.lift)).monospacedDigit() }.width(min: 50, ideal: 60)
            TableColumn("Live") { r in Text(r.liveTotal > 0 ? "\(r.liveHits)/\(r.liveTotal)" : "—").monospacedDigit() }.width(min: 45, ideal: 55)
            TableColumn("Today") { r in Text("\(r.todayMatches.count)").monospacedDigit() }.width(min: 40, ideal: 45)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let k = ids.first, let r = s.rules.first(where: { $0.key == k }) {
                Button("Copy combination") { copy([r.text]) }
                if !r.todayMatches.isEmpty { Button("Copy today's matches") { copy(r.todayMatches) } }
            }
        }
    }

    // MARK: Track record

    private var trackRecord: some View {
        let past = s.predictions.filter { $0.day != s.lastRunDay || $0.hit != nil }
        let resolved = past.filter { $0.hit != nil }
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(resolved.count) checked · \(past.count - resolved.count) still inside their 21 trading days")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            Table(past) {
                TableColumn("Day") { p in Text(p.day).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Symbol") { p in Text(p.symbol).bold() }.width(min: 80, ideal: 100)
                TableColumn("Chance (≥)") { p in Text(pct(p.chance)).monospacedDigit() }.width(min: 60, ideal: 70)
                TableColumn("Peak gain in 21d") { p in
                    Text(p.outcome.map { String(format: "%+.1f%%", $0) } ?? "pending").monospacedDigit()
                        .foregroundStyle(p.hit == true ? Color.green : (p.hit == false ? Color.secondary : Color.orange))
                }.width(min: 90, ideal: 110)
                TableColumn("Result") { p in Text(p.hit == nil ? "…" : (p.hit! ? "✓ came true" : "✗")) }.width(min: 70, ideal: 90)
                TableColumn("Combination") { p in Text(p.rules.first ?? "").lineLimit(1).help(p.rules.joined(separator: "\n")) }
            }
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if s.runs.count >= 2 {
                Chart {
                    ForEach(s.runs) { r in
                        LineMark(x: .value("Day", r.day), y: .value("Count", r.rulesUsable)).foregroundStyle(by: .value("Series", "Proven combinations"))
                        LineMark(x: .value("Day", r.day), y: .value("Count", r.labeledDays)).foregroundStyle(by: .value("Series", "Labelled days"))
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 150).padding(.horizontal, 12)
            }
            Table(Array(s.runs.reversed())) {
                TableColumn("Day") { r in Text(r.day).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Labelled days") { r in Text("\(r.labeledDays)").monospacedDigit() }
                TableColumn("30% movers") { r in Text("\(r.gainers)").monospacedDigit() }
                TableColumn("Chance") { r in Text(pct(r.baseRate)).monospacedDigit() }
                TableColumn("Combos found") { r in Text("\(r.rulesFound)").monospacedDigit() }
                TableColumn("Proven") { r in Text("\(r.rulesUsable)").monospacedDigit() }
                TableColumn("Predicted") { r in Text("\(r.predictions)").monospacedDigit() }
                TableColumn("Live hit rate") { r in Text(r.liveHitRate.map { "\(pct($0)) of \(r.liveResolved)" } ?? "—").monospacedDigit() }
            }
        }
    }

    // MARK: Helpers

    private func pct(_ v: Double) -> String { String(format: v < 0.1 ? "%.1f%%" : "%.0f%%", v * 100) }
    private func open(_ s: String?, _ queue: [String]) { if let s { vm.openChart(s, queue: queue, openWindow: openWindow) } }
    private func copy(_ items: [String]) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(items.joined(separator: ", "), forType: .string)
    }
}

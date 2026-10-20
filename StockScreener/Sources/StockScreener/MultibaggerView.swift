import SwiftUI
import Charts

/// Multibaggers: every stock that gained ≥ 30% (your threshold) in a calendar month since Jan 2023,
/// month by month — and a one-click Chart Reel of them with both charts jumped to the move's date.
struct MultibaggerView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var mb = MultibaggerCenter.shared

    @AppStorage("mb.threshold") private var threshold = 30.0
    @AppStorage("mb.from") private var fromMonth = "2023-01"
    @AppStorage("mb.usePeak") private var usePeak = false
    @AppStorage("mb.center") private var centerRaw = MBCenter.start.rawValue
    @AppStorage("mb.scope") private var scope = "Sheet stocks"

    @State private var month: String?          // nil = all months
    @State private var selection: MBEvent.ID?
    @State private var search = ""

    private var shown: [MBEvent] {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        var e = scoped
        if let m = month { e = e.filter { $0.month == m } }
        if !q.isEmpty { e = e.filter { $0.symbol.contains(q) } }
        return e
    }

    private var scoped: [MBEvent] {
        var e = mb.events
        if scope == "Sheet stocks" { let s = Set(vm.allSymbols.map { $0.uppercased() }); e = e.filter { s.contains($0.symbol) } }
        if scope == "My Filter", let l = vm.labelIndex {
            let s = Set(vm.filterRows.map { $0.text(l).trimmingCharacters(in: .whitespaces).uppercased() }); e = e.filter { s.contains($0.symbol) }
        }
        return e
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mb.book.series.isEmpty && !mb.isFetching {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Multibaggers").font(.title2.bold())
                    Text("Downloads ~5 years of Yahoo daily closes for your sheet's \(vm.allSymbols.count) stocks, then lists every stock that gained ≥ \(CombiEngine.fmt(threshold))% in a calendar month from \(MBEngine.monthTitle(fromMonth)) to now. Open them in the Chart Reel with both charts jumped to the move.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 620)
                    Button("Download Yahoo history") { mb.fetch(vm.allSymbols) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    monthList.frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
                    eventTable.frame(minWidth: 620)
                }
            }
        }
        .navigationTitle("Multibaggers")
        .onAppear { mb.loadIfNeeded() }
        .onChange(of: threshold) { _ in mb.recompute() }
        .onChange(of: fromMonth) { _ in mb.recompute() }
        .onChange(of: usePeak) { _ in mb.recompute() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Multibagger = gain ≥").font(.caption)
                TextField("", value: $threshold, format: .number).frame(width: 44).multilineTextAlignment(.trailing)
                Text("% in a calendar month, from").font(.caption)
                Picker("", selection: $fromMonth) {
                    ForEach(["2023-01", "2023-07", "2024-01", "2024-07", "2025-01", "2025-07", "2026-01"], id: \.self) { Text(MBEngine.monthTitle($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                Picker("", selection: $usePeak) {
                    Text("month-end close").tag(false)
                    Text("best close in the month").tag(true)
                }
                .labelsHidden().fixedSize()
                .help("Gain vs the previous month's last close: at the month's last close, or at its highest close")
                Spacer()
                if mb.isFetching {
                    ProgressView(value: Double(mb.progress.done), total: Double(max(1, mb.progress.total))).frame(width: 140)
                    Button("Stop") { mb.cancel() }
                } else {
                    Button { mb.fetch(vm.allSymbols) } label: { Label(mb.book.series.isEmpty ? "Download Yahoo history" : "Update Yahoo", systemImage: "arrow.down.circle") }
                        .help("First time: 5 years per stock. Later: only the last 3 months, merged into what's stored.")
                }
            }
            HStack(spacing: 10) {
                Picker("", selection: $scope) { ForEach(["Sheet stocks", "My Filter", "All downloaded"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("Chart centre:").font(.caption)
                Picker("", selection: $centerRaw) { ForEach(MBCenter.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    .labelsHidden().fixedSize()
                    .help("The date the Chart Reel jumps both TradingView charts to (TradingView's Go to date)")
                SymbolField(vm: vm, placeholder: "Search", text: $search).frame(width: 120)
                Spacer()
                if let s = mb.status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Button { openReel(start: nil) } label: { Label("Chart Reel (both charts)", systemImage: "film.stack") }
                    .buttonStyle(.borderedProminent)
                    .disabled(shown.isEmpty)
                    .help("Flick through these multibaggers — Chart 1 and Chart 2 side by side, each jumped to the move's date")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var monthList: some View {
        let counts = Dictionary(grouping: scoped, by: \.month).mapValues(\.count)
        let months = counts.keys.sorted(by: >)
        return VStack(spacing: 0) {
            Chart {
                ForEach(months.reversed(), id: \.self) { m in
                    BarMark(x: .value("Month", MBEngine.monthTitle(m)), y: .value("Count", counts[m] ?? 0))
                        .foregroundStyle(m == month ? Color.accentColor : Color.green.opacity(0.6))
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 70).padding(8)
            List(selection: $month) {
                Text("All months (\(counts.values.reduce(0, +)))").tag(String?.none)
                ForEach(months, id: \.self) { m in
                    HStack {
                        Text(MBEngine.monthTitle(m))
                        Spacer()
                        Text("\(counts[m] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(String?.some(m))
                }
            }
        }
    }

    private var eventTable: some View {
        let rows = shown
        return VStack(spacing: 0) {
            HStack {
                Text("\(rows.count) multibagger\(rows.count == 1 ? "" : "s")\(month.map { " in " + MBEngine.monthTitle($0) } ?? "")").font(.caption.bold())
                Spacer()
                Text("Double-click: Chart Reel from that stock").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Table(rows, selection: $selection) {
                TableColumn("Symbol") { e in Text(e.symbol).bold() }.width(min: 80, ideal: 100)
                TableColumn("Month") { e in Text(e.monthTitle) }.width(min: 60, ideal: 70)
                TableColumn("Gain") { e in Text(String(format: "%+.0f%%", e.gain)).monospacedDigit().foregroundStyle(.green) }.width(min: 50, ideal: 60)
                TableColumn("Best in month") { e in Text(String(format: "%+.0f%%", e.peakGain)).monospacedDigit() }.width(min: 70, ideal: 80)
                TableColumn("Start") { e in Text(e.startDay).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Crossed \(CombiEngine.fmt(threshold))%") { e in Text(e.crossDay).monospacedDigit() }.width(min: 80, ideal: 95)
                TableColumn("Peak") { e in Text(e.peakDay).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Chart goes to") { e in Text(e.day(for: MBCenter(rawValue: centerRaw) ?? .start)).monospacedDigit().foregroundStyle(.orange) }.width(min: 80, ideal: 95)
            }
            .contextMenu(forSelectionType: MBEvent.ID.self) { ids in
                if let id = ids.first, let e = rows.first(where: { $0.id == id }) {
                    Button("Chart Reel from \(e.symbol)") { openReel(start: e.id) }
                    Button("Copy date \(e.day(for: MBCenter(rawValue: centerRaw) ?? .start))") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.day(for: MBCenter(rawValue: centerRaw) ?? .start), forType: .string)
                    }
                }
            } primaryAction: { ids in openReel(start: ids.first) }
        }
    }

    /// Hands the current list to the Chart Reel (both charts) and opens it.
    private func openReel(start: MBEvent.ID?) {
        let d = UserDefaults.standard
        d.set(ReelSource.multibaggers.rawValue, forKey: "reel.source")
        d.set(month ?? "", forKey: "reel.mbMonth")
        d.set(scope, forKey: "reel.mbScope")
        d.set(start ?? "", forKey: "reel.mbStart")
        let l = ReelLayout(rawValue: d.string(forKey: "reel.layout") ?? "") ?? .chart1
        if l == .chart1 || l == .chart2 { d.set(ReelLayout.side.rawValue, forKey: "reel.layout") }
        openWindow(id: "reel")
    }
}

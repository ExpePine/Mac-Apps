import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

/// Performance pane: pick a column whose value says when an event happened (D_Trigger = days ago),
/// and see how the stocks did from that day, using Yahoo daily closes.
struct PerformanceView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: UUID?
    @State private var showSheetSettings = false
    @State private var sortOrder = [KeyPathComparator(\PerfRow.returnNow, order: .reverse)]
    @State private var horizonsText = ""
    @State private var tableSelection = Set<String>()

    private var index: Int? {
        if let id = selectedID, let i = vm.settings.perfStudies.firstIndex(where: { $0.id == id }) { return i }
        return vm.settings.perfStudies.isEmpty ? nil : 0
    }

    @AppStorage("perfMode") private var mode = 0       // 0 = study, 1 = compare & patterns

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    Text("Study").tag(0)
                    Text("Compare indicators & hidden patterns").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                Spacer()
                Text("\(vm.perfRuns.count) saved run\(vm.perfRuns.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if mode == 1 {
                CompareView()
            } else {
                studyBody
            }
        }
        .navigationTitle("Performance")
        .onAppear { vm.restorePerfResults() }
    }

    private var studyBody: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            if let i = index {
                VStack(spacing: 0) {
                    editor(i)
                    Divider()
                    results(vm.settings.perfStudies[i])
                }
            } else {
                Text("Add a study with +").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showSheetSettings) { ExperimentsSheetSettings().environmentObject(vm) }
        .onAppear {
            if let i = index { horizonsText = vm.settings.perfStudies[i].horizons.map(String.init).joined(separator: ", ") }
        }
        .onChange(of: selectedID) { _ in
            if let i = index { horizonsText = vm.settings.perfStudies[i].horizons.map(String.init).joined(separator: ", ") }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { index.map { vm.settings.perfStudies[$0].id } }, set: { selectedID = $0 })) {
                Section("Studies") {
                    ForEach(vm.settings.perfStudies) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name.isEmpty ? s.column : s.name).lineLimit(1)
                            Text("\(s.column) · \(s.source == .main ? "main" : "experiments")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(s.id)
                        .contextMenu {
                            Button("Duplicate") { duplicate(s) }
                            Button("Delete", role: .destructive) { vm.settings.perfStudies.removeAll { $0.id == s.id } }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }.help("New study")
                    Button { if let i = index { vm.settings.perfStudies.remove(at: i) } } label: { Image(systemName: "minus") }
                        .disabled(index == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                Divider()
                Text("Experiments sheet").font(.caption.bold())
                Text(vm.expTable.headers.isEmpty ? "Not imported" : "\(vm.expTable.rows.count) rows · \(vm.settings.perfImportedColumns.count) columns used")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Sheet & columns…") { showSheetSettings = true }.controlSize(.small)
            }
            .padding(8)
        }
    }

    // MARK: Study editor

    private func editor(_ i: Int) -> some View {
        let study = $vm.settings.perfStudies[i]
        let s = vm.settings.perfStudies[i]
        let sourceColumns = s.source == .main ? vm.headers.filter { $0 != "NN_score" && $0 != "NN_conf" }
                                              : vm.settings.perfImportedColumns.filter { vm.expTable.index(of: $0) != nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Study name", text: study.name).textFieldStyle(.roundedBorder).frame(width: 220)
                    .font(.headline)
                Spacer()
                if vm.perfRunning == s.id {
                    ProgressView(value: Double(vm.perfProgress.0), total: Double(max(1, vm.perfProgress.1))).frame(width: 120)
                    Text(vm.perfStatus ?? "Working…").font(.caption)
                } else if let st = vm.perfStatus {
                    Text(st).font(.caption).foregroundStyle(.orange)
                }
                Button { vm.runStudy(s) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(vm.perfRunning != nil || !vm.hasData)
                    .help("Fetches any missing Yahoo prices, then calculates (⌘R)")
            }
            HStack(spacing: 10) {
                Picker("Column", selection: study.source) {
                    ForEach(PerfStudy.Source.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 260)
                Picker("", selection: study.column) {
                    if !sourceColumns.contains(s.column) { Text(s.column.isEmpty ? "Pick a column" : "\(s.column) (missing)").tag(s.column) }
                    ForEach(sourceColumns, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 180)
                Picker("Value means", selection: study.unit) {
                    ForEach(PerfStudy.Unit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 260)
                .help("D_Trigger = 100 means the event was 100 trading days (or calendar days) before the sheet's data day")
            }
            HStack(spacing: 10) {
                Text("Rose significantly =").font(.callout)
                TextField("20", value: study.successPercent, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                Text("% from the event close").font(.callout).foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Text("Horizons").font(.callout)
                TextField("5, 10, 21, 50, 100", text: $horizonsText).textFieldStyle(.roundedBorder).frame(width: 140)
                    .onSubmit {
                        let h = horizonsText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { $0 > 0 }
                        if !h.isEmpty { vm.settings.perfStudies[i].horizons = Array(Set(h)).sorted() }
                    }
                    .help("Trading days after the event — press Return to apply")
                Text("days").font(.callout).foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Text("Ignore events newer than").font(.callout)
                TextField("0", value: study.minDaysAgo, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                Text("days").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Picker("Stocks", selection: study.scope) {
                    ForEach(PerfStudy.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 280)
                Picker("Compare groups by", selection: study.splitBy) {
                    Text("— none —").tag("")
                    ForEach(vm.perfColumnChoices, id: \.key) { Text($0.title).tag($0.key) }
                    if !s.splitBy.isEmpty && !vm.perfColumnChoices.contains(where: { $0.key == s.splitBy }) {
                        Text("\(s.splitBy) (missing)").tag(s.splitBy)
                    }
                }
                .frame(width: 330)
                .help("Numbers are split into Low / Mid / High thirds; text by value")
            }
        }
        .padding(12)
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ study: PerfStudy) -> some View {
        if let r = vm.perfResults[study.id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary(r, study)
                    AdvancedPerfPanel(rows: r.rows, path: r.avgPath)
                    if !r.horizonStats.isEmpty || !r.avgPath.isEmpty {
                        HStack(alignment: .top, spacing: 16) {
                            horizonTable(r).frame(width: 330)
                            pathChart(r, study).frame(minWidth: 320, minHeight: 220)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        if !r.histogram.isEmpty { histogram(r).frame(minWidth: 320, minHeight: 200) }
                        if !r.groups.isEmpty { groupTable(r, study).frame(minWidth: 380) }
                    }
                    stockTable(r, study).frame(minHeight: 360)
                    if !r.skipped.isEmpty {
                        DisclosureGroup("\(r.skipped.count) stocks skipped") {
                            Text(r.skipped.prefix(200).map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                    Text("Entry = Yahoo close on the event day; returns run to the latest Yahoo close. Days are counted back from the main sheet's data day (\(r.refDay)). Yahoo is an unofficial source; past performance is not a forecast or financial advice.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Pick a column (e.g. D_Trigger) and click Run").font(.title3)
                Text("Each stock's value says how many days ago the event happened. The app finds that day in Yahoo's price history and measures what the stock did after it: return to today, best rise and when, worst fall, whether and how fast it reached your “rose significantly” %, and the same versus the Nifty 50.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ r: PerfResult, _ s: PerfStudy) -> some View {
        HStack(spacing: 22) {
            stat("Stocks", "\(r.count)", .primary)
            stat("Avg return", pct(r.avgReturn), color(r.avgReturn), note: "median " + pct(r.medianReturn))
            stat("Up now", r.winRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—", .primary)
            stat("Avg best rise", pct(r.avgPeak), .green,
                 note: r.avgDaysToPeak.map { String(format: "avg %.0f trading days after trigger (median %.0f)", $0, r.medianDaysToPeak ?? 0) } ?? "")
            stat("Reached +\(fmt(s.successPercent))%", r.hitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—", .blue,
                 note: r.medianDaysToHit.map { "median \(Int($0)) trading days" } ?? "")
            stat("vs Nifty 50", r.avgExcess.map { String(format: "%+.1f pts", $0) } ?? "—", color(r.avgExcess),
                 note: "avg, same dates")
        }
    }

    private func horizonTable(_ r: PerfResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("After the event").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Days").gridColumnAlignment(.leading); Text("Stocks"); Text("Average"); Text("Median"); Text("Up")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(r.horizonStats, id: \.days) { h in
                    GridRow {
                        Text("+\(h.days)").gridColumnAlignment(.leading)
                        Text("\(h.count)").foregroundStyle(.secondary)
                        Text(pct(h.avg)).foregroundStyle(color(h.avg)).fontWeight(.semibold)
                        Text(pct(h.median)).foregroundStyle(color(h.median))
                        Text(String(format: "%.0f%%", h.winRate * 100))
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func pathChart(_ r: PerfResult, _ s: PerfStudy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Average move after the event").font(.headline)
            Chart {
                ForEach(r.avgPath, id: \.day) { p in
                    LineMark(x: .value("Trading days after event", p.day), y: .value("%", p.mean), series: .value("", "Average"))
                        .foregroundStyle(.blue)
                    LineMark(x: .value("Trading days after event", p.day), y: .value("%", p.median), series: .value("", "Median"))
                        .foregroundStyle(.orange)
                }
                RuleMark(y: .value("Target", s.successPercent)).foregroundStyle(.green.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.5))
            }
            .chartXAxisLabel("Trading days after the event")
            .chartYAxisLabel("% from event close")
            HStack(spacing: 12) {
                legend(.blue, "Average"); legend(.orange, "Median"); legend(.green, "+\(fmt(s.successPercent))% target")
                Spacer()
                Text("Only days with ≥ 3 stocks").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func histogram(_ r: PerfResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Return since the event").font(.headline)
            Chart(r.histogram, id: \.from) { b in
                BarMark(x: .value("Return", "\(Int(b.from))…\(Int(b.to))%"), y: .value("Stocks", b.count))
                    .foregroundStyle(b.from >= 0 ? Color.green.opacity(0.75) : Color.red.opacity(0.75))
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 8)) } }
            Text("Returns are clipped to −50% … +200%").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func groupTable(_ r: PerfResult, _ s: PerfStudy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By \(s.splitBy.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "")").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Group").gridColumnAlignment(.leading); Text("Stocks"); Text("Avg"); Text("Median"); Text("Best rise")
                    Text("Hit +\(fmt(s.successPercent))%"); Text("Days to hit")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(r.groups) { g in
                    GridRow {
                        Text(g.name).gridColumnAlignment(.leading).lineLimit(1)
                        Text("\(g.count)").foregroundStyle(.secondary)
                        Text(pct(g.avgReturn)).foregroundStyle(color(g.avgReturn)).fontWeight(.semibold)
                        Text(pct(g.medianReturn)).foregroundStyle(color(g.medianReturn))
                        Text(pct(g.avgPeak)).foregroundStyle(.green)
                        Text(String(format: "%.0f%%", g.hitRate * 100))
                        Text(g.medianDaysToHit.map { "\(Int($0))" } ?? "—").foregroundStyle(.secondary)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("Small groups (a few stocks) can look extreme by chance.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func stockTable(_ r: PerfResult, _ s: PerfStudy) -> some View {
        let rows = r.rows.sorted(using: sortOrder)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stocks").font(.headline)
                Spacer()
                Menu("Copy / Export") {
                    Button("Copy table (tab-separated)") { copy(tsv(rows, s)) }
                    Button("Export CSV…") { export(rows, s) }
                    Divider()
                    ForEach(vm.watchlists) { list in
                        Button("Add \(tableSelection.isEmpty ? "all \(rows.count)" : "\(tableSelection.count) selected") to “\(list.name)”") {
                            let syms = tableSelection.isEmpty ? rows.map(\.symbol) : rows.map(\.symbol).filter { tableSelection.contains($0) }
                            vm.addSymbols(syms, listID: list.id)
                        }
                    }
                }
                .fixedSize()
            }
            Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
                TableColumn("Symbol", value: \.symbol) { Text($0.symbol).fontWeight(.semibold) }.width(min: 80, ideal: 100)
                TableColumn("\(s.column)", value: \.tradingDaysSince) { row in
                    Text("\(row.value)").help("Event day \(row.eventDay) · \(row.tradingDaysSince) trading days ago")
                }
                .width(70)
                TableColumn("Event day", value: \.eventDay) { Text($0.eventDay).monospacedDigit() }.width(85)
                TableColumn("Entry → Now", value: \.now) { row in
                    Text("\(fmt(row.entry)) → \(fmt(row.now))").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(120)
                TableColumn("Return", value: \.returnNow) { row in Text(pct(row.returnNow)).monospacedDigit().fontWeight(.semibold).foregroundStyle(color(row.returnNow)) }
                    .width(70)
                TableColumn("Best rise", value: \.peak) { row in
                    Text("\(pct(row.peak)) @\(row.daysToPeak)d").monospacedDigit().foregroundStyle(.green)
                        .help("Highest close after the event, \(row.daysToPeak) trading days after it")
                }
                .width(110)
                TableColumn("Worst", value: \.worst) { row in Text(pct(row.worst)).monospacedDigit().foregroundStyle(.red) }.width(65)
                TableColumn("Hit +\(fmt(s.successPercent))%", value: \.hitSort) { row in
                    Text(row.hitDays.map { "in \($0)d" } ?? "—").monospacedDigit().foregroundStyle(row.hitDays == nil ? Color.secondary : Color.blue)
                }
                .width(75)
                TableColumn("vs Nifty", value: \.excessSort) { row in
                    Text(row.excess.map { String(format: "%+.1f", $0) } ?? "—").monospacedDigit().foregroundStyle(color(row.excess))
                }
                .width(65)
                TableColumn("Group", value: \.group) { Text($0.group).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                ForEach(vm.watchlists) { list in
                    Button("Add \(ids.count) to “\(list.name)”") { vm.addSymbols(Array(ids), listID: list.id) }
                }
                Button("Open chart") { if let s = ids.first { vm.openChart(s, queue: rows.map(\.symbol), openWindow: openWindow) } }.disabled(ids.count != 1)
                Button("Screenshots…") { if let s = ids.first { vm.shotSymbol = s; openWindow(id: "shots") } }.disabled(ids.count != 1)
                Button("Copy symbols") { copy(ids.sorted().joined(separator: "\n")) }
            }
        }
    }

    // MARK: Helpers

    private func add() {
        var s = PerfStudy()
        s.column = vm.settings.triggerColumn
        s.name = "\(s.column) performance"
        vm.settings.perfStudies.append(s)
        selectedID = s.id
    }

    private func duplicate(_ s: PerfStudy) {
        var c = s
        c.id = UUID(); c.name += " copy"
        vm.settings.perfStudies.append(c)
        selectedID = c.id
    }

    private func stat(_ title: String, _ value: String, _ color: Color, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 12, height: 3); Text(t).font(.caption2) }
    }

    private func pct(_ v: Double?) -> String { v.map { String(format: "%+.1f%%", $0) } ?? "—" }
    private func color(_ v: Double?) -> Color { v.map { $0 >= 0 ? Color.green : Color.red } ?? .secondary }
    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func tsv(_ rows: [PerfRow], _ s: PerfStudy, sep: String = "\t") -> String {
        let head = ["Symbol", s.column, "Event day", "Trading days since", "Entry", "Now", "Return %", "Best rise %", "Days to best",
                    "Worst %", "Days to +\(fmt(s.successPercent))%", "Nifty %", "Group"] + s.horizons.map { "+\($0)d %" }
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        let lines = rows.map { r in
            ([r.symbol, r.value, r.eventDay, "\(r.tradingDaysSince)", f(r.entry), f(r.now), f(r.returnNow), f(r.peak), "\(r.daysToPeak)",
              f(r.worst), r.hitDays.map(String.init) ?? "", f(r.benchmark), r.group.replacingOccurrences(of: sep, with: " ")]
             + r.horizons.map(f)).joined(separator: sep)
        }
        return ([head.joined(separator: sep)] + lines).joined(separator: "\n")
    }

    private func export(_ rows: [PerfRow], _ s: PerfStudy) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(s.name.isEmpty ? s.column : s.name).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? tsv(rows, s, sep: ",").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension PerfRow {
    private static let missing = -Double.greatestFiniteMagnitude
    var hitSort: Int { hitDays ?? Int.max }
    var excessSort: Double { excess ?? Self.missing }
}

/// Experiments sheet: link, stock-name column, and which of its columns the Performance pane can use.
struct ExperimentsSheetSettings: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Experiments sheet").font(.title3.bold())
            Text("A second Google Sheet with your performance experiments. Share it as “Anyone with the link can view” (or File → Share → Publish to web) and paste the link — a specific tab's link works too. Rows are matched to stocks by the stock-name column.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("https://docs.google.com/spreadsheets/d/…", text: $link).textFieldStyle(.roundedBorder)
                Button(vm.expTable.headers.isEmpty ? "Import" : "Re-import") {
                    vm.settings.perfSheetLink = link
                    vm.importExperimentsSheet()
                }
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || vm.isLoadingExp)
                if vm.isLoadingExp { ProgressView().controlSize(.small) }
            }
            if let st = vm.expStatus { Text(st).font(.caption).foregroundStyle(.secondary) }

            if !vm.expTable.headers.isEmpty {
                Picker("Stock name column", selection: $vm.settings.perfSymbolColumn) {
                    Text("Auto (\(vm.expSymbolIndex.map { vm.expTable.headers[$0] } ?? "first column"))").tag("")
                    ForEach(vm.expTable.headers, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 360)
                HStack {
                    Text("Columns to use in Performance").font(.headline)
                    Spacer()
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                    Button("All") { vm.settings.perfImportedColumns = vm.expTable.headers }
                    Button("None") { vm.settings.perfImportedColumns = [] }
                }
                List {
                    ForEach(vm.expTable.headers.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { h in
                        Toggle(isOn: Binding(
                            get: { vm.settings.perfImportedColumns.contains(h) },
                            set: { on in
                                if on { vm.settings.perfImportedColumns.append(h) } else { vm.settings.perfImportedColumns.removeAll { $0 == h } }
                            })) {
                            HStack {
                                Text(h)
                                Spacer()
                                Text(sample(h)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                Spacer()
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 560)
        .onAppear { link = vm.settings.perfSheetLink }
    }

    private func sample(_ h: String) -> String {
        guard let c = vm.expTable.index(of: h) else { return "" }
        return vm.expTable.rows.lazy.map { $0.text(c) }.filter { !$0.isEmpty }.prefix(3).joined(separator: ", ")
    }
}

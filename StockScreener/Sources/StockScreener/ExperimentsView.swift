import SwiftUI
import Charts

/// Experiments: add a sheet of your own experiments, say in plain words what the columns mean and what to compare;
/// the app (with Groq for reading your words) works out a plan, measures every trigger on Yahoo prices and tells you
/// which one did better.
@MainActor final class ExperimentCenter: ObservableObject {
    static let shared = ExperimentCenter()
    @Published var experiments: [Experiment] = ExperimentFile.load() { didSet { ExperimentFile.save(experiments) } }
    @Published var tables: [UUID: SheetTable] = [:]
    @Published var results: [UUID: ExpResult] = [:]
    @Published var busy: [UUID: String] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var prices = PriceBook()

    func importSheet(_ id: UUID) {
        guard let e = experiments.first(where: { $0.id == id }), let url = SheetService.csvURL(from: e.link) else {
            errors[id] = "Paste the sheet's link first (shared as “Anyone with the link can view”)."; return
        }
        busy[id] = "Downloading the sheet…"; errors[id] = nil
        Task {
            do {
                let r = try await SheetService.fetch(from: url)
                tables[id] = r.table
            } catch { errors[id] = "Couldn't download: \(error.localizedDescription)" }
            busy[id] = nil
        }
    }

    func makePlan(_ id: UUID, model: String) {
        guard let i = experiments.firstIndex(where: { $0.id == id }), let t = tables[id] else { errors[id] = "Import the sheet first."; return }
        let text = experiments[i].instructions
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errors[id] = "Write what the columns mean and what to compare."; return }
        errors[id] = nil
        if model.isEmpty || GroqClient.apiKey.isEmpty {
            experiments[i].plan = ExperimentEngine.guessPlan(text, table: t)
            experiments[i].plan.explanation += " (Groq isn't set up — add a key and model in Daily Gainers → News & AI settings for a smarter read.)"
            return
        }
        busy[id] = "Groq is reading your instructions…"
        Task {
            do {
                let p = try await ExperimentEngine.groqPlan(text, table: t, model: model)
                if let k = experiments.firstIndex(where: { $0.id == id }) { experiments[k].plan = p }
            } catch {
                errors[id] = "Groq: \(error.localizedDescription) — used a simple reading instead."
                if let k = experiments.firstIndex(where: { $0.id == id }) { experiments[k].plan = ExperimentEngine.guessPlan(text, table: t) }
            }
            busy[id] = nil
        }
    }

    func run(_ id: UUID, base: PriceBook) {
        guard let e = experiments.first(where: { $0.id == id }), let t = tables[id] else { errors[id] = "Import the sheet first."; return }
        let issues = ExperimentEngine.problems(e.plan, table: t)
        guard issues.filter({ !$0.contains("Date column") }).isEmpty || !e.plan.triggers.isEmpty else { errors[id] = issues.joined(separator: " · "); return }
        errors[id] = nil
        // Prices: what the app already has (1 year + multibagger history) plus Yahoo for anything missing
        var book = prices
        for (k, v) in base.series where book.series[k] == nil { book.series[k] = v }
        for (k, v) in MultibaggerCenter.shared.book.series where (book.series[k]?.days.count ?? 0) < v.days.count { book.series[k] = v }
        let need = ExperimentEngine.symbols(e.plan, table: t).filter { (book.series[$0]?.days.count ?? 0) < 400 }
        busy[id] = need.isEmpty ? "Measuring…" : "Yahoo prices for \(need.count) stocks…"
        Task {
            if !need.isEmpty {
                let (got, _) = await YahooClient.fetchAll(need, range: "5y") { _, _ in }
                for (k, v) in got.series { book.series[k] = v }
                prices = book
            }
            let plan = e.plan
            let r = await Task.detached(priority: .userInitiated) { ExperimentEngine.run(plan, table: t, prices: book) }.value
            results[id] = r
            busy[id] = nil
        }
    }

    func summarize(_ id: UUID, model: String) {
        guard let i = experiments.firstIndex(where: { $0.id == id }), let r = results[id] else { return }
        guard !model.isEmpty, !GroqClient.apiKey.isEmpty else { errors[id] = "Groq isn't set up (Daily Gainers → News & AI settings)."; return }
        let plan = experiments[i].plan, text = experiments[i].instructions
        busy[id] = "Groq is writing the conclusion…"
        Task {
            do {
                let s = try await ExperimentEngine.groqSummary(r, plan: plan, instructions: text, model: model)
                if let k = experiments.firstIndex(where: { $0.id == id }) { experiments[k].summary = s }
            } catch { errors[id] = "Groq: \(error.localizedDescription)" }
            busy[id] = nil
        }
    }
}

struct ExperimentsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var ec = ExperimentCenter.shared
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(ec.experiments) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).font(.headline)
                        Text(e.instructions.isEmpty ? "No instructions yet" : e.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(e.id)
                    .contextMenu { Button("Delete", role: .destructive) { ec.experiments.removeAll { $0.id == e.id } } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { let e = Experiment(); ec.experiments.append(e); selected = e.id } label: { Label("New experiment", systemImage: "plus") }
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            if let id = selected, let i = ec.experiments.firstIndex(where: { $0.id == id }) {
                ExperimentDetail(exp: $ec.experiments[i]).environmentObject(vm)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "flask").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Experiments").font(.title2.bold())
                    Text("Add a Google Sheet with your experiment, then write e.g. “COL A is the shortlist trigger — the NSE symbol is shortlisted; COL B and COL C are timing triggers — compare which of COL B or COL C does better.” The app works out the plan, measures both on Yahoo prices and tells you which is better.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
                    Button("New experiment") { let e = Experiment(); ec.experiments.append(e); selected = e.id }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Experiments")
        .onAppear { if selected == nil { selected = ec.experiments.first?.id } }
    }
}

struct ExperimentDetail: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var ec = ExperimentCenter.shared
    @Binding var exp: Experiment
    @State private var showEntries = false

    private var table: SheetTable? { ec.tables[exp.id] }
    private var result: ExpResult? { ec.results[exp.id] }
    private var headers: [String] { table?.headers ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Name", text: $exp.name).font(.title2.bold()).textFieldStyle(.plain)
                    Spacer()
                    if let b = ec.busy[exp.id] { ProgressView().controlSize(.small); Text(b).font(.caption).foregroundStyle(.secondary) }
                }
                if let e = ec.errors[exp.id] { Text(e).font(.caption).foregroundStyle(.orange) }

                // 1. Sheet
                section("1 · Experiment sheet") {
                    HStack {
                        TextField("Google Sheet link (Anyone with the link can view)", text: $exp.link).textFieldStyle(.roundedBorder)
                        Button(table == nil ? "Import" : "Re-import") { ec.importSheet(exp.id) }.disabled(exp.link.isEmpty)
                    }
                    if let t = table {
                        Text("\(t.rows.count) rows · columns: " + t.headers.enumerated().map { "\(ExperimentEngine.columnLetter($0)) \($1)" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        SheetTableView(headers: t.headers, originalHeaders: t.originalHeaders, columns: Array(t.headers.indices),
                                       rows: Array(t.rows.prefix(200)), version: t.rows.count)
                            .frame(height: 160)
                    }
                }

                // 2. Instructions
                section("2 · What to work out (plain words)") {
                    TextEditor(text: $exp.instructions)
                        .font(.body).frame(minHeight: 70)
                        .overlay(alignment: .topLeading) {
                            if exp.instructions.isEmpty {
                                Text("e.g. COL A is the shortlist trigger — here the NSE symbol is shortlisted. COL B and COL C are timing triggers — compare which of COL B or COL C does better.")
                                    .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Button { ec.makePlan(exp.id, model: vm.settings.groqModel) } label: { Label("Work out the plan", systemImage: "sparkles") }
                            .buttonStyle(.borderedProminent).disabled(table == nil)
                            .help("Groq reads your words and the sheet's columns and proposes a plan — you can change it below")
                        Text("Groq only decides which column means what; the numbers are computed by the app.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // 3. Plan
                if table != nil { planEditor }

                // 4. Results
                if let r = result { results(r) }
            }
            .padding(16)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            c()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func columnPicker(_ title: String, _ sel: Binding<String>, allowNone: Bool = false) -> some View {
        Picker(title, selection: sel) {
            if allowNone { Text("—").tag("") }
            ForEach(Array(headers.enumerated()), id: \.offset) { i, h in Text("\(ExperimentEngine.columnLetter(i)) · \(h)").tag(h) }
        }
        .frame(width: 280)
    }

    private var planEditor: some View {
        section("3 · Plan (check it)") {
            if !exp.plan.explanation.isEmpty { Text(exp.plan.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { Text("NSE symbol in").font(.caption); columnPicker("", $exp.plan.symbolColumn) }
                GridRow {
                    Text("Shortlist").font(.caption)
                    HStack {
                        columnPicker("", $exp.plan.shortlistColumn)
                        Picker("", selection: $exp.plan.shortlistKind) {
                            Text("non-empty / 1 = shortlisted").tag("flag")
                            Text("cell is the shortlist date").tag("date")
                            Text("the column is the symbol (every row)").tag("symbol")
                        }.labelsHidden().fixedSize()
                    }
                }
                GridRow { Text("Row date (optional)").font(.caption); columnPicker("", $exp.plan.baseDateColumn, allowNone: true) }
            }
            Text("Timing triggers to compare").font(.caption.bold()).padding(.top, 4)
            ForEach($exp.plan.triggers) { $t in
                HStack {
                    columnPicker("", $t.column)
                    Picker("", selection: $t.kind) {
                        Text("cell = trigger date").tag("date")
                        Text("non-empty / 1 = triggered (on the row / shortlist date)").tag("flag")
                        Text("cell = entry price (on the row / shortlist date)").tag("price")
                    }.labelsHidden().fixedSize()
                    TextField("label", text: $t.label).frame(width: 110).textFieldStyle(.roundedBorder)
                    Button { exp.plan.triggers.removeAll { $0.id == t.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                Button { exp.plan.triggers.append(ExpTrigger(column: headers.first ?? "")) } label: { Label("Add trigger", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Measure after").font(.caption)
                TextField("", text: Binding(get: { exp.plan.horizons.map(String.init).joined(separator: ", ") },
                                            set: { exp.plan.horizons = $0.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { (1...250).contains($0) } }))
                    .frame(width: 90).textFieldStyle(.roundedBorder)
                Text("trading days · hit ≥").font(.caption)
                TextField("", value: $exp.plan.winPercent, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                Text("%").font(.caption)
                Button { ec.run(exp.id, base: vm.priceBook) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(exp.plan.triggers.isEmpty)
            }
            let issues = table.map { ExperimentEngine.problems(exp.plan, table: $0) } ?? []
            if !issues.isEmpty { Text(issues.joined(separator: " · ")).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func results(_ r: ExpResult) -> some View {
        let hs = exp.plan.horizons
        let mid = max(0, hs.count / 2)
        let best = r.best(horizonIndex: mid)
        return section("4 · Results") {
            Text("\(r.shortlisted) shortlisted rows · \(r.entries.count) entries measured" + (r.missingPrices.isEmpty ? "" : " · no Yahoo prices for \(r.missingPrices.count) (e.g. \(r.missingPrices.prefix(4).joined(separator: ", ")))"))
                .font(.caption).foregroundStyle(.secondary)
            if let best, hs.indices.contains(mid) {
                Label("Better after \(hs[mid]) trading days: \(best)", systemImage: "trophy.fill").font(.title3.bold()).foregroundStyle(.green)
            }
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Trigger").gridColumnAlignment(.leading)
                    Text("Entries")
                    ForEach(hs, id: \.self) { h in Text("\(h)d mean / median") }
                    ForEach(hs, id: \.self) { h in Text("\(h)d win · hit") }
                    Text("Days after shortlist")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(r.stats) { s in
                    GridRow {
                        Text(s.name).bold().foregroundStyle(s.name == best ? Color.green : Color.primary)
                        Text("\(s.triggered)").monospacedDigit()
                        ForEach(hs.indices, id: \.self) { k in
                            Text("\(pct(s.mean[k])) / \(pct(s.median[k]))").monospacedDigit().foregroundStyle((s.mean[k] ?? 0) >= 0 ? Color.green : Color.red)
                        }
                        ForEach(hs.indices, id: \.self) { k in Text("\(ExperimentEngine.f(s.winRate[k]))% · \(ExperimentEngine.f(s.hitRate[k]))%").monospacedDigit() }
                        Text(s.meanDaysAfterShortlist.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                    }
                }
            }
            .font(.callout)
            Chart {
                ForEach(r.stats) { s in
                    ForEach(hs.indices, id: \.self) { k in
                        if let m = s.mean[k] {
                            BarMark(x: .value("Horizon", "\(hs[k])d"), y: .value("Mean %", m)).foregroundStyle(by: .value("Trigger", s.name)).position(by: .value("Trigger", s.name))
                        }
                    }
                }
            }
            .frame(height: 170)
            ForEach(r.headToHead, id: \.a) { h in
                Text("Head to head after \(h.horizon)d, on \(h.pairs) rows where both fired: \(h.a) better \(h.aWins)×, \(h.b) better \(h.bWins)×"
                     + (h.pValue.map { String(format: " · could be luck: p = %.3f%@", $0, $0 < 0.05 ? " (unlikely luck)" : " (could easily be luck)") } ?? "")
                     + " · fired first: \(h.a) \(h.aEarlier)×, \(h.b) \(h.bEarlier)×")
                    .font(.callout)
            }
            if r.entries.count < 30 {
                Label("Fewer than 30 entries — treat any winner as a hint, not a result.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button { ec.summarize(exp.id, model: vm.settings.groqModel) } label: { Label("Conclusion (Groq)", systemImage: "text.bubble") }
                Button(showEntries ? "Hide entries" : "Show every entry (\(r.entries.count))") { showEntries.toggle() }
            }
            if !exp.summary.isEmpty {
                Text(exp.summary).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            if showEntries {
                Table(r.entries) {
                    TableColumn("Symbol") { e in Text(e.symbol).bold() }.width(min: 80, ideal: 100)
                    TableColumn("Trigger") { e in Text(e.trigger) }.width(min: 70, ideal: 90)
                    TableColumn("Entry day") { e in Text(e.day).monospacedDigit() }.width(min: 80, ideal: 90)
                    TableColumn("Entry") { e in Text(String(format: "%.2f", e.entry)).monospacedDigit() }.width(min: 55, ideal: 65)
                    TableColumn("Returns") { e in
                        Text(zip(hs, e.returns).map { "\($0)d \(pct($1))" }.joined(separator: " · ")).monospacedDigit()
                    }.width(min: 160, ideal: 220)
                    TableColumn("Worst") { e in Text(pct(e.worst.last ?? nil)).monospacedDigit().foregroundStyle(.red) }.width(min: 50, ideal: 60)
                }
                .frame(height: 260)
            }
        }
    }

    private func pct(_ v: Double?) -> String { v.map { String(format: "%+.1f%%", $0) } ?? "—" }
}

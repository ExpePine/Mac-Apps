import SwiftUI
import Charts

/// Experiments: one sheet of your experimental data, and as many plain-English commands as you like. Each command
/// becomes a plan (Groq or a simple built-in reader), the app computes the numbers, and Groq can write a conclusion.
@MainActor final class ExperimentCenter: ObservableObject {
    static let shared = ExperimentCenter()
    @Published var experiments: [Experiment] = ExperimentFile.load() { didSet { ExperimentFile.save(experiments) } }
    @Published var tables: [UUID: SheetTable] = [:]
    @Published var results: [UUID: ExpResult] = [:]          // per command
    @Published var busy: [UUID: String] = [:]                 // per experiment or command
    @Published var errors: [UUID: String] = [:]
    var prices = PriceBook()

    func importSheet(_ id: UUID) {
        guard let e = experiments.first(where: { $0.id == id }), let url = SheetService.csvURL(from: e.link) else {
            errors[id] = "Paste the sheet's link first (shared as “Anyone with the link can view”)."; return
        }
        busy[id] = "Downloading the sheet…"; errors[id] = nil
        Task {
            do { tables[id] = try await SheetService.fetch(from: url).table } catch { errors[id] = "Couldn't download: \(error.localizedDescription)" }
            busy[id] = nil
        }
    }

    private func index(_ exp: UUID) -> Int? { experiments.firstIndex { $0.id == exp } }

    /// New command: plan it (Groq if set up), then run it.
    func ask(_ exp: UUID, text: String, model: String, base: PriceBook) {
        guard let i = index(exp), let t = tables[exp] else { errors[exp] = "Import the sheet first."; return }
        let cmd = ExpCommand(text: text)
        let history = experiments[i].commands
        let notes = experiments[i].notes
        let prev = history.last?.plan
        experiments[i].commands.append(cmd)
        let cid = cmd.id
        if model.isEmpty || GroqClient.apiKey.isEmpty {
            var p = ExperimentEngine.guessPlan(text, notes: notes, table: t, previous: prev)
            p.explanation += " (Groq isn't set up — Daily Gainers → News & AI settings — for a smarter read of any command.)"
            update(exp, cid) { $0.plan = p }
            run(exp, cid, base: base)
            return
        }
        busy[cid] = "Groq is reading the command…"
        Task {
            do {
                let p = try await ExperimentEngine.groqPlan(text, notes: notes, history: history, table: t, model: model)
                update(exp, cid) { $0.plan = p }
            } catch {
                errors[cid] = "Groq: \(error.localizedDescription) — used a simple reading instead."
                update(exp, cid) { $0.plan = ExperimentEngine.guessPlan(text, notes: notes, table: t, previous: prev) }
            }
            busy[cid] = nil
            run(exp, cid, base: base)
        }
    }

    func update(_ exp: UUID, _ cid: UUID, _ change: (inout ExpCommand) -> Void) {
        guard let i = index(exp), let k = experiments[i].commands.firstIndex(where: { $0.id == cid }) else { return }
        change(&experiments[i].commands[k])
    }

    func run(_ exp: UUID, _ cid: UUID, base: PriceBook) {
        guard let i = index(exp), let cmd = experiments[i].commands.first(where: { $0.id == cid }), let t = tables[exp] else {
            errors[cid] = "Import the sheet first."; return
        }
        errors[cid] = nil
        let plan = cmd.plan
        var book = prices
        for (k, v) in base.series where book.series[k] == nil { book.series[k] = v }
        for (k, v) in MultibaggerCenter.shared.book.series where (book.series[k]?.days.count ?? 0) < v.days.count { book.series[k] = v }
        let need = ExperimentEngine.needsPrices(plan) ? ExperimentEngine.symbols(plan, table: t).filter { (book.series[$0]?.days.count ?? 0) < 400 } : []
        busy[cid] = need.isEmpty ? "Computing…" : "Yahoo prices for \(need.count) stocks…"
        let calendar = DeliveryCenter.shared.calendar
        let start = book
        Task {
            var b = start
            if !need.isEmpty {
                let (got, _) = await YahooClient.fetchAll(need, range: "5y") { _, _ in }
                for (k, v) in got.series { b.series[k] = v }
                prices = b
            }
            let ready = b
            let r = await Task.detached(priority: .userInitiated) { ExperimentEngine.run(plan, table: t, prices: ready, calendar: calendar) }.value
            results[cid] = r
            busy[cid] = nil
        }
    }

    func summarize(_ exp: UUID, _ cid: UUID, model: String) {
        guard let i = index(exp), let cmd = experiments[i].commands.first(where: { $0.id == cid }), let r = results[cid] else { return }
        guard !model.isEmpty, !GroqClient.apiKey.isEmpty else { errors[cid] = "Groq isn't set up (Daily Gainers → News & AI settings)."; return }
        let notes = experiments[i].notes
        busy[cid] = "Groq is writing the conclusion…"
        Task {
            do {
                let s = try await ExperimentEngine.groqSummary(r, command: cmd.text, notes: notes, model: model)
                update(exp, cid) { $0.summary = s }
            } catch { errors[cid] = "Groq: \(error.localizedDescription)" }
            busy[cid] = nil
        }
    }
}

struct ExperimentsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var ec = ExperimentCenter.shared
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(ec.experiments) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).font(.headline)
                        Text("\(e.commands.count) command\(e.commands.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(e.id)
                    .contextMenu { Button("Delete", role: .destructive) { ec.experiments.removeAll { $0.id == e.id } } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack { Button { let e = Experiment(); ec.experiments.append(e); selected = e.id } label: { Label("New experiment", systemImage: "plus") }; Spacer() }
                    .padding(8)
            }
            .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)

            if let id = selected, let i = ec.experiments.firstIndex(where: { $0.id == id }) {
                ExperimentDetail(exp: $ec.experiments[i]).environmentObject(vm)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "flask").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Experiments").font(.title2.bold())
                    Text("Add a Google Sheet of your experiment, then give it any commands in plain words — compare timing triggers, days between two columns, results per sector, whether a higher value means better returns… Each command gets its own plan, numbers and conclusion.")
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
    @ObservedObject private var ec = ExperimentCenter.shared
    @Binding var exp: Experiment
    @State private var command = ""

    private var table: SheetTable? { ec.tables[exp.id] }

    static let examples = [
        "COL B and COL C are timing triggers — compare which does better",
        "Same, but only rows where D_Trigger = 1",
        "Compare per sector",
        "How many trading days from COL A to COL B?",
        "Does a higher COL D mean better returns after 10 days?",
        "Compare with a 15% target and 7% stop, entering the next day",
        "Describe COL D and COL E",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            TextField("Name", text: $exp.name).font(.title2.bold()).textFieldStyle(.plain)
                            Spacer()
                            if let b = ec.busy[exp.id] { ProgressView().controlSize(.small); Text(b).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let e = ec.errors[exp.id] { Text(e).font(.caption).foregroundStyle(.orange) }
                        box("Experiment sheet") {
                            HStack {
                                TextField("Google Sheet link (Anyone with the link can view)", text: $exp.link).textFieldStyle(.roundedBorder)
                                Button(table == nil ? "Import" : "Re-import") { ec.importSheet(exp.id) }.disabled(exp.link.isEmpty)
                            }
                            if let t = table {
                                Text("\(t.rows.count) rows · " + t.headers.enumerated().map { "\(ExperimentEngine.columnLetter($0)) \($1)" }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                SheetTableView(headers: t.headers, originalHeaders: t.originalHeaders, columns: Array(t.headers.indices),
                                               rows: Array(t.rows.prefix(200)), version: t.rows.count)
                                    .frame(height: 150)
                            } else if !exp.link.isEmpty {
                                Text("Click Import to load the sheet (needed after each app start).").font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("What the columns mean (optional, used by every command) — e.g. COL A is the shortlist trigger: the NSE symbol is shortlisted",
                                      text: $exp.notes, axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(1...4)
                        }
                        ForEach($exp.commands) { $c in
                            CommandCard(exp: exp, cmd: $c, onDelete: { exp.commands.removeAll { $0.id == c.id } }).environmentObject(vm).id(c.id)
                        }
                        if exp.commands.isEmpty && table != nil {
                            Text("Type a command below — or start from an example.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: exp.commands.count) { _ in if let last = exp.commands.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } } }
            }
            Divider()
            HStack(spacing: 8) {
                Menu {
                    ForEach(Self.examples, id: \.self) { ex in Button(ex) { command = ex } }
                } label: { Image(systemName: "text.badge.plus") }
                .menuStyle(.borderlessButton).fixedSize().help("Example commands")
                TextField("Command — e.g. compare COL B vs COL C · only D_Trigger = 1 · per sector · days from COL A to COL B…", text: $command, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .onSubmit(send)
                Button("Run", action: send).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || table == nil)
            }
            .padding(10)
        }
    }

    private func send() {
        let t = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, table != nil else { return }
        ec.ask(exp.id, text: t, model: vm.settings.groqModel, base: vm.priceBook)
        command = ""
    }

    private func box<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); c() }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// One command: its text, plan (editable), results, conclusion.
struct CommandCard: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var ec = ExperimentCenter.shared
    let exp: Experiment
    @Binding var cmd: ExpCommand
    let onDelete: () -> Void
    @State private var showPlan = false
    @State private var showEntries = false

    private var table: SheetTable? { ec.tables[exp.id] }
    private var headers: [String] { table?.headers ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "chevron.right.circle.fill").foregroundStyle(.tint)
                Text(cmd.text).font(.headline).textSelection(.enabled)
                Spacer()
                if let b = ec.busy[cmd.id] { ProgressView().controlSize(.small); Text(b).font(.caption).foregroundStyle(.secondary) }
                Button(showPlan ? "Hide plan" : "Plan") { showPlan.toggle() }.controlSize(.small)
                Button { ec.run(exp.id, cmd.id, base: vm.priceBook) } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small).help("Run again")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.controlSize(.small).buttonStyle(.borderless)
            }
            if !cmd.plan.explanation.isEmpty { Text(cmd.plan.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let e = ec.errors[cmd.id] { Text(e).font(.caption).foregroundStyle(.orange) }
            if showPlan, table != nil { planEditor }
            if let r = ec.results[cmd.id] { results(r) }
            else if ec.busy[cmd.id] == nil && table != nil {
                Button("Run") { ec.run(exp.id, cmd.id, base: vm.priceBook) }.controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: Plan

    private func pick(_ sel: Binding<String>, none: Bool = true) -> some View {
        Picker("", selection: sel) {
            if none { Text("—").tag("") }
            ForEach(Array(headers.enumerated()), id: \.offset) { i, h in Text("\(ExperimentEngine.columnLetter(i)) · \(h)").tag(h) }
        }
        .labelsHidden().frame(width: 220)
    }

    private var planEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Task", selection: $cmd.plan.task) {
                    Text("Compare returns after entries").tag("compare")
                    Text("Days between two date columns").tag("gap")
                    Text("Describe columns").tag("describe")
                    Text("Does a higher value mean better returns?").tag("relation")
                }.frame(width: 360)
                Spacer()
                Button("Run with this plan") { ec.run(exp.id, cmd.id, base: vm.priceBook) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { Text("NSE symbol").font(.caption); pick($cmd.plan.symbolColumn, none: false) }
                GridRow {
                    Text("Shortlist").font(.caption)
                    HStack {
                        pick($cmd.plan.shortlistColumn)
                        Picker("", selection: $cmd.plan.shortlistKind) {
                            Text("non-empty / 1 = shortlisted").tag("flag"); Text("cell is the date").tag("date"); Text("the column is the symbol").tag("symbol")
                        }.labelsHidden().fixedSize()
                    }
                }
                GridRow { Text("Row date").font(.caption); pick($cmd.plan.baseDateColumn) }
                GridRow {
                    Text("Group by").font(.caption)
                    HStack {
                        pick($cmd.plan.groupBy)
                        Picker("", selection: $cmd.plan.groupBuckets) { Text("each value").tag(0); Text("Low / Mid / High").tag(3) }.labelsHidden().fixedSize()
                    }
                }
            }
            Text("Filters").font(.caption.bold())
            ForEach($cmd.plan.filters) { $f in
                HStack {
                    pick($f.column, none: false)
                    Picker("", selection: $f.op) { ForEach(["=", "≠", ">", "≥", "<", "≤", "contains", "nonempty", "empty"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().fixedSize()
                    if !["nonempty", "empty"].contains(f.op) { TextField("value", text: $f.value).frame(width: 90).textFieldStyle(.roundedBorder) }
                    Button { cmd.plan.filters.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button { cmd.plan.filters.append(ExpFilter(column: headers.first ?? "")) } label: { Label("Add filter", systemImage: "plus.circle") }.buttonStyle(.borderless).font(.caption)

            switch cmd.plan.task {
            case "gap":
                HStack { Text("From").font(.caption); pick($cmd.plan.gapFrom, none: false); Text("to").font(.caption); pick($cmd.plan.gapTo, none: false) }
            case "describe", "relation":
                Text(cmd.plan.task == "relation" ? "Number column(s)" : "Columns").font(.caption.bold())
                HStack {
                    ForEach(cmd.plan.columns, id: \.self) { c in
                        HStack(spacing: 2) { Text(c).font(.caption); Button { cmd.plan.columns.removeAll { $0 == c } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
                            .padding(.horizontal, 6).background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Menu("Add") { ForEach(headers, id: \.self) { h in Button(h) { if !cmd.plan.columns.contains(h) { cmd.plan.columns.append(h) } } } }.fixedSize()
                }
                if cmd.plan.task == "relation" { horizonsRow }
            default:
                Text("Entries to compare (none = enter on the row date)").font(.caption.bold())
                ForEach($cmd.plan.triggers) { $t in
                    HStack {
                        pick($t.column, none: false)
                        Picker("", selection: $t.kind) {
                            Text("cell = date").tag("date"); Text("non-empty / 1 = on the row date").tag("flag"); Text("cell = entry price").tag("price")
                        }.labelsHidden().fixedSize()
                        TextField("label", text: $t.label).frame(width: 90).textFieldStyle(.roundedBorder)
                        Button { cmd.plan.triggers.removeAll { $0.id == t.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button { cmd.plan.triggers.append(ExpTrigger(column: headers.first ?? "")) } label: { Label("Add entry", systemImage: "plus.circle") }.buttonStyle(.borderless).font(.caption)
                horizonsRow
                HStack {
                    Stepper("Enter \(cmd.plan.entryDelay == 0 ? "on the trigger day's close" : "\(cmd.plan.entryDelay) day\(cmd.plan.entryDelay == 1 ? "" : "s") later")",
                            value: $cmd.plan.entryDelay, in: 0...5).font(.caption)
                    Text("target %").font(.caption); TextField("", value: $cmd.plan.targetPercent, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                    Text("stop %").font(.caption); TextField("", value: $cmd.plan.stopPercent, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                    Text("(0 = off)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            let issues = table.map { ExperimentEngine.problems(cmd.plan, table: $0) } ?? []
            if !issues.isEmpty { Text(issues.joined(separator: " · ")).font(.caption).foregroundStyle(.orange) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }

    private var horizonsRow: some View {
        HStack {
            Text("Measure after").font(.caption)
            TextField("", text: Binding(get: { cmd.plan.horizons.map(String.init).joined(separator: ", ") },
                                        set: { cmd.plan.horizons = $0.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { (1...250).contains($0) } }))
                .frame(width: 90).textFieldStyle(.roundedBorder)
            Text("trading days · hit ≥").font(.caption)
            TextField("", value: $cmd.plan.winPercent, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
            Text("%").font(.caption)
        }
    }

    // MARK: Results

    private func results(_ r: ExpResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !r.headline.isEmpty { Label(r.headline, systemImage: "lightbulb.fill").font(.title3.bold()).foregroundStyle(.green) }
            ForEach(r.tables) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                            GridRow { ForEach(Array(t.columns.enumerated()), id: \.offset) { i, c in Text(c).font(.caption.bold()).foregroundStyle(.secondary).gridColumnAlignment(i == 0 ? .leading : .trailing) } }
                            ForEach(Array(t.rows.enumerated()), id: \.offset) { _, row in
                                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { i, v in
                                    Text(v).font(.callout.monospacedDigit()).fontWeight(i == 0 ? .semibold : .regular)
                                        .foregroundStyle(v.hasPrefix("+") ? Color.green : (v.hasPrefix("-") && v.count > 1 ? Color.red : Color.primary))
                                } }
                            }
                        }
                    }
                }
            }
            if !r.bars.isEmpty {
                Text(r.barTitle).font(.caption.bold()).foregroundStyle(.secondary)
                Chart(r.bars) { b in
                    BarMark(x: .value("x", b.category), y: .value("value", b.value)).foregroundStyle(by: .value("series", b.series)).position(by: .value("series", b.series))
                }
                .frame(height: 160)
            }
            ForEach(r.notes, id: \.self) { n in Label(n, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button { ec.summarize(exp.id, cmd.id, model: vm.settings.groqModel) } label: { Label("Conclusion (Groq)", systemImage: "text.bubble") }.controlSize(.small)
                if !r.entries.isEmpty { Button(showEntries ? "Hide entries" : "Every entry (\(r.entries.count))") { showEntries.toggle() }.controlSize(.small) }
            }
            if !cmd.summary.isEmpty {
                Text(cmd.summary).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            if showEntries {
                let hs = cmd.plan.horizons
                Table(r.entries) {
                    TableColumn("Symbol") { e in Text(e.symbol).bold() }.width(min: 80, ideal: 100)
                    TableColumn("Entry type") { e in Text(e.arm) }.width(min: 80, ideal: 120)
                    TableColumn("Entry day") { e in Text(e.day).monospacedDigit() }.width(min: 80, ideal: 90)
                    TableColumn("Entry") { e in Text(String(format: "%.2f", e.entry)).monospacedDigit() }.width(min: 55, ideal: 65)
                    TableColumn("Returns") { e in Text(zip(hs, e.returns).map { "\($0)d \(ExperimentEngine.pct($1))" }.joined(separator: " · ")).monospacedDigit() }.width(min: 160, ideal: 220)
                    TableColumn("Trade") { e in Text(ExperimentEngine.pct(e.trade)).monospacedDigit() }.width(min: 50, ideal: 60)
                }
                .frame(height: 240)
            }
        }
    }
}

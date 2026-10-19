import SwiftUI
import AppKit

/// Combinatorix: which combinations of your filter values, conditions, rules and context came before
/// daily, weekly and monthly gainers — grouped into named families, checked on later days.
struct CombinatorixView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var tab = "Daily"
    @State private var family: Int?             // family id
    @State private var selected: CombiCombo.ID?
    @State private var renaming: CombiFamily?
    @State private var newName = ""
    @State private var groqNote: String?
    @State private var showHelp = false

    private var horizon: CombiHorizon? { CombiHorizon(rawValue: tab) }
    private var result: CombiHorizonResult? { horizon.flatMap { vm.combiReport?.results[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if vm.combiReport == nil {
                empty
            } else if tab == "All-rounders" {
                allRounders
            } else if let r = result {
                summary(r)
                Divider()
                if r.combos.isEmpty {
                    Text(r.note.isEmpty ? "Nothing found." : r.note).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        familyList(r).frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                        VStack(spacing: 0) {
                            comboTable(r)
                            Divider()
                            detail(r).frame(height: 150)
                        }
                        .frame(minWidth: 560)
                    }
                }
            }
        }
        .navigationTitle("Combinatorix")
        .onChange(of: tab) { _ in family = nil; selected = nil }
        .alert("Name this family", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let f = renaming { vm.settings.combiNames[f.key] = newName } ; renaming = nil }
            Button("Use the automatic name") { if let f = renaming { vm.settings.combiNames[f.key] = nil }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(isPresented: $showHelp) { CombiHelp() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(CombiHorizon.allCases) { h in Text(h.rawValue).tag(h.rawValue) }
                Text("All-rounders").tag("All-rounders")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Divider().frame(height: 18)
            pct("Daily ≥", $vm.settings.combiDailyPct, "Daily gainer: gain on the next trading day")
            pct("Weekly ≥", $vm.settings.combiWeeklyPct, "Weekly gainer: gain within the next 5 trading days")
            pct("Monthly ≥", $vm.settings.combiMonthlyPct, "Monthly gainer: gain within the next 21 trading days")
            Menu("Options") {
                Toggle("Weekly / monthly: count the best close in the period (off = the last close)", isOn: $vm.settings.combiUsePeak)
                Toggle("Include 5-day changes (rising / falling, just turned 1)", isOn: $vm.settings.combiUseChanges)
                Toggle("Include sector quadrant and market regime", isOn: $vm.settings.combiUseContext)
                Picker("Signals per combination", selection: $vm.settings.combiMaxSize) {
                    Text("Up to 2").tag(2); Text("Up to 3").tag(3)
                }
            }
            .fixedSize()
            Spacer()
            if vm.isMiningCombos || vm.isFetchingPrices {
                ProgressView().controlSize(.small)
            }
            if let s = vm.combiStatus { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if vm.priceBook.series.isEmpty {
                Button("Fetch Yahoo prices") { vm.fetchYahooPrices() }.disabled(vm.isFetchingPrices)
            }
            Button { vm.runCombinatorix() } label: { Label(vm.combiReport == nil ? "Find combinations" : "Re-run", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isMiningCombos)
                .keyboardShortcut("r", modifiers: .command)
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.borderless).help("How Combinatorix works")
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func pct(_ title: String, _ v: Binding<Double>, _ help: String) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption)
            TextField("", value: v, format: .number.precision(.fractionLength(0...1))).frame(width: 38).multilineTextAlignment(.trailing)
            Text("%").font(.caption)
        }
        .help(help)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Combinatorix").font(.title2.bold())
            Text("Looks through every stored day for combinations of your Filter columns, Filter conditions, alert rules, 5-day changes and sector / market context that came before daily, weekly and monthly gainers — then checks them on later days and groups them into named families.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 620)
            Text("Uses \(vm.nnAutoFeatures.prefix(40).count) Filter columns · \(HistoryStore.days().count) stored days · \(vm.priceBook.series.count) stocks with Yahoo prices")
                .font(.caption).foregroundStyle(.secondary)
            Button("Find combinations") { vm.runCombinatorix() }.buttonStyle(.borderedProminent).disabled(vm.isMiningCombos)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ r: CombiHorizonResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 14) {
                stat("\(r.rows.formatted())", "stock-days learned from")
                stat(percent(r.baseRate), "were \(r.horizon.gainerWord)s (≥ \(CombiEngine.fmt(r.threshold))%\(r.usePeak ? " at best" : ""))")
                stat("\(r.tested.formatted())", "combinations tried")
                stat("\(r.combos.count)", "kept")
                stat("\(r.combos.filter { $0.heldUp == true }.count)", "held up on later days")
                Spacer()
                if let h = horizon {
                    Button("✨ Name families with Groq") {
                        groqNote = "Asking Groq…"
                        Task { groqNote = await vm.nameCombiFamiliesWithGroq(h) }
                    }
                    .controlSize(.small)
                    .help("Groq suggests a short name per family from its signals. Right-click a family to rename it yourself.")
                }
            }
            HStack {
                Text(r.testMethod).font(.caption).foregroundStyle(.secondary)
                if let g = groqNote { Text("· \(g)").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(vm.combiReport?.notes ?? [], id: \.self) { Text("ℹ️ " + $0).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func stat(_ v: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(v).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Families

    private func familyList(_ r: CombiHorizonResult) -> some View {
        List(selection: $family) {
            ForEach(r.families) { f in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(vm.combiFamilyName(f)).font(.headline)
                        Spacer()
                        Text("×" + String(format: "%.1f", f.bestLift)).font(.caption.monospacedDigit().bold())
                            .foregroundStyle(f.heldUp > 0 ? .green : .secondary)
                    }
                    Text(f.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 8) {
                        Text("\(f.combos.count) combo\(f.combos.count == 1 ? "" : "s")")
                        if f.heldUp > 0 { Text("✅ \(f.heldUp) held up") }
                        if !f.todayMatches.isEmpty { Text("📍 \(f.todayMatches.count) today") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(f.id)
                .contextMenu {
                    Button("Rename…") { newName = vm.combiFamilyName(f); renaming = f }
                    if vm.settings.combiNames[f.key] != nil { Button("Use the automatic name") { vm.settings.combiNames[f.key] = nil } }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Families").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if family != nil { Button("Show all") { family = nil }.buttonStyle(.borderless).font(.caption) }
            }
            .padding(.horizontal, 10).padding(.top, 6)
        }
    }

    // MARK: Combinations

    private func shown(_ r: CombiHorizonResult) -> [CombiCombo] {
        guard let f = family, let fam = r.families.first(where: { $0.id == f }) else { return r.combos }
        return fam.combos.map { r.combos[$0] }
    }

    private func comboTable(_ r: CombiHorizonResult) -> some View {
        Table(shown(r), selection: $selected) {
            TableColumn("Combination") { c in
                Text(c.text).lineLimit(2).help(c.text)
            }
            .width(min: 220, ideal: 340)
            TableColumn("Family") { c in Text(r.families.first { $0.id == c.family }.map(vm.combiFamilyName) ?? "").font(.caption) }
                .width(min: 90, ideal: 130)
            TableColumn("Gainers / with") { c in Text("\(c.gainers) / \(c.total)").monospacedDigit() }
                .width(min: 80, ideal: 95)
            TableColumn("Hit rate") { c in
                Text(percent(c.hitRate)).monospacedDigit().help("Base rate: \(percent(r.baseRate))")
            }
            .width(min: 55, ideal: 65)
            TableColumn("Lift") { c in
                Text("×" + String(format: "%.1f", c.lift)).monospacedDigit().bold()
                    .help("Safe lift (95% lower bound): ×" + String(format: "%.2f", c.safeLift))
            }
            .width(min: 45, ideal: 55)
            TableColumn("Later days") { c in
                if let l = c.testLift {
                    Text("×" + String(format: "%.1f", l) + " (\(c.testGainers)/\(c.testTotal))").monospacedDigit()
                        .foregroundStyle(c.heldUp == true ? .green : .orange)
                } else { Text("—").foregroundStyle(.secondary).help("Not enough later rows with this combination to check") }
            }
            .width(min: 80, ideal: 105)
            TableColumn("q") { c in
                Text(c.qValue < 0.001 ? "<0.001" : String(format: "%.3f", c.qValue)).monospacedDigit().foregroundStyle(.secondary)
                    .help("False-discovery rate across all \(r.tested) combinations tried — lower is more believable")
            }
            .width(min: 45, ideal: 55)
            TableColumn("Avg gain") { c in
                Text(String(format: "%+.1f%%", c.avgGain)).monospacedDigit().help("All stocks: \(String(format: "%+.1f%%", r.avgGain))")
            }
            .width(min: 55, ideal: 65)
            TableColumn("Today") { c in Text(c.todayMatches.isEmpty ? "—" : "\(c.todayMatches.count)").monospacedDigit() }
                .width(min: 40, ideal: 45)
            TableColumn("Tags") { c in Text(c.tags.joined(separator: " ")).font(.caption) }
                .width(min: 90, ideal: 140)
        }
        .contextMenu(forSelectionType: CombiCombo.ID.self) { ids in
            if let id = ids.first, let c = r.combos.first(where: { $0.id == id }) { comboActions(c, r) }
        }
    }

    @ViewBuilder private func comboActions(_ c: CombiCombo, _ r: CombiHorizonResult) -> some View {
        let fam = r.families.first { $0.id == c.family }.map(vm.combiFamilyName) ?? ""
        Button(c.canBeFilter ? "Apply to Filter" : "Apply the Filter parts to Filter") { vm.applyCombi(c, r); openWindow(id: "filter") }
        Button("Make an alert rule") { vm.ruleFromCombi(c, r, family: fam); openWindow(id: "alerts") }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(fam): \(c.text) — \(c.gainers)/\(c.total) \(r.horizon.gainerWord)s, lift ×\(String(format: "%.1f", c.lift))", forType: .string)
        }
    }

    private func detail(_ r: CombiHorizonResult) -> some View {
        Group {
            if let id = selected, let c = r.combos.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(c.text).font(.headline).lineLimit(2)
                        Spacer()
                        comboActions(c, r).buttonStyle(.bordered).controlSize(.small)
                    }
                    Text(plain(c, r)).font(.caption).foregroundStyle(.secondary)
                    if !c.canBeFilter {
                        Text("Some parts (5-day changes, sector, market) can't be a Filter condition, so Apply uses only the other parts.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if c.todayMatches.isEmpty {
                        Text("No stock matches this combination in today's data.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                Text("Today:").font(.caption.bold())
                                ForEach(c.todayMatches.prefix(60), id: \.self) { s in
                                    Button(s) { vm.openChart(s, queue: c.todayMatches, openWindow: openWindow) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                        .help("Open chart")
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
            } else {
                Text("Select a combination to see what it means and which stocks match it today.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func plain(_ c: CombiCombo, _ r: CombiHorizonResult) -> String {
        var s = "On the days it learned from, \(c.total) stock-days had this combination and \(c.gainers) of them (\(percent(c.hitRate))) became \(r.horizon.gainerWord)s, against \(percent(r.baseRate)) for all stocks — \(String(format: "%.1f", c.lift))× as often."
        if let l = c.testLift {
            s += c.heldUp == true
                ? " On later days it never saw it was still \(String(format: "%.1f", l))× (\(c.testGainers) of \(c.testTotal))."
                : " On later days it dropped to \(String(format: "%.1f", l))× (\(c.testGainers) of \(c.testTotal)), so treat it with caution."
        }
        return s
    }

    // MARK: All-rounders

    private var allRounders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signals that lead families on more than one horizon").font(.headline)
            Text("A signal that comes before daily, weekly AND monthly gainers is more likely a real tendency than a one-off.")
                .font(.caption).foregroundStyle(.secondary)
            let rows = vm.combiReport?.allRounders ?? []
            if rows.isEmpty {
                Text("None yet — no signal leads a family on two or more horizons.").foregroundStyle(.secondary).padding(.top, 20)
            } else {
                Table(rows) {
                    TableColumn("Signal") { a in Text(a.signal) }.width(min: 220, ideal: 320)
                    TableColumn("Daily") { a in cell(a, .daily) }.width(min: 70, ideal: 90)
                    TableColumn("Weekly") { a in cell(a, .weekly) }.width(min: 70, ideal: 90)
                    TableColumn("Monthly") { a in cell(a, .monthly) }.width(min: 70, ideal: 90)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func cell(_ a: CombiAllRounder, _ h: CombiHorizon) -> some View {
        if let l = a.lifts[h] {
            Text("×" + String(format: "%.1f", l) + (a.heldUp[h] == true ? " ✅" : "")).monospacedDigit()
        } else { Text("—").foregroundStyle(.secondary) }
    }

    private func percent(_ v: Double) -> String { String(format: v < 0.1 ? "%.1f%%" : "%.0f%%", v * 100) }
}

struct CombiHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How Combinatorix works").font(.title2.bold())
            Group {
                Text("**Rows** — every stock on every stored day (sampled to 80,000 if larger). Its label is the real gain after that day from Yahoo prices: next day (Daily), within 5 trading days (Weekly) or 21 (Monthly).")
                Text("**Signals** — each Filter column as Low / Mid / High (thirds) or 0 / 1, rising / falling over the last 5 snapshots, just turned 1, each Filter condition, the whole Filter, each alert rule, the sector's rotation quadrant and the market regime.")
                Text("**Combinations** — every set of 1–3 signals is counted on the earlier days. Lift = how many times more often it was followed by a gainer than stocks in general. Safe lift is the cautious version (95% lower bound). q is the false-discovery rate across everything tried; only q ≤ 0.10 is kept, and combos that are no better than one of their parts are dropped.")
                Text("**Later days** — each combination is then checked on the most recent days it never saw. ✅ Held up = still at least 1.2× there. ⚠️ Faded = it didn't.")
                Text("**Families** — combinations are grouped by their strongest signal and named after it: Power (high values), Coiled (low), Momentum (rising), Pullback (falling), Fresh-trigger (just turned on), Setup (a Filter condition), Rule-fired, Sector-led, Rotation, Tailwind… + Spark (daily), Surge (weekly), Runner (monthly). Right-click to rename, or let Groq name them.")
                Text("**Tags** — 🎯 Sniper: rare but hits 3× the base rate. 🌊 Broad: covers 5%+ of stock-days.")
                Text("**Caution** — these are past associations, not guarantees. With few stored days, even 'held up' patterns can be luck; the more days the app stores, the more trustworthy this gets.").foregroundStyle(.orange)
            }
            .font(.callout)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 620)
    }
}

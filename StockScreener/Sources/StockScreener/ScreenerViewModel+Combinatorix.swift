import Foundation

extension ScreenerViewModel {

    /// The signals Combinatorix tests besides the column levels: each Filter condition / group, the whole Filter,
    /// and every alert rule — each compiled against today's columns.
    func combiConditions() -> [(name: String, kind: CombiKind, filter: FilterGroup, pred: RowPredicate)] {
        var out: [(String, CombiKind, FilterGroup, RowPredicate)] = []
        var issues: [String] = []
        func add(_ name: String, _ kind: CombiKind, _ g: FilterGroup) {
            guard !name.isEmpty, let p = FilterCompiler.compile(g, table: table, issues: &issues),
                  !out.contains(where: { $0.0 == name }) else { return }
            out.append((name, kind, g, p))
        }
        let fg = settings.filterGroup
        if fg.isEnabled {
            for c in fg.conditions where c.isEnabled {
                let g = FilterGroup(mode: .all, conditions: [c])
                add(Self.describe(g), .condition, g)
            }
            for g in fg.groups where g.isEnabled { add("(" + Self.describe(g) + ")", .condition, g) }
            if fg.conditions.filter(\.isEnabled).count + fg.groups.filter(\.isEnabled).count > 1 { add("Passes your Filter", .filter, fg) }
        }
        for r in settings.buyTriggers { add("Rule: " + r.name, .rule, r.filter) }
        return Array(out.prefix(64))
    }

    nonisolated static func combiDay(_ day: String, _ t: SheetTable, label: Int, cols: [Int], preds: [RowPredicate]) -> CombiDay {
        var symbols: [String] = [], values: [Float] = [], flags: [UInt64] = []
        var seen = Set<String>()
        for row in t.rows {
            let sym = row.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            guard !sym.isEmpty, seen.insert(sym).inserted else { continue }
            symbols.append(sym)
            for c in cols { values.append(row.number(c).map { Float($0) } ?? .nan) }
            var f: UInt64 = 0
            for (k, p) in preds.enumerated() where p(row) { f |= 1 << UInt64(k) }
            flags.append(f)
        }
        return CombiDay(day: day, symbols: symbols, values: values, flags: flags)
    }

    /// Reads every stored snapshot and mines the combinations behind daily, weekly and monthly gainers.
    func runCombinatorix() {
        guard !isMiningCombos else { return }
        guard let label = labelIndex, hasData else { combiStatus = "Import data first."; return }
        guard !priceBook.series.isEmpty else { combiStatus = "Fetch Yahoo prices first (button above) — gains are measured from them."; return }
        let current = table
        let colNames = Array(nnAutoFeatures.prefix(40))
        let cols = colNames.compactMap { current.index(of: $0) }
        let conds = combiConditions()
        guard !cols.isEmpty || !conds.isEmpty else { combiStatus = "Pick columns on the Filter screen first — Combinatorix uses them."; return }
        let preds = conds.map(\.pred)
        let liveKey = HistoryStore.dayKey(dataDay(of: table))
        let stored = Array(HistoryStore.days().filter { $0 < liveKey }.suffix(300))

        var input = CombiInput()   // filled here, completed in the task
        input.columns = colNames
        input.conditions = conds.map { ($0.name, $0.kind, $0.filter) }
        input.book = priceBook
        input.thresholds = [.daily: settings.combiDailyPct, .weekly: settings.combiWeeklyPct, .monthly: settings.combiMonthlyPct]
        input.usePeak = settings.combiUsePeak
        input.maxSize = max(1, min(3, settings.combiMaxSize))
        input.useChanges = settings.combiUseChanges
        input.useContext = settings.combiUseContext
        if settings.combiUseContext, let rep = sectorReport, let sc = sectorColumnIndex {
            for r in current.rows {
                let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                let sec = r.text(sc).trimmingCharacters(in: .whitespaces)
                if !sym.isEmpty, !sec.isEmpty { input.sectorOf[sym] = sec }
            }
            for s in rep.sectors { for st in s.history { input.quadrants[st.day, default: [:]][s.name] = st.quadrant } }
            for m in rep.marketHistory { input.regimes[m.day] = m.regime }
        }

        let baseInput = input
        isMiningCombos = true
        combiStatus = "Reading \(stored.count) stored days…"
        Task { [weak self] in
            let days: [CombiDay] = await Task.detached(priority: .userInitiated) {
                stored.compactMap { day in
                    HistoryStore.load(day).flatMap { ScreenerViewModel.align($0, to: current) }
                        .map { ScreenerViewModel.combiDay(day, $0, label: label, cols: cols, preds: preds) }
                }
            }.value
            var inp = baseInput
            inp.days = days
            inp.live = ScreenerViewModel.combiDay(liveKey, current, label: label, cols: cols, preds: preds)
            let ready = inp
            self?.combiStatus = "Mining combinations on \(days.count) days…"
            let report = await Task.detached(priority: .userInitiated) {
                CombiEngine.run(ready) { msg in Task { @MainActor in self?.combiStatus = msg } }
            }.value
            guard let self else { return }
            var r = report
            if stored.count < 30 { r.notes.append("Only \(stored.count) stored days so far — patterns from few days are fragile; they get more trustworthy as days build up.") }
            if !self.settings.combiUseContext || self.sectorReport == nil { r.notes.append("Sector / market signals are off (open Sectors to calculate them, and turn them on in Options).") }
            self.combiReport = r
            self.isMiningCombos = false
            self.combiStatus = nil
        }
    }

    func combiFamilyName(_ f: CombiFamily) -> String {
        let own = settings.combiNames[f.key]?.trimmingCharacters(in: .whitespaces) ?? ""
        return own.isEmpty ? f.autoName : own
    }

    /// The combination as a Filter group (only the parts that are Filter conditions).
    func combiFilter(_ c: CombiCombo, _ r: CombiHorizonResult) -> FilterGroup {
        var g = FilterGroup(mode: .all)
        for i in c.signals {
            let s = r.signals[i]
            if let item = s.item { g.conditions += item.filterConditions(combiReport?.columns ?? []) }
            else if let f = s.filter { g.groups.append(f) }
        }
        return g
    }

    func applyCombi(_ c: CombiCombo, _ r: CombiHorizonResult) { settings.filterGroup = combiFilter(c, r) }

    func ruleFromCombi(_ c: CombiCombo, _ r: CombiHorizonResult, family: String) {
        var rule = BuyTrigger(isEnabled: true, name: "Combinatorix · \(family): \(c.text)")
        rule.filter = combiFilter(c, r)
        settings.buyTriggers.append(rule)
    }

    /// Asks Groq for a short, memorable name per family (from its signals only).
    func nameCombiFamiliesWithGroq(_ h: CombiHorizon) async -> String? {
        guard let r = combiReport?.results[h], !r.families.isEmpty else { return "Run Combinatorix first." }
        guard !settings.groqModel.isEmpty else { return "Pick a Groq model in Daily Gainers → Why? settings first." }
        let lines = r.families.prefix(20).map { f -> String in
            let combos = f.combos.prefix(4).map { r.combos[$0].text }.joined(separator: " | ")
            return "\(f.id): \(combos)"
        }.joined(separator: "\n")
        let system = """
        You name stock-screening patterns. Each line is a family id and the signal combinations in it that came \
        before a \(h.gainerWord). Give each family a short, memorable 2–3 word name that describes what the signals \
        have in common (e.g. "Quiet Coil Breakout"). No numbers, no promises of profit. \
        Reply as JSON: {"names": {"id": "name"}}.
        """
        do {
            let text = try await GroqClient.chat(model: settings.groqModel, system: system, user: lines, json: true)
            guard let d = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let names = j["names"] as? [String: Any] else { return "Groq's reply couldn't be read." }
            var n = 0
            for f in r.families {
                if let name = names["\(f.id)"] as? String, !name.isEmpty { settings.combiNames[f.key] = String(name.prefix(40)); n += 1 }
            }
            return "Named \(n) famil\(n == 1 ? "y" : "ies")."
        } catch {
            return error.localizedDescription
        }
    }
}

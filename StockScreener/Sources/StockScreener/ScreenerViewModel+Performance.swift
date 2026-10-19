import Foundation

/// The experiments sheet, cached on disk so the Performance pane works offline.
enum ExperimentStore {
    private static var url: URL { AppFolders.base.appendingPathComponent("experiments.csv.lzfse") }

    static func load() -> SheetTable {
        guard let data = try? Data(contentsOf: url),
              let raw = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let t = try? SheetService.parse(raw).table else { return SheetTable() }
        return t
    }

    static func save(csv: Data) {
        try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
        if let c = try? (csv as NSData).compressed(using: .lzfse) as Data { try? c.write(to: url, options: .atomic) }
    }
}

extension ScreenerViewModel {

    // MARK: Experiments sheet

    var expSymbolIndex: Int? {
        guard !expTable.headers.isEmpty else { return nil }
        if !settings.perfSymbolColumn.isEmpty, let i = expTable.index(of: settings.perfSymbolColumn) { return i }
        if let i = expTable.headers.firstIndex(where: { ["symbol", "ticker", "stock", "name"].contains($0.lowercased()) }) { return i }
        return 0
    }

    func importExperimentsSheet() {
        let link = settings.perfSheetLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let url = SheetService.csvURL(from: link) else {
            expStatus = "Paste the experiments sheet link first (Share → Anyone with the link can view)."
            return
        }
        isLoadingExp = true
        expStatus = "Downloading…"
        Task { [weak self] in
            do {
                let result = try await SheetService.fetch(from: url)
                guard let self else { return }
                self.expTable = result.table
                ExperimentStore.save(csv: result.raw)
                self.expStatus = "Imported \(result.table.rows.count) rows, \(result.table.headers.count) columns · \(Date().formatted(date: .omitted, time: .shortened))"
            } catch {
                self?.expStatus = "Couldn't download: \(error.localizedDescription)"
            }
            self?.isLoadingExp = false
        }
    }

    /// Columns a study can use: "main:NAME" or "exp:NAME" (imported experiment columns only).
    var perfColumnChoices: [(key: String, title: String)] {
        headers.filter { $0 != "NN_score" && $0 != "NN_conf" }.map { ("main:" + $0, $0) }
            + settings.perfImportedColumns.filter { expTable.index(of: $0) != nil }.map { ("exp:" + $0, "\($0)  (experiments)") }
    }

    // MARK: Running a study

    /// Reads the events, fetches missing Yahoo prices, then analyses.
    func runStudy(_ study: PerfStudy) {
        guard perfRunning == nil else { return }
        let refDay = HistoryStore.dayKey(dataDay(of: table))
        let events = perfEvents(study)
        guard !events.isEmpty else {
            perfStatus = "No stocks have a value in \(study.column)."
            perfResults[study.id] = PerfResult()
            return
        }
        perfRunning = study.id
        perfStatus = "Checking prices…"

        // Which symbols need (longer) Yahoo history?
        let maxBack = events.compactMap { NumberParser.parse($0.value) }.max() ?? 250
        let range = maxBack > 450 ? "5y" : "2y"
        let needFrom = HistoryStore.date(fromKey: refDay).flatMap {
            Calendar.current.date(byAdding: .day, value: -Int(Double(min(maxBack, 2000)) * (study.unit == .tradingDays ? 1.5 : 1.05)) - 5, to: $0)
        }.map(HistoryStore.dayKey) ?? "0000"
        var need = events.map(\.symbol).filter { sym in
            guard let s = priceBook.series(for: sym), let first = s.days.first, let last = s.lastDay else { return true }
            return first > needFrom || last < refDay && Date().timeIntervalSince(priceBook.fetchedAt) > 6 * 3600
        }
        let benchmark = priceBook.series(for: Self.benchmarkSymbol)
        if benchmark == nil || (benchmark?.days.first ?? "9") > needFrom { need.append(Self.benchmarkSymbol) }
        need = Array(Set(need))

        Task { [weak self] in
            guard let self else { return }
            if !need.isEmpty {
                self.perfStatus = "Fetching Yahoo prices for \(need.count) stocks…"
                let (book, failed) = await YahooClient.fetchAll(need, range: range) { [weak self] done, total in
                    self?.perfProgress = (done, total)
                }
                var merged = self.priceBook
                for (k, v) in book.series { merged.series[k] = v }
                self.priceBook = merged
                PriceStore.save(merged)
                if !failed.isEmpty { self.perfStatus = "Yahoo had no prices for \(failed.count) symbol\(failed.count == 1 ? "" : "s")" }
            }
            self.perfStatus = (self.perfStatus?.hasPrefix("Yahoo had") ?? false) ? self.perfStatus : nil
            let book = self.priceBook
            let result = await Task.detached(priority: .userInitiated) {
                PerfEngine.analyze(events, book: book, refDay: refDay, study: study)
            }.value
            self.perfResults[study.id] = result
            if !result.rows.isEmpty {
                let run = PerfRun(study: study, refDay: refDay, rows: result.rows, skipped: result.skipped.count)
                await Task.detached(priority: .utility) { PerfRunStore.save(run) }.value
                self.perfRuns.insert(run, at: 0)
                if self.perfRuns.count > PerfRunStore.keep { self.perfRuns = Array(self.perfRuns.prefix(PerfRunStore.keep)) }
                // compare the newest run of each indicator by default
                self.compareSelection.subtract(self.perfRuns.filter { $0.study.id == study.id && $0.id != run.id }.map(\.id))
                self.compareSelection.insert(run.id)
            }
            self.perfRunning = nil
            self.perfProgress = (0, 0)
        }
    }

    /// One event per stock: from the main sheet or the experiments sheet, with the split-by value.
    func perfEvents(_ study: PerfStudy) -> [PerfEvent] {
        guard let label = labelIndex else { return [] }
        let expSym = expSymbolIndex
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).uppercased() }

        var mainRows: [String: SheetRow] = [:]
        for r in table.rows { let k = key(r.text(label)); if !k.isEmpty, mainRows[k] == nil { mainRows[k] = r } }
        var expRows: [String: SheetRow] = [:]
        if let e = expSym { for r in expTable.rows { let k = key(r.text(e)); if !k.isEmpty, expRows[k] == nil { expRows[k] = r } } }

        let (srcRows, srcTable) = study.source == .main ? (mainRows, table) : (expRows, expTable)
        guard let col = srcTable.index(of: study.column) else { return [] }

        var splitTable: SheetTable?, splitCol: Int?, splitRows: [String: SheetRow] = [:]
        if study.splitBy.hasPrefix("main:") {
            splitTable = table; splitRows = mainRows; splitCol = table.index(of: String(study.splitBy.dropFirst(5)))
        } else if study.splitBy.hasPrefix("exp:") {
            splitTable = expTable; splitRows = expRows; splitCol = expTable.index(of: String(study.splitBy.dropFirst(4)))
        }
        _ = splitTable

        let filterSet = Set(filterRows.map { key($0.text(label)) })
        let watchSet = Set(watchlists.flatMap { $0.items.map { key($0.symbol) } })

        return srcRows.keys.sorted().compactMap { sym in
            guard let row = srcRows[sym] else { return nil }
            let v = row.text(col).trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            switch study.scope {
            case .all: break
            case .filter: guard filterSet.contains(sym) else { return nil }
            case .watchlists: guard watchSet.contains(sym) else { return nil }
            }
            let g = splitCol.flatMap { c in splitRows[sym]?.text(c) }
            return PerfEvent(symbol: sym, value: v, group: study.splitBy.isEmpty ? nil : (g ?? ""))
        }
    }
}

extension ScreenerViewModel {
    /// Shows each study's last saved run (after relaunch).
    func restorePerfResults() {
        for study in settings.perfStudies where perfResults[study.id] == nil {
            if let run = perfRuns.first(where: { $0.study.id == study.id }) {
                var r = PerfEngine.summarize(run.rows, study: run.study)
                r.refDay = run.refDay
                perfResults[study.id] = r
            }
        }
        if compareSelection.isEmpty {
            var seen = Set<UUID>()
            for run in perfRuns where !seen.contains(run.study.id) {      // newest run of each study
                seen.insert(run.study.id)
                compareSelection.insert(run.id)
            }
        }
    }

    func runComparison() {
        let runs = perfRuns.filter { compareSelection.contains($0.id) }
        guard !runs.isEmpty else { compareResult = nil; return }
        let h = max(1, settings.perfCompareHorizon), t = settings.perfCompareTarget, st = settings.perfCompareStop
        isComparing = true
        Task { [weak self] in
            let r = await Task.detached(priority: .userInitiated) { PerfCompare.compare(runs, horizon: h, target: t, stop: st) }.value
            self?.compareResult = r
            self?.isComparing = false
        }
    }

    func deleteRun(_ id: UUID) {
        PerfRunStore.delete(id)
        perfRuns.removeAll { $0.id == id }
        compareSelection.remove(id)
    }
}

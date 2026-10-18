import SwiftUI
import AppKit

// MARK: - Shared types

struct TGSummary {
    let day: String
    let count: Int
    let safetySum: Double?
    let fromYahoo: Int        // rows whose change% came from Yahoo
    let fromSheet: Int        // rows that used the sheet's change% column
}

enum FlashKind { case up, down, new }

/// Cells to flash on the Filter table ("what changed since the previous day").
struct FlashSpec {
    let token: Int
    let started: Date
    let cells: [Int: [Int: FlashKind]]    // row id -> column -> kind
    let newRows: Set<Int>
    let duration: Double = 2.2

    func kind(row: Int, column: Int) -> FlashKind? {
        if newRows.contains(row) { return .new }
        return cells[row]?[column]
    }

    var isActive: Bool { Date().timeIntervalSince(started) < duration }

    static func color(_ k: FlashKind) -> NSColor {
        switch k {
        case .up: return NSColor.systemGreen
        case .down: return NSColor.systemRed
        case .new: return NSColor.systemBlue
        }
    }
}

struct NNReport {
    var mode: String                 // "Predictive" or "Descriptive"
    var modeDetail: String
    var featureNames: [String]
    var stocks: Int
    var gainers: Int
    var threshold: Double
    var windowDays: Int
    var combos: [PatternCombo]
    var auc: Double?
    var precisionTop20: Double?
    var importance: [(String, Double)]
    var topScored: [(String, Double)]
    var trainedAt = Date()
    var gainerList: [(String, Double)]   // symbol, % gain
}

// MARK: - Yahoo prices, TG, neural net, flash

extension ScreenerViewModel {

    // Yahoo

    /// Downloads ~1 year of daily closes for every stock in today's data (cached on disk).
    func fetchYahooPrices() {
        guard !isFetchingPrices else { return }
        let symbols = allSymbols
        guard !symbols.isEmpty else { priceError = "Import data first."; return }
        isFetchingPrices = true
        priceError = nil
        priceProgress = (0, symbols.count)
        priceTask = Task { [weak self] in
            let (book, failed) = await YahooClient.fetchAll(symbols, range: "1y") { done, total in
                self?.priceProgress = (done, total)
            }
            guard let self else { return }
            self.isFetchingPrices = false
            if book.series.isEmpty {
                self.priceError = "Yahoo returned no prices (\(failed.count) symbols failed). Yahoo may be blocking or rate-limiting requests — try again later."
                return
            }
            self.priceBook = book
            PriceStore.save(book)
            if !failed.isEmpty {
                self.priceError = "\(failed.count) symbols weren't found on Yahoo (e.g. \(failed.prefix(5).joined(separator: ", "))) — indices/ETFs often use other codes."
            }
            self.scheduleFilterRecompute(delayMs: 0)
        }
    }

    func cancelYahooFetch() {
        priceTask?.cancel()
        isFetchingPrices = false
    }

    var priceBookAgeText: String {
        guard priceBook.fetchedAt > .distantPast else { return "No Yahoo prices yet" }
        return "\(priceBook.series.count) stocks · up to \(priceBook.latestDay ?? "?") · fetched \(priceBook.fetchedAt.formatted(.relative(presentation: .named)))"
    }

    // TG

    /// The trading day currently shown on the Filter screen.
    var displayedDayKey: String {
        if let i = timelineIndex, i < timelineDays.count { return timelineDays[i] }
        return HistoryStore.dayKey(dataDay(of: table))
    }

    /// change% per stock for `day`: Yahoo when available, otherwise the sheet's change% column.
    func tgChanges(for source: SheetTable, day: String) -> [Int: (Double, Bool)] {
        guard let label = labelIndex else { return [:] }
        let sheetCol = source.index(of: "change%") ?? source.index(of: "change %") ?? source.index(of: "change")
        var out: [Int: (Double, Bool)] = [:]
        for row in source.rows {
            let sym = row.text(label)
            if let y = priceBook.series(for: sym)?.dailyChange(on: day) {
                out[row.id] = (y, true)
            } else if let c = sheetCol, let v = row.number(c) {
                out[row.id] = (v, false)
            }
        }
        return out
    }

    func toggleTG() {
        tgMode.toggle()
        scheduleFilterRecompute(delayMs: 0)
    }

    // Neural net

    func trainPatternModel() {
        guard !isTraining else { return }
        guard !priceBook.series.isEmpty else { nnError = "Fetch Yahoo prices first."; return }
        guard let label = labelIndex else { nnError = "No stock name column."; return }
        isTraining = true
        nnError = nil
        nnStatus = "Preparing data…"

        let threshold = Double(settings.nnGainThreshold)
        let window = settings.nnWindowDays
        let featureNames = nnFeatureColumns
        let book = priceBook
        let live = table
        let days = HistoryStore.days()
        let endDay = book.latestDay ?? HistoryStore.dayKey(Date())

        Task { [weak self] in
            // Predictive mode if we stored a snapshot from ~window trading days ago; otherwise descriptive.
            var featureTable = live
            var mode = "Descriptive"
            var detail = "Today's filter values vs each stock's gain over the last \(window) trading days. This shows what recent gainers look like now — not yet what came before their rise. It switches to Predictive automatically once a snapshot from ~\(window) trading days ago is stored."
            var startDay: String?
            if let anySeries = book.series.values.max(by: { $0.days.count < $1.days.count }),
               let endIdx = anySeries.index(onOrBefore: endDay), endIdx - window >= 0 {
                let target = anySeries.days[endIdx - window]
                if let stored = days.last(where: { $0 <= target }), let past = await self?.loadAlignedDay(stored) {
                    featureTable = past
                    startDay = stored
                    mode = "Predictive"
                    detail = "Filter values on \(stored) vs the gain over the next \(window) trading days — the patterns that were present BEFORE the rise."
                }
            }

            let cols = featureNames.compactMap { featureTable.index(of: $0) }
            let names = cols.map { featureTable.headers[$0] }
            self?.nnStatus = "Finding monthly gainers…"
            let featureSource = featureTable, fromDay = startDay, modeName = mode, modeDetail = detail

            let result = await Task.detached(priority: .userInitiated) { () -> (NNReport, [String: Double]) in
                var data: [LabeledStock] = []
                for row in featureSource.rows {
                    let sym = row.text(label).trimmingCharacters(in: .whitespaces)
                    guard let s = book.series(for: sym) else { continue }
                    let gain: Double?
                    if let start = fromDay { gain = s.maxGain(within: window, after: start) }
                    else { gain = s.change(over: window, endingOn: endDay) }
                    guard let g = gain else { continue }
                    data.append(LabeledStock(symbol: sym, features: cols.map { row.number($0) },
                                             gain: g, isGainer: g >= threshold))
                }
                let gainers = data.filter(\.isGainer)

                // 1. Combinations of filter values shared by gainers
                let combos = PatternMiner.mine(data, featureCount: cols.count, names: names,
                                               minGainers: max(2, gainers.count / 20))

                // 2. Neural net: train on 80%, test on 20% (stratified), then retrain on all
                var rng = SeededRandom(seed: 42)
                var pos = data.indices.filter { data[$0].isGainer }.shuffled(using: &rng)
                var neg = data.indices.filter { !data[$0].isGainer }.shuffled(using: &rng)
                let testPos = Array(pos.prefix(max(1, pos.count / 5))), testNeg = Array(neg.prefix(neg.count / 5))
                pos.removeFirst(min(testPos.count, pos.count)); neg.removeFirst(min(testNeg.count, neg.count))
                let trainIdx = pos + neg, testIdx = testPos + testNeg

                var auc: Double?, p20: Double?
                var importance: [(String, Double)] = []
                if gainers.count >= 5 && trainIdx.count >= 30 && !cols.isEmpty {
                    var net = TinyNet(inputs: cols.count)
                    net.train(trainIdx.map { data[$0].features }, trainIdx.map { data[$0].isGainer }, epochs: 150)
                    let testX = testIdx.map { data[$0].features }, testY = testIdx.map { data[$0].isGainer }
                    let scores = testX.map { net.predict($0) }
                    let a = ModelMetrics.auc(scores, testY)
                    auc = a
                    p20 = ModelMetrics.precisionAtK(scores, testY, k: 20)
                    // Permutation importance: how much AUC drops when a column is scrambled
                    for (j, name) in names.enumerated() {
                        var shuffled = testX
                        var column = shuffled.map { $0[j] }
                        column.shuffle(using: &rng)
                        for k in shuffled.indices { shuffled[k][j] = column[k] }
                        let drop = a - ModelMetrics.auc(shuffled.map { net.predict($0) }, testY)
                        importance.append((name, drop))
                    }
                    importance.sort { $0.1 > $1.1 }
                }

                // Final model on all data → score today's stocks
                var scores: [String: Double] = [:]
                var top: [(String, Double)] = []
                if gainers.count >= 5 && !cols.isEmpty {
                    var net = TinyNet(inputs: cols.count)
                    net.train(data.map(\.features), data.map(\.isGainer), epochs: 150)
                    let liveCols = names.compactMap { live.index(of: $0) }
                    if liveCols.count == cols.count {
                        for row in live.rows {
                            let sym = row.text(label).trimmingCharacters(in: .whitespaces)
                            guard !sym.isEmpty else { continue }
                            scores[sym.uppercased()] = net.predict(liveCols.map { row.number($0) }) * 100
                        }
                        top = scores.sorted { $0.value > $1.value }.prefix(25).map { ($0.key, $0.value) }
                    }
                }

                let report = NNReport(mode: modeName, modeDetail: modeDetail, featureNames: names, stocks: data.count,
                                      gainers: gainers.count, threshold: threshold, windowDays: window,
                                      combos: combos, auc: auc, precisionTop20: p20, importance: importance,
                                      topScored: top,
                                      gainerList: gainers.sorted { $0.gain > $1.gain }.map { ($0.symbol, $0.gain) })
                return (report, scores)
            }.value

            guard let self else { return }
            self.nnReport = result.0
            self.nnScores = result.1
            self.isTraining = false
            self.nnStatus = nil
            if result.0.gainers == 0 {
                self.nnError = "No stock gained ≥ \(Int(threshold))% in the window — lower the threshold or fetch more history."
            }
            self.setTableKeepingRaw()      // adds / refreshes the NN_score column
        }
    }

    /// Every column with its kind (feature, price level, date…), for the training-column picker.
    var nnColumnProfiles: [ColumnProfile] {
        FeatureClassifier.profiles(table: table, label: labelIndex, filterColumns: filterColumnIndices)
    }

    /// Auto-pick: the Filter screen's columns that are features (no prices, dates, names, raw sizes).
    var nnAutoFeatures: [String] {
        let label = labelIndex
        let sample = Array(rows.prefix(1000))
        return filterColumnIndices.filter { c in
            FeatureClassifier.classify(name: headers[c], numbers: sample.map { $0.number(c) }, isLabel: c == label).0.isFeature
        }.map { headers[$0] }
    }

    /// Columns the model trains on: the ones you picked, or the auto-pick.
    var nnFeatureColumns: [String] {
        if !settings.nnFeatures.isEmpty { return settings.nnFeatures.filter { table.index(of: $0) != nil } }
        return nnAutoFeatures
    }

    /// Applies a found combination to the Filter screen.
    func applyCombo(_ combo: PatternCombo, names: [String]) {
        var g = FilterGroup(mode: .all)
        g.conditions = combo.items.flatMap { $0.filterConditions(names) }
        settings.filterGroup = g
    }

    func ruleFromCombo(_ combo: PatternCombo, names: [String]) {
        var rule = BuyTrigger(isEnabled: true, name: "Pattern: " + combo.items.map { $0.describe(names) }.joined(separator: " & "))
        rule.filter = FilterGroup(mode: .all, conditions: combo.items.flatMap { $0.filterConditions(names) })
        settings.buyTriggers.append(rule)
    }

    // Flash: what changed since the previous stored day

    func flashChangesSincePreviousDay() {
        guard hasData, timelineIndex == nil else { return }
        let current = HistoryStore.dayKey(dataDay(of: table))
        guard let prevDay = HistoryStore.days().last(where: { $0 < current }) else {
            flashSummary = nil
            return
        }
        let shownRows = filterRows
        let cols = filterColumnIndices
        let label = labelIndex
        Task { [weak self] in
            guard let self, let prev = await self.loadAlignedDay(prevDay), let label else { return }
            var prevBySymbol: [String: SheetRow] = [:]
            for r in prev.rows { prevBySymbol[r.text(label).uppercased()] = r }
            var cells: [Int: [Int: FlashKind]] = [:]
            var newRows = Set<Int>()
            var up = 0, down = 0
            for row in shownRows {
                guard let old = prevBySymbol[row.text(label).uppercased()] else { newRows.insert(row.id); continue }
                for c in cols where c != label {
                    if let a = row.number(c), let b = old.number(c) {
                        if a > b + 1e-9 { cells[row.id, default: [:]][c] = .up; up += 1 }
                        else if a < b - 1e-9 { cells[row.id, default: [:]][c] = .down; down += 1 }
                    } else if row.text(c) != old.text(c) {
                        cells[row.id, default: [:]][c] = .up; up += 1
                    }
                }
            }
            let date = HistoryStore.date(fromKey: prevDay)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? prevDay
            self.flashSummary = "Since \(date): ▲ \(up) values up · ▼ \(down) down · \(newRows.count) new stocks"
            self.flashToken += 1
            self.flashSpec = FlashSpec(token: self.flashToken, started: Date(), cells: cells, newRows: newRows)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self.flashSummary = nil
        }
    }
}

import Foundation

/// Result of the ranking model (stock × day panel).
struct PanelReport {
    var daysStored = 0
    var labeledDays = 0
    var rows = 0
    var stocks = 0
    var horizons: [Int] = []
    var mainHorizon = 0
    var gainerThreshold = 0.0
    var testMethod = ""
    var lowConfidence = true
    var metrics = PanelTrainer.Metrics()
    var luckICs: [Double] = []
    var beatsLuck = false
    var verdict = ""
    var pairs: [(String, String, Double)] = []
    var importance: [(String, Double)] = []
    var featureNames: [String] = []
    var members = 0
    var topScored: [(String, Double, Double)] = []      // symbol, score 0–100, confidence 0–100
    var combosTested = 0
    var combosHeldUp = 0
    var luckLift: Double?
}

extension ScreenerViewModel {

    /// Trains the ranking model on every stored snapshot that already has forward prices.
    /// Called at the end of "Learn patterns"; replaces NN_score and the combinations when it can run.
    func runPanelModel() async {
        guard let label = labelIndex else { return }
        let levelNames = nnFeatureColumns
        let current = table
        let cols = levelNames.compactMap { current.index(of: $0) }
        guard !cols.isEmpty else { return }
        let book = priceBook
        let window = max(2, settings.nnWindowDays)
        let threshold = Double(settings.nnGainThreshold)
        let liveKey = HistoryStore.dayKey(dataDay(of: table))
        let allDays = HistoryStore.days()
        let stored = Array(allDays.filter { $0 < liveKey }.suffix(400))   // past days; today is scored, not trained on
        let horizons = Array(Set([5, 10, window].filter { $0 <= window })).sorted()

        nnStatus = "Ranking model: reading \(stored.count) daily snapshots…"
        let values: [PanelBuilder.DayValues] = await Task.detached(priority: .userInitiated) {
            stored.map { day in
                HistoryStore.load(day).flatMap { ScreenerViewModel.align($0, to: current) }
                    .map { PanelBuilder.dayValues($0, label: label, cols: cols) } ?? [:]
            }
        }.value
        let liveValues = PanelBuilder.dayValues(current, label: label, cols: cols)

        nnStatus = "Ranking model: labelling gains…"
        let data = await Task.detached(priority: .userInitiated) {
            PanelBuilder.build(days: stored, values: values, book: book, levelNames: levelNames, horizons: horizons)
        }.value

        // Main horizon: the longest one with at least 3 labelled days.
        let labeledDays = horizons.indices.map { h in Set(data.rows.filter { $0.fwd[h] != nil }.map(\.day)).count }
        guard let main = horizons.indices.last(where: { labeledDays[$0] >= 3 }),
              data.rows.filter({ $0.fwd[main] != nil }).count >= 300 else {
            let need = horizons.first ?? 5
            nnReport?.panelNote = "Ranking model: needs at least 3 stored snapshots that are \(need)+ trading days old, with Yahoo prices after them. You have \(stored.count) past snapshot\(stored.count == 1 ? "" : "s") (\(labeledDays.first ?? 0) labelled). It turns on by itself as snapshots build up — keep the app running each trading day."
            return
        }
        let mainH = horizons[main]
        let thr = threshold * Double(mainH) / Double(window)

        nnStatus = "Ranking model: training \(6) nets on \(data.rows.count) stock-days…"
        let result = await Task.detached(priority: .userInitiated) { () -> (PanelReport, [PatternCombo], [String: Double], [String: Double]) in
            let rows = data.rows
            let labeled = rows.indices.filter { rows[$0].fwd[main] != nil }
            let ldays = Array(Set(labeled.map { rows[$0].day })).sorted()
            var report = PanelReport()
            report.daysStored = stored.count
            report.labeledDays = ldays.count
            report.rows = labeled.count
            report.stocks = Set(labeled.map { rows[$0].symbol }).count
            report.horizons = horizons
            report.mainHorizon = mainH
            report.gainerThreshold = thr
            report.featureNames = data.featureNames

            // Split: walk-forward when there are enough days, otherwise whole stocks held out.
            var trainIdx: [Int] = [], testIdx: [Int] = [], valIdx: [Int] = []
            if ldays.count >= 30 {
                let nTest = max(5, ldays.count / 4)
                let firstTest = ldays[ldays.count - nTest]
                for i in labeled {
                    let r = rows[i]
                    if r.day >= firstTest { testIdx.append(i) }
                    else if r.day < firstTest - mainH {            // gap so training gains don't overlap the test days
                        if (0.85..<1.0).contains(symbolBucket(r.symbol)) { valIdx.append(i) } else { trainIdx.append(i) }
                    }
                }
                report.testMethod = "Walk-forward: trained on \(ldays.count - nTest) earlier days, tested on the last \(nTest) days it never saw (\(mainH)-day gap between them)."
                report.lowConfidence = ldays.count < 60
            } else {
                for i in labeled {
                    let b = symbolBucket(rows[i].symbol)
                    if b < 0.2 { testIdx.append(i) } else if b < 0.35 { valIdx.append(i) } else { trainIdx.append(i) }
                }
                report.testMethod = "Held-out stocks: tested on 20% of stocks it never saw. Only \(ldays.count) labelled day\(ldays.count == 1 ? "" : "s"), so it can't yet test on later days (walk-forward starts at ~30 days)."
                report.lowConfidence = true
            }

            // Ensemble on the training split → test metrics
            let members = 6
            let nets = (0..<members).map { m in
                PanelTrainer.train(rows, train: trainIdx, val: valIdx, main: main, threshold: thr, seed: UInt64(101 + m * 17))
            }
            report.members = members
            let testRows = testIdx.map { rows[$0] }
            let testScores = PanelTrainer.ensembleScores(nets, xs: testRows.map(\.x), main: main)
            report.metrics = PanelTrainer.metrics(scores: testScores, rows: testRows, main: main, threshold: thr)

            // Chance check: train on shuffled gains, score the real test days
            for k in 0..<3 {
                let fake = PanelTrainer.shuffledLabels(rows, indices: trainIdx + valIdx, seed: UInt64(900 + k))
                let net = PanelTrainer.train(fake, train: trainIdx, val: valIdx, main: main, threshold: thr, seed: UInt64(500 + k))
                let s = PanelTrainer.ensembleScores([net], xs: testRows.map(\.x), main: main)
                report.luckICs.append(PanelTrainer.dailyIC(scores: s, rows: testRows, main: main).mean)
            }
            let luckMax = report.luckICs.max() ?? 0
            report.beatsLuck = report.metrics.ic > luckMax && report.metrics.ic > 0.02
            report.verdict = report.beatsLuck
                ? "Beats luck: ranks the unseen \(report.metrics.testDays > 0 ? "days" : "stocks") better than all \(report.luckICs.count) shuffled-label runs."
                : "Not yet better than luck: shuffled-label runs scored about as well. Treat NN_score as noise for now."

            // Permutation importance (first 3 members, ≤4000 test rows)
            let sample = Array(testRows.prefix(4000))
            let few = Array(nets.prefix(3))
            let baseIC = PanelTrainer.dailyIC(scores: PanelTrainer.ensembleScores(few, xs: sample.map(\.x), main: main), rows: sample, main: main).mean
            var rng = SeededRandom(seed: 77)
            for (j, name) in data.featureNames.enumerated() {
                var xs = sample.map(\.x)
                let col = xs.map { $0[j] }.shuffled(using: &rng)
                for i in xs.indices { xs[i][j] = col[i] }
                let ic = PanelTrainer.dailyIC(scores: PanelTrainer.ensembleScores(few, xs: xs, main: main), rows: sample, main: main).mean
                report.importance.append((name, baseIC - ic))
            }
            report.importance.sort { $0.1 > $1.1 }

            // Final ensemble on all labelled days → today's scores and the pair weights
            var finalTrain: [Int] = [], finalVal: [Int] = []
            for i in labeled { if (0.85..<1.0).contains(symbolBucket(rows[i].symbol)) { finalVal.append(i) } else { finalTrain.append(i) } }
            let finals = (0..<members).map { m in
                PanelTrainer.train(rows, train: finalTrain, val: finalVal, main: main, threshold: thr, seed: UInt64(2001 + m * 31))
            }
            let d = data.featureNames.count
            var pairs: [(String, String, Double)] = []
            for i in 0..<d { for j in (i + 1)..<max(i + 1, d) {
                let w = finals.reduce(0) { $0 + $1.pairWeight(i, j) } / Double(finals.count)
                pairs.append((data.featureNames[i], data.featureNames[j], w))
            } }
            report.pairs = Array(pairs.sorted { abs($0.2) > abs($1.2) }.prefix(20))

            // Today: Δ features from the last stored snapshots
            let symbols = liveValues.keys.sorted()
            let prev1 = values.last, prev5 = values.count >= 5 ? values[values.count - 5] : nil
            let xs = PanelBuilder.features(today: liveValues, prev1: prev1, prev5: prev5, symbols: symbols, columns: levelNames.count)
            var memberRanks: [[Double]] = []
            for net in finals { memberRanks.append(PanelBuilder.ranks(xs.map { Optional(net.predict($0)[main]) }).map { ($0 + 1) / 2 }) }
            var scores: [String: Double] = [:], conf: [String: Double] = [:]
            for (i, sym) in symbols.enumerated() {
                let r = memberRanks.map { $0[i] }
                let mean = r.reduce(0, +) / Double(r.count)
                let sd = sqrt(r.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(r.count))
                scores[sym] = mean * 100
                conf[sym] = max(0, 1 - sd / 0.29) * 100
            }
            report.topScored = scores.sorted { $0.value > $1.value }.prefix(25).map { ($0.key, $0.value, conf[$0.key] ?? 0) }

            // Combinations: found on training days, checked on test days, compared with luck
            func labeledStocks(_ idx: [Int], _ src: [PanelRow]) -> [LabeledStock] {
                idx.map { LabeledStock(symbol: src[$0].symbol, features: src[$0].raw, gain: src[$0].fwdMax[main] ?? 0,
                                       isGainer: PanelTrainer.isGainer(src[$0], main: main, threshold: thr)) }
            }
            var mineIdx = trainIdx + valIdx
            if mineIdx.count > 50_000 { var r2 = SeededRandom(seed: 5); mineIdx = Array(mineIdx.shuffled(using: &r2).prefix(50_000)) }
            let mineSet = labeledStocks(mineIdx, rows)
            let g = mineSet.filter(\.isGainer).count
            let minG = max(3, g / 25)
            var combos = PatternMiner.mine(mineSet, featureCount: levelNames.count, names: levelNames, minGainers: minG, limit: 200)
            let luckSet = labeledStocks(mineIdx, PanelTrainer.shuffledLabels(rows, indices: mineIdx, seed: 4242))
            let luckLift = PatternMiner.mine(luckSet, featureCount: levelNames.count, names: levelNames, minGainers: minG, limit: 50).map(\.lift).max()
            report.luckLift = luckLift
            let testSet = labeledStocks(testIdx, rows)
            let testBase = Double(testSet.filter(\.isGainer).count) / Double(max(1, testSet.count))
            for k in combos.indices {
                let with = testSet.filter { s in combos[k].items.allSatisfy { $0.test(s.features[$0.feature]) } }
                if with.count >= 3, testBase > 0 {
                    combos[k].testLift = (Double(with.filter(\.isGainer).count) / Double(with.count)) / testBase
                }
                combos[k].heldUp = (combos[k].testLift ?? 0) >= 1.2 && combos[k].lift > (luckLift ?? 1)
            }
            combos.sort { a, b in
                if (a.heldUp ?? false) != (b.heldUp ?? false) { return a.heldUp ?? false }
                return (a.testLift ?? 0) > (b.testLift ?? 0)
            }
            report.combosTested = combos.count
            report.combosHeldUp = combos.filter { $0.heldUp == true }.count
            return (report, combos, scores, conf)
        }.value

        nnReport?.panel = result.0
        nnReport?.panelNote = nil
        if !result.1.isEmpty { nnReport?.combos = result.1; nnReport?.featureNames = levelNames }
        nnScores = result.2
        nnConf = result.3
    }
}

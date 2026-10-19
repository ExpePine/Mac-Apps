import Foundation

struct GainerRow {
    let row: SheetRow
    let symbol: String
    let change: Double
    let close: Double?
    let fromYahoo: Bool
}

extension ScreenerViewModel {
    static let sensexSymbol = "^BSESN"

    /// Trading days available for the gainers screen (newest first), from the Nifty's Yahoo history.
    var gainerDays: [String] {
        Array((priceBook.series(for: Self.benchmarkSymbol)?.days ?? []).suffix(60).reversed())
    }

    var currentGainerDay: String {
        gainersDay ?? priceBook.series(for: Self.benchmarkSymbol)?.lastDay ?? HistoryStore.dayKey(dataDay(of: table))
    }

    var companyNameIndex: Int? {
        if !settings.companyNameColumn.isEmpty { return table.index(of: settings.companyNameColumn) }
        return headers.firstIndex { ["company", "company name", "name of company", "companyname"].contains($0.lowercased()) }
    }

    /// Advancers / decliners among all sheet stocks on `day`.
    func breadth(on day: String) -> (up: Int, down: Int) {
        guard let label = labelIndex else { return (0, 0) }
        var up = 0, down = 0
        for r in table.rows {
            if let c = priceBook.series(for: r.text(label))?.dailyChange(on: day) { if c > 0 { up += 1 } else if c < 0 { down += 1 } }
        }
        return (up, down)
    }

    /// Sheet stocks up ≥ threshold on `day` (Yahoo close-to-close; the sheet's change% column as a fallback).
    func gainers(on day: String) -> [GainerRow] {
        guard let label = labelIndex else { return [] }
        let changes = tgChanges(for: table, day: day)
        let sheetDay = HistoryStore.dayKey(dataDay(of: table))
        return table.rows.compactMap { r in
            guard let ch = changes[r.id], ch.0 >= settings.gainersThreshold else { return nil }
            let c = ch.0, yahoo = ch.1
            if !yahoo && day != sheetDay { return nil }        // the sheet's change% only describes its own data day
            let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            let s = priceBook.series(for: sym)
            let close = s?.index(onOrBefore: day).map { s!.closes[$0] }
            return GainerRow(row: r, symbol: sym, change: c, close: close, fromYahoo: yahoo)
        }.sorted { $0.change > $1.change }
    }

    func reason(_ symbol: String, day: String) -> String? { newsCache.reasons["\(day)|\(symbol)"] }

    // MARK: Index charts

    func refreshIndexCharts() async {
        for sym in [Self.benchmarkSymbol, Self.sensexSymbol] {
            if let s = try? await YahooClient.intraday(sym) { indexIntraday[sym] = s }
        }
        if priceBook.series(for: Self.sensexSymbol) == nil || (priceBook.series(for: Self.sensexSymbol)?.lastDay ?? "") < (priceBook.series(for: Self.benchmarkSymbol)?.lastDay ?? "") {
            if let s = try? await YahooClient.daily(Self.sensexSymbol, range: "6mo") {
                var b = priceBook
                b.series[Self.sensexSymbol] = b.series[Self.sensexSymbol].map { $0.merged(with: s) } ?? s
                priceBook = b
            }
        }
    }

    // MARK: News + Groq

    /// Fetches headlines and asks Groq for a 5–10 word reason per gainer (cached per day).
    func explainGainers(_ rows: [GainerRow], day: String, force: Bool = false) {
        guard !isExplaining else { return }
        guard !settings.groqModel.isEmpty else { newsStatus = "Pick a Groq model in News & AI settings."; return }
        guard !GroqClient.apiKey.isEmpty else { newsStatus = "Add your Groq API key in News & AI settings."; return }
        let todo = rows.filter { force || reason($0.symbol, day: day) == nil }
        guard !todo.isEmpty else { newsStatus = "All reasons already fetched for \(day)."; return }
        isExplaining = true
        newsStatus = nil
        explainProgress = (0, todo.count)
        let provider = settings.newsProvider, model = settings.groqModel
        let nameCol = companyNameIndex
        Task { [weak self] in
            guard let self else { return }
            var done = 0
            var failures = 0
            for chunk in stride(from: 0, to: todo.count, by: 8).map({ Array(todo[$0..<min($0 + 8, todo.count)]) }) {
                var batch: [(symbol: String, move: Double, headlines: [Headline])] = []
                for g in chunk {
                    let key = "\(day)|\(g.symbol)"
                    var heads = self.newsCache.headlines[key] ?? []
                    if heads.isEmpty || force {
                        heads = await NewsClient.headlines(symbol: g.symbol, name: nameCol.map { g.row.text($0) }, provider: provider)
                        self.newsCache.headlines[key] = heads
                        try? await Task.sleep(nanoseconds: 300_000_000)          // be gentle with the news source
                    }
                    batch.append((g.symbol, g.change, heads))
                }
                do {
                    let reasons = try await GroqClient.explain(model: model, stocks: batch)
                    for g in chunk { self.newsCache.reasons["\(day)|\(g.symbol)"] = reasons[g.symbol] ?? "No clear news; likely sector or technical move" }
                } catch {
                    failures += 1
                    self.newsStatus = error.localizedDescription
                    if failures >= 2 { break }
                }
                done += chunk.count
                self.explainProgress = (done, todo.count)
            }
            self.newsCache.save()
            self.isExplaining = false
            self.explainProgress = nil
        }
    }
}

// MARK: - Index reasons & sector rotation for gainers

extension ScreenerViewModel {
    static let indexNames: [(name: String, symbol: String, query: String)] = [
        ("NIFTY 50", ScreenerViewModel.benchmarkSymbol, "Nifty 50 today stock market"),
        ("SENSEX", ScreenerViewModel.sensexSymbol, "Sensex today stock market"),
    ]

    /// The index's move on `day` (today's live move when it's the latest day).
    func indexMove(_ symbol: String, day: String) -> Double? {
        let daily = priceBook.series(for: symbol)
        if day == daily?.lastDay || gainersDay == nil, let live = indexIntraday[symbol]?.change { return live }
        return daily?.dailyChange(on: day)
    }

    /// 5–10 word reasons for the NIFTY 50 and SENSEX moves (news + Groq), cached per day.
    func explainIndices(day: String, force: Bool = false) {
        guard !settings.groqModel.isEmpty, !GroqClient.apiKey.isEmpty else { return }
        let todo = Self.indexNames.filter { force || reason($0.name, day: day) == nil }
        guard !todo.isEmpty else { return }
        let model = settings.groqModel
        Task { [weak self] in
            guard let self else { return }
            var batch: [(symbol: String, move: Double, headlines: [Headline])] = []
            for ix in todo {
                let key = "\(day)|\(ix.name)"
                var heads = self.newsCache.headlines[key] ?? []
                if heads.isEmpty || force {
                    heads = await NewsClient.market(ix.query)
                    self.newsCache.headlines[key] = heads
                }
                batch.append((ix.name, self.indexMove(ix.symbol, day: day) ?? 0, heads))
            }
            do {
                let reasons = try await GroqClient.explain(model: model, stocks: batch)
                for ix in todo {
                    self.newsCache.reasons["\(day)|\(ix.name)"] = reasons[ix.name.uppercased()] ?? reasons[ix.name] ?? "No clear news; likely global or flow-driven move"
                }
                self.newsCache.save()
            } catch {
                self.newsStatus = error.localizedDescription
            }
        }
    }

    /// The gainer's sector on the rotation map that day: quadrant, trend, score, and (latest day only) rank.
    func sectorRotation(_ sector: String, day: String) -> (quadrant: Quadrant, trend: Trend, score: Double, rank: Int?)? {
        guard let s = sectorReport?.sectors.first(where: { $0.name == sector }) else { return nil }
        let isLatest = day >= (s.history.last?.day ?? "")
        if let st = s.history.last(where: { $0.day <= day }) {
            return (st.quadrant, st.trend, st.score, isLatest ? s.rank : nil)
        }
        return (s.quadrant, s.trend, s.score, s.rank)
    }

    static func quadrantLabel(_ q: Quadrant) -> String {
        switch q {
        case .leading: return "🟢 Leading"
        case .improving: return "🔵 Improving"
        case .weakening: return "🟠 Weakening"
        case .lagging: return "🔴 Lagging"
        }
    }
}

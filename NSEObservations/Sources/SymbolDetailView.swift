import SwiftUI

private enum DetailTab: String, CaseIterable, Identifiable {
    case notes = "Observations", shots = "Screenshots", news = "News", trades = "Trades", ai = "AI Analysis"
    var id: String { rawValue }
}

private enum ActiveSheet: Identifiable {
    case newObservation
    case editObservation(Observation)
    case newTrade
    case editTrade(Trade)
    case editSymbol
    case newNews
    case editNews(NewsItem)
    case editShot(UUID)

    var id: String {
        switch self {
        case .newObservation: return "newObs"
        case .editObservation(let o): return "obs-\(o.id)"
        case .newTrade: return "newTrade"
        case .editTrade(let t): return "trade-\(t.id)"
        case .editSymbol: return "symbol"
        case .newNews: return "newNews"
        case .editNews(let n): return "news-\(n.id)"
        case .editShot(let id): return "shot-\(id)"
        }
    }
}

struct SymbolDetailView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var directory: SymbolDirectory
    let symbolID: UUID
    /// Optional tab to open first, e.g. "Screenshots".
    var initialTab: String? = nil

    @State private var series: QuoteSeries?
    @State private var loading = false
    @State private var loadError: String?
    @State private var range: ChartRange = .notes
    @State private var style: ChartStyle = .line
    @State private var tab: DetailTab = .notes
    @State private var sheet: ActiveSheet?
    @State private var aiBusy: AnalysisKind?
    @State private var aiError: String?

    private var symbol: TrackedSymbol? { store.symbol(symbolID) }
    private var observations: [Observation] { store.observations(for: symbolID) }
    private var trades: [Trade] { store.trades(for: symbolID) }
    private var candles: [Candle] { series?.candles ?? [] }
    private var firstNoteDate: Date? { observations.map(\.date).min() }

    private var visibleCandles: [Candle] {
        let start = Calendar.ist.startOfDay(for: range.startDate(firstNote: firstNoteDate))
        return candles.filter { $0.date >= start }
    }

    var body: some View {
        if let symbol {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(symbol)
                    stats
                    chartCard
                    Picker("Section", selection: $tab) {
                        ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 640)
                    .id("tabs")

                    switch tab {
                    case .notes: notesSection
                    case .trades: tradesSection
                    case .shots: ChartShotsSection(symbolID: symbolID, candles: candles) { sheet = .editShot($0) }
                    case .news: newsSection
                    case .ai: aiSection(symbol)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if initialTab != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("tabs", anchor: .top) }
                }
            }
            }
            .navigationTitle(symbol.ticker)
            .toolbar {
                ToolbarItemGroup {
                    Button { Task { await load(force: true) } } label: {
                        Label("Refresh Prices", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh prices from Yahoo Finance")
                    Button { sheet = .editSymbol } label: {
                        Label("Edit Symbol", systemImage: "info.circle")
                    }
                    .help("Edit name, list, tags and thesis")
                    Button { sheet = .newObservation } label: {
                        Label("New Observation", systemImage: "square.and.pencil")
                    }
                    .help("New Observation (⌘N)")
                }
            }
            .task { await load(force: false) }
            .onAppear { if let t = initialTab, let dt = DetailTab(rawValue: t) { tab = dt } }
            .onReceive(NotificationCenter.default.publisher(for: .newObservation)) { _ in
                sheet = .newObservation
            }
            .sheet(item: $sheet) { s in
                Group {
                    switch s {
                    case .newObservation: ObservationEditor(symbolID: symbolID, existing: nil)
                    case .editObservation(let o): ObservationEditor(symbolID: symbolID, existing: o)
                    case .newTrade: TradeEditor(symbolID: symbolID, existing: nil)
                    case .editTrade(let t): TradeEditor(symbolID: symbolID, existing: t)
                    case .editSymbol: SymbolEditor(existing: symbol)
                    case .newNews: NewsEditor(existing: nil, defaultSymbolID: symbolID)
                    case .editNews(let n): NewsEditor(existing: n)
                    case .editShot(let id): ChartShotEditor(shotID: id)
                    }
                }
                .environmentObject(store)
                .environmentObject(directory)
            }
        }
    }

    // MARK: Header

    private func header(_ s: TrackedSymbol) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(s.ticker)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Menu {
                        ForEach(SymbolStatus.allCases) { st in
                            Button { store.setStatus(st, for: s.id) } label: {
                                Label(st.title, systemImage: st.systemImage)
                            }
                        }
                    } label: {
                        Label(s.status.title, systemImage: s.status.systemImage)
                            .font(.callout.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(s.status.tint)
                }
                if !s.displayName.isEmpty {
                    Text(s.displayName).font(.title3).foregroundStyle(.secondary)
                }
                if !s.tags.isEmpty { TagChips(tags: s.tags) }
                if !s.thesis.isEmpty {
                    Text(s.thesis)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let last = candles.last {
                    Text(Fmt.rupees(last.close))
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    if candles.count > 1 {
                        let prev = candles[candles.count - 2].close
                        let ch = (last.close - prev) / prev * 100
                        Text("\(Fmt.pct(ch)) on the day")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(ch.changeColor)
                    }
                    Text("Close \(Fmt.day.string(from: last.date)) · Yahoo Finance")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else if let loadError {
                    InlineError(message: loadError).frame(maxWidth: 320)
                }
            }
        }
    }

    // MARK: Stats

    private var stats: some View {
        let last = candles.last?.close
        let firstOutcome = firstNoteDate.flatMap { ObservationOutcome.compute(for: $0, candles: candles) }
        let lastNote = observations.first
        let lastOutcome = lastNote.flatMap { ObservationOutcome.compute(for: $0.date, candles: candles) }
        let pos = store.position(for: symbolID)

        return HStack(spacing: 10) {
            StatTile(title: "Since first note",
                     value: Fmt.pct(firstOutcome?.sinceThen),
                     detail: firstNoteDate.map { Fmt.day.string(from: $0) } ?? "No notes yet",
                     tint: firstOutcome?.sinceThen.changeColor ?? .primary)
            StatTile(title: "Since last note",
                     value: Fmt.pct(lastOutcome?.sinceThen),
                     detail: lastNote.map { "\($0.sentiment.title) · \(Fmt.day.string(from: $0.date))" } ?? "—",
                     tint: lastOutcome?.sinceThen.changeColor ?? .primary)
            StatTile(title: "Observations", value: "\(observations.count)",
                     detail: "\(trades.count) trade\(trades.count == 1 ? "" : "s")")
            if let pos {
                let pnl = last.map { ($0 - pos.avg) / pos.avg * 100 }
                StatTile(title: "Position",
                         value: "\(AIContext.formatQty(pos.qty)) @ \(Fmt.rupees(pos.avg))",
                         detail: pnl.map { "Unrealised \(Fmt.pct($0))" },
                         tint: .primary)
            }
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Range", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                    Spacer()
                    Picker("Style", selection: $style) {
                        ForEach(ChartStyle.allCases) { Image(systemName: $0.systemImage).help($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 90)
                }

                ZStack {
                    if visibleCandles.isEmpty {
                        VStack(spacing: 6) {
                            if loading {
                                ProgressView()
                                Text("Loading prices…").foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "chart.line.downtrend.xyaxis").font(.title).foregroundStyle(.tertiary)
                                Text(loadError ?? "No price data for this range.")
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Try Again") { Task { await load(force: true) } }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PriceChartView(candles: visibleCandles, observations: observations, trades: trades,
                                       shots: store.chartShots(for: symbolID), style: style)
                    }
                }
                .frame(height: 300)

                HStack(spacing: 14) {
                    ForEach(Sentiment.allCases) { s in
                        HStack(spacing: 4) {
                            Circle().fill(s.color).frame(width: 7, height: 7)
                            Text("\(s.title) note").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "triangle.fill").font(.system(size: 7)).foregroundStyle(.secondary)
                        Text("Trade").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "square.fill").font(.system(size: 7)).foregroundStyle(Color.blue)
                        Text("Screenshot").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Daily data, unofficial Yahoo Finance feed — verify important levels on NSE.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Observations

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(observations.count) observation\(observations.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button { sheet = .newObservation } label: {
                    Label("New Observation", systemImage: "plus")
                }
            }
            if observations.isEmpty {
                Card {
                    Text("No observations yet. Each time you revisit this chart, jot down what you see — the date is saved with it, so you can later compare your read with what the price did.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(observations) { o in
                ObservationCard(observation: o,
                                outcome: ObservationOutcome.compute(for: o.date, candles: candles),
                                onEdit: { sheet = .editObservation(o) },
                                onDelete: { store.deleteObservation(o.id) })
            }
        }
    }

    // MARK: News

    private var newsSection: some View {
        let items = store.news(for: nil).filter { $0.symbolID == symbolID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(items.count) news summar\(items.count == 1 ? "y" : "ies")").font(.headline)
                Spacer()
                Button { sheet = .newNews } label: { Label("Add News Summary", systemImage: "plus") }
            }
            if items.isEmpty {
                Card {
                    Text("Paste news summaries you gather (from ChatGPT, Perplexity or news sites) to keep them next to your chart notes. The AI features read them too.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(items) { n in
                NewsCard(item: n, outcome: ObservationOutcome.compute(for: n.date, candles: candles), showSymbol: false) {
                    sheet = .editNews(n)
                }
            }
        }
    }

    // MARK: Trades

    private var tradesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trades").font(.headline)
                Spacer()
                Button { sheet = .newTrade } label: { Label("Log Trade", systemImage: "plus") }
            }
            if trades.isEmpty {
                Card { Text("No trades logged. Log buys and sells to see them on the chart and in the AI comparison.").foregroundStyle(.secondary) }
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(trades.reversed()) { t in
                            HStack {
                                Text(t.side.title.uppercased())
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(t.side.color)
                                    .frame(width: 40, alignment: .leading)
                                Text(Fmt.day.string(from: t.date)).frame(width: 100, alignment: .leading)
                                Text("\(AIContext.formatQty(t.quantity)) @ \(Fmt.rupees(t.price))").monospacedDigit()
                                if let last = candles.last?.close, t.side == .buy {
                                    Text(Fmt.pct((last - t.price) / t.price * 100))
                                        .monospacedDigit()
                                        .foregroundStyle(((last - t.price) / t.price).changeColor)
                                }
                                Text(t.note).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button { sheet = .editTrade(t) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless)
                                Button(role: .destructive) { store.deleteTrade(t.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 6)
                            if t.id != trades.first?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: AI

    private func aiSection(_ s: TrackedSymbol) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { Task { await runAI(.summary, symbol: s) } } label: {
                    Label("Summarize My Notes", systemImage: "text.badge.star")
                }
                .disabled(aiBusy != nil || observations.isEmpty)
                Button { Task { await runAI(.priceComparison, symbol: s) } } label: {
                    Label("Compare Notes with Price", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(aiBusy != nil || observations.isEmpty || candles.isEmpty)
                if let aiBusy {
                    ProgressView().controlSize(.small)
                    Text("Asking Groq for a \(aiBusy.title.lowercased())…").foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !settings.hasKey {
                InlineError(message: "Add your Groq API key in Settings (⌘,) to use AI analysis.")
            }
            if let aiError { InlineError(message: aiError) }

            ForEach([AnalysisKind.summary, .priceComparison], id: \.self) { kind in
                let items = store.analyses(for: symbolID, kind: kind)
                if let latest = items.first {
                    AnalysisCard(analysis: latest) { store.deleteAnalysis(latest.id) }
                    if items.count > 1 {
                        DisclosureGroup("Earlier \(kind.title.lowercased()) runs (\(items.count - 1))") {
                            VStack(spacing: 10) {
                                ForEach(items.dropFirst()) { a in
                                    AnalysisCard(analysis: a) { store.deleteAnalysis(a.id) }
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func load(force: Bool) async {
        guard let s = symbol else { return }
        loading = true
        defer { loading = false }
        let dates = observations.map(\.date) + trades.map(\.date)
        let fiveYears = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date()
        let from = min(fiveYears, (dates.min() ?? Date()).addingTimeInterval(-45 * 86_400))
        do {
            let result = try await MarketDataService.shared.series(for: s.yahooSymbol, from: from, force: force)
            series = result
            loadError = nil
            if s.displayName.isEmpty, let n = result.name, var current = store.symbol(symbolID) {
                current.displayName = n
                store.upsert(current)
            }
        } catch {
            loadError = "Couldn't load prices for \(s.yahooSymbol): \(error.localizedDescription)"
        }
    }

    private func runAI(_ kind: AnalysisKind, symbol s: TrackedSymbol) async {
        aiBusy = kind
        aiError = nil
        defer { aiBusy = nil }
        let block = AIContext.symbolBlock(s, store: store, series: series, includeOutcomes: kind == .priceComparison)
        let trimmed = String(block.prefix(Int(settings.contextBudget)))
        let prompt = kind == .summary ? AIContext.summaryPrompt(trimmed) : AIContext.comparisonPrompt(trimmed)
        let model = settings.model
        do {
            let text = try await GroqClient.complete(
                messages: [GroqMessage(role: "system", content: AIContext.analystRole),
                           GroqMessage(role: "user", content: prompt)],
                model: model)
            store.add(SavedAnalysis(kind: kind, symbolID: s.id, text: text, model: model))
        } catch {
            aiError = error.localizedDescription
        }
    }
}

// MARK: - Observation card

struct ObservationCard: View {
    let observation: Observation
    let outcome: ObservationOutcome?
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(observation.sentiment.title, systemImage: observation.sentiment.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(observation.sentiment.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(observation.sentiment.color.opacity(0.12), in: Capsule())
                    Text(Fmt.dayTime.string(from: observation.date))
                        .font(.subheadline.weight(.semibold))
                    Text("· \(observation.timeframe.title) chart")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let p = observation.notedPrice {
                        Text("· saw \(Fmt.rupees(p))").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Edit…", action: onEdit)
                        Button("Delete…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Text(observation.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !observation.tags.isEmpty { TagChips(tags: observation.tags) }

                if !observation.imageFiles.isEmpty { AttachmentThumbnails(names: observation.imageFiles) }

                if let oc = outcome {
                    HStack(spacing: 14) {
                        outcomeItem("Since", oc.sinceThen)
                        outcomeItem("5 sessions", oc.after5)
                        outcomeItem("20 sessions", oc.after20)
                        outcomeItem("Best", oc.maxUp)
                        outcomeItem("Worst", oc.maxDown)
                        Spacer()
                        Text("from close \(Fmt.rupees(oc.referenceClose))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete this observation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func outcomeItem(_ title: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(Fmt.pct(v))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(v?.changeColor ?? .secondary)
        }
    }
}

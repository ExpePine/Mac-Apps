import SwiftUI
import AppKit

// MARK: - Editor

struct NewsEditor: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    @Environment(\.dismiss) private var dismiss

    let existing: NewsItem?
    var defaultSymbolID: UUID? = nil

    @State private var stockQuery = ""
    @State private var chosenTicker: String?
    @State private var chosenName = ""
    @State private var tags: Set<NewsTag> = []
    @State private var date = Date()
    @State private var title = ""
    @State private var source = ""
    @State private var text = ""
    @FocusState private var stockFocused: Bool

    private let sourceSuggestions = ["ChatGPT", "Perplexity", "Claude", "Gemini", "Moneycontrol", "Economic Times", "Business Standard"]

    /// Journal symbols first, then the rest of the NSE list.
    private var suggestions: [ListedSymbol] {
        guard chosenTicker?.uppercased() != stockQuery.uppercased() else { return [] }
        let q = stockQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let journal = store.symbols
            .filter { $0.ticker.localizedCaseInsensitiveContains(q) || $0.displayName.localizedCaseInsensitiveContains(q) }
            .prefix(4)
            .map { ListedSymbol(symbol: $0.ticker, name: $0.displayName, series: "") }
        let listed = directory.search(q, limit: 8).filter { l in !journal.contains { $0.symbol == l.symbol } }
        return Array((journal + listed).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add News Summary" : "Edit News Summary")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Stock").font(.callout).foregroundStyle(.secondary)
                TextField("Stock", text: $stockQuery, prompt: Text("Type a symbol or company, e.g. RELIANCE, tata"))
                    .textFieldStyle(.roundedBorder)
                    .focused($stockFocused)
                    .onSubmit { if let first = suggestions.first { pick(first) } }
                if !suggestions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(suggestions) { item in
                            Button { pick(item) } label: {
                                HStack(spacing: 10) {
                                    Text(item.symbol).font(.system(.body, design: .rounded).weight(.semibold))
                                        .frame(minWidth: 110, alignment: .leading)
                                    Text(item.name).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    if store.existingSymbol(ticker: item.symbol) != nil {
                                        Text("In journal").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if item.id != suggestions.last?.id { Divider().padding(.leading, 10) }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
                } else if let t = chosenTicker {
                    Label("\(t)\(chosenName.isEmpty ? "" : " — \(chosenName)")\(store.existingSymbol(ticker: t) == nil ? " · will be added to Watching" : "")",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(NewsTag.allCases) { tag in
                        let on = tags.contains(tag)
                        Button {
                            if on { tags.remove(tag) } else { tags.insert(tag) }
                        } label: {
                            Label(tag.title, systemImage: tag.systemImage)
                                .font(.callout.weight(on ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .foregroundStyle(on ? Color.white : tag.color)
                                .background(on ? tag.color : tag.color.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Form {
                DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                TextField("Headline", text: $title, prompt: Text("Short title, e.g. Q2 results beat estimates"))
                HStack {
                    TextField("Source", text: $source, prompt: Text("Where the summary came from"))
                    Menu("Pick") {
                        ForEach(sourceSuggestions, id: \.self) { s in Button(s) { source = s } }
                    }
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Summary").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) { text = text.isEmpty ? s : text + "\n\n" + s }
                    } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .controlSize(.small)
                }
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                Text("Saved summaries and their tags are included when you use the AI features.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenTicker == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear {
            let symbolID = existing?.symbolID ?? defaultSymbolID
            if let id = symbolID, let s = store.symbol(id) {
                chosenTicker = s.ticker; chosenName = s.displayName; stockQuery = s.ticker
            } else {
                stockFocused = true
            }
            if let e = existing {
                date = e.date; title = e.title; source = e.source; text = e.text
                tags = Set(e.newsTags)
            }
        }
    }

    private func pick(_ item: ListedSymbol) {
        chosenTicker = item.symbol
        chosenName = item.name
        stockQuery = item.symbol
        stockFocused = false
    }

    private func save() {
        guard let ticker = chosenTicker else { return }
        // The stock may not be in the journal yet: add it to Watching.
        let symbol: TrackedSymbol
        if let s = store.existingSymbol(ticker: ticker) {
            symbol = s
        } else {
            let s = TrackedSymbol(ticker: ticker, displayName: chosenName, status: .watching)
            store.upsert(s)
            symbol = s
        }
        var n = existing ?? NewsItem()
        n.symbolID = symbol.id
        n.date = date
        n.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        n.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        n.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        n.tags = tags.isEmpty ? nil : NewsTag.allCases.filter { tags.contains($0) }.map(\.rawValue)
        if n.title.isEmpty {
            // Use the first line of the summary as a headline.
            n.title = String(n.text.split(separator: "\n").first?.prefix(90) ?? "News")
        }
        store.upsert(n)
        dismiss()
    }
}

/// Small coloured chips for news tags.
struct NewsTagChips: View {
    let tags: [NewsTag]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags) { t in
                Label(t.title, systemImage: t.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(t.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(t.color.opacity(0.12), in: Capsule())
            }
        }
    }
}

// MARK: - Card

struct NewsCard: View {
    @EnvironmentObject private var store: Store
    let item: NewsItem
    var outcome: ObservationOutcome? = nil
    var showSymbol = true
    var openSymbol: ((UUID) -> Void)? = nil
    var onEdit: () -> Void

    @State private var expanded = false
    @State private var confirmDelete = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "newspaper").foregroundStyle(.secondary)
                    Text(item.title).font(.headline).lineLimit(2)
                    Spacer()
                    Menu {
                        Button("Edit…", action: onEdit)
                        Button("Copy Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.text, forType: .string)
                        }
                        Button("Delete…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(Fmt.dayTime.string(from: item.date))
                    if !item.source.isEmpty { Text("· \(item.source)") }
                    if showSymbol {
                        if let id = item.symbolID, let s = store.symbol(id) {
                            Button(s.ticker) { openSymbol?(id) }
                                .buttonStyle(.link)
                                .disabled(openSymbol == nil)
                        } else if item.symbolID == nil {
                            Text("· Market").foregroundStyle(.tertiary)
                        }
                    }
                    if let oc = outcome {
                        Text("· since then \(Fmt.pct(oc.sinceThen))").foregroundStyle(oc.sinceThen.changeColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !item.newsTags.isEmpty { NewsTagChips(tags: item.newsTags) }

                Text(item.text)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                if item.text.count > 320 || item.text.filter({ $0 == "\n" }).count > 4 {
                    Button(expanded ? "Show less" : "Show more") { withAnimation { expanded.toggle() } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete this news summary?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.deleteNews(item.id) }
        }
    }
}

// MARK: - News page (all symbols)

struct NewsListView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    var openSymbol: (UUID) -> Void

    private enum Filter: Hashable { case all, market, symbol(UUID) }
    @State private var filter: Filter = .all
    /// nil = all tags.
    @State private var tagFilter: NewsTag?
    @State private var editing: NewsItem?
    @State private var adding = false
    @State private var series: [String: QuoteSeries] = [:]

    private var items: [NewsItem] {
        store.news(for: nil).filter {
            switch filter {
            case .all: return true
            case .market: return $0.symbolID == nil
            case .symbol(let id): return $0.symbolID == id
            }
        }
        .filter { tagFilter == nil || $0.newsTags.contains(tagFilter!) }
    }

    private var hasMarketNews: Bool { store.data.news.contains { $0.symbolID == nil } }

    /// For each tag: how many summaries, and the average move of the stock since the news.
    private struct TagStat: Identifiable {
        let tag: NewsTag
        let count: Int
        let avg: Double?
        var id: String { tag.rawValue }
    }

    private var tagStats: [TagStat] {
        NewsTag.allCases.map { tag in
            let tagged = store.data.news.filter { $0.newsTags.contains(tag) }
            let moves = tagged.compactMap { outcome(for: $0)?.sinceThen }
            return TagStat(tag: tag, count: tagged.count, avg: moves.isEmpty ? nil : moves.reduce(0, +) / Double(moves.count))
        }
    }

    private struct MonthGroup: Identifiable {
        let id: Date
        let items: [NewsItem]
    }

    private var monthGroups: [MonthGroup] {
        let cal = Calendar.ist
        let g = Dictionary(grouping: items) { cal.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
        return g.keys.sorted(by: >).map { MonthGroup(id: $0, items: g[$0] ?? []) }
    }

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; f.timeZone = Calendar.ist.timeZone; return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("News")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Stock news summaries you collect from AI tools and sites, tagged and dated — and how each stock moved since.")
                        .foregroundStyle(.secondary)
                }
                if !store.data.news.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(tagStats) { st in
                            Button {
                                tagFilter = tagFilter == st.tag ? nil : st.tag
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(st.tag.title, systemImage: st.tag.systemImage)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(st.tag.color)
                                        .lineLimit(1)
                                    Text("\(st.count)").font(.title3.weight(.semibold).monospacedDigit())
                                    Text(st.avg.map { "avg \(Fmt.pct($0)) since" } ?? "no price data yet")
                                        .font(.caption2)
                                        .foregroundStyle(st.avg?.changeColor ?? .secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(tagFilter == st.tag ? st.tag.color.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(tagFilter == st.tag ? st.tag.color : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .help(tagFilter == st.tag ? "Show all tags" : "Show only \(st.tag.title)")
                        }
                    }
                }
                HStack {
                    Picker("Stock", selection: $filter) {
                        Text("All stocks").tag(Filter.all)
                        if hasMarketNews { Text("Market / general (older)").tag(Filter.market) }
                        Divider()
                        ForEach(store.symbols.filter { s in store.data.news.contains { $0.symbolID == s.id } }
                                    .sorted { $0.ticker < $1.ticker }) { s in
                            Text(s.ticker).tag(Filter.symbol(s.id))
                        }
                    }
                    .frame(width: 240)
                    Picker("Tag", selection: $tagFilter) {
                        Text("All tags").tag(NewsTag?.none)
                        Divider()
                        ForEach(NewsTag.allCases) { t in Text(t.title).tag(Optional(t)) }
                    }
                    .frame(width: 260)
                    Spacer()
                    Button { adding = true } label: { Label("Add News Summary", systemImage: "plus") }
                }

                if items.isEmpty {
                    Card {
                        Text(store.data.news.isEmpty
                             ? "No news saved yet. Copy a summary from ChatGPT, Perplexity or a news site, click Add News Summary, pick the stock and tags, and paste it in."
                             : "No news matches these filters.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(monthGroups) { g in
                    Text(Self.monthFmt.string(from: g.id)).font(.title3.weight(.semibold)).padding(.top, 6)
                    ForEach(g.items) { n in
                        NewsCard(item: n, outcome: outcome(for: n), openSymbol: openSymbol) { editing = n }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("News")
        .toolbar {
            ToolbarItem {
                Button { adding = true } label: { Label("Add News Summary", systemImage: "plus") }
                    .help("Add News Summary")
            }
        }
        .sheet(isPresented: $adding) {
            NewsEditor(existing: nil, defaultSymbolID: { if case .symbol(let id) = filter { return id }; return nil }())
                .environmentObject(store)
                .environmentObject(directory)
        }
        .sheet(item: $editing) { n in
            NewsEditor(existing: n).environmentObject(store).environmentObject(directory)
        }
        .task {
            let syms = store.symbols.filter { s in store.data.news.contains { $0.symbolID == s.id } }
            series = await loadSeries(for: syms, store: store)
        }
    }

    private func outcome(for n: NewsItem) -> ObservationOutcome? {
        guard let id = n.symbolID, let s = store.symbol(id), let c = series[s.yahooSymbol]?.candles else { return nil }
        return ObservationOutcome.compute(for: n.date, candles: c)
    }
}

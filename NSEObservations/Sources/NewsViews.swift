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
    @State private var tags: Set<String> = []
    @State private var newTagTitle = ""
    @State private var addingTag = false
    @State private var managingTags = false
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
                HStack {
                    Text("Tags").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Tags…") { managingTags = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                FlowLayout(spacing: 8) {
                    ForEach(store.newsTagDefs) { tag in
                        let on = tags.contains(tag.id)
                        Button {
                            if on { tags.remove(tag.id) } else { tags.insert(tag.id) }
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
                    if addingTag {
                        TextField("New tag", text: $newTagTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .onSubmit { createTag() }
                    } else {
                        Button { addingTag = true } label: {
                            Label("New Tag", systemImage: "plus")
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sheet(isPresented: $managingTags) {
                TagManagerSheet().environmentObject(store)
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
                tags = Set(e.tags ?? [])
            }
        }
    }

    private func createTag() {
        let t = newTagTitle.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            if let existing = store.newsTagDefs.first(where: { $0.title.caseInsensitiveCompare(t) == .orderedSame }) {
                tags.insert(existing.id)
            } else {
                let tag = store.makeTag(title: t)
                store.addTagDef(tag)
                tags.insert(tag.id)
            }
        }
        newTagTitle = ""
        addingTag = false
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
        let ordered = store.newsTagDefs.map(\.id).filter { tags.contains($0) }
        n.tags = ordered.isEmpty ? nil : ordered
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

                let itemTags = store.tags(for: item)
                if !itemTags.isEmpty { NewsTagChips(tags: itemTags) }

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
    @State private var tagFilter: String?
    @State private var managingTags = false
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
        .filter { n in tagFilter.map { (n.tags ?? []).contains($0) } ?? true }
    }

    private var hasMarketNews: Bool { store.data.news.contains { $0.symbolID == nil } }

    /// For each tag: how many summaries, and the average move of the stock since the news.
    private struct TagStat: Identifiable {
        let tag: NewsTag
        let count: Int
        let avg: Double?
        var id: String { tag.id }
    }

    private var tagStats: [TagStat] {
        store.newsTagDefs.map { tag in
            let tagged = store.data.news.filter { ($0.tags ?? []).contains(tag.id) }
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
                if !store.data.news.isEmpty && !store.newsTagDefs.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(tagStats) { st in
                            Button {
                                tagFilter = tagFilter == st.tag.id ? nil : st.tag.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(st.tag.title, systemImage: st.tag.systemImage)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(st.tag.color)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(st.count)").font(.title3.weight(.semibold).monospacedDigit())
                                    Text(st.avg.map { "avg \(Fmt.pct($0)) since" } ?? "no price data yet")
                                        .font(.caption2)
                                        .foregroundStyle(st.avg?.changeColor ?? .secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(tagFilter == st.tag.id ? st.tag.color.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(tagFilter == st.tag.id ? st.tag.color : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .help(tagFilter == st.tag.id ? "Show all tags" : "Show only \(st.tag.title)")
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
                        Text("All tags").tag(String?.none)
                        Divider()
                        ForEach(store.newsTagDefs) { t in Text(t.title).tag(Optional(t.id)) }
                    }
                    .frame(width: 260)
                    Spacer()
                    Button("Manage Tags…") { managingTags = true }
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
        .sheet(isPresented: $managingTags) {
            TagManagerSheet().environmentObject(store)
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


// MARK: - Tag manager

struct TagManagerSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var defs: [NewsTag] = []
    @State private var pendingDelete: NewsTag?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("News Tags").font(.title2.weight(.semibold))
            Text("Rename, recolour, pick an icon, drag to reorder, or delete. Changes apply when you click Save.")
                .font(.callout).foregroundStyle(.secondary)

            List {
                ForEach($defs) { $tag in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Menu {
                            ForEach(NewsTag.icons, id: \.self) { icon in
                                Button { tag.icon = icon } label: { Label(icon, systemImage: icon) }
                            }
                        } label: {
                            Image(systemName: tag.icon).foregroundStyle(tag.color)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Icon")

                        TextField("Tag name", text: $tag.title)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 160)

                        HStack(spacing: 4) {
                            ForEach(NewsTag.paletteNames, id: \.self) { name in
                                Circle()
                                    .fill(NewsTag.color(named: name))
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(Color.primary.opacity(tag.colorName == name ? 0.9 : 0), lineWidth: 2).padding(-3))
                                    .onTapGesture { tag.colorName = name }
                                    .help(name.capitalized)
                            }
                        }

                        Text("\(store.usageCount(ofTag: tag.id))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                            .help("Summaries with this tag")

                        Button(role: .destructive) {
                            if store.usageCount(ofTag: tag.id) > 0 { pendingDelete = tag } else { defs.removeAll { $0.id == tag.id } }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
                .onMove { from, to in defs.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)

            HStack {
                Button {
                    var t = store.makeTag(title: "New tag")
                    let used = Set(defs.map(\.colorName))
                    t.colorName = NewsTag.paletteNames.first { !used.contains($0) } ?? "gray"
                    defs.append(t)
                } label: { Label("Add Tag", systemImage: "plus") }
                Button("Restore Starter Tags") {
                    for d in NewsTag.defaults where !defs.contains(where: { $0.id == d.id }) { defs.append(d) }
                }
                .help("Adds back any of the four starter tags you deleted")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let cleaned = defs.map { d -> NewsTag in
                        var c = d
                        c.title = d.title.trimmingCharacters(in: .whitespaces)
                        if c.title.isEmpty { c.title = "Untitled" }
                        return c
                    }
                    store.saveTagDefs(cleaned)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
        .onAppear { defs = store.newsTagDefs }
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { t in
            Button("Delete Tag", role: .destructive) { defs.removeAll { $0.id == t.id } }
        } message: { t in
            Text("It will be removed from \(store.usageCount(ofTag: t.id)) news summar\(store.usageCount(ofTag: t.id) == 1 ? "y" : "ies") when you save. The summaries themselves are kept.")
        }
    }
}

/// Wraps its children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW {
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

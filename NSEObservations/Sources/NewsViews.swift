import SwiftUI
import AppKit

// MARK: - Editor

struct NewsEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let existing: NewsItem?
    var defaultSymbolID: UUID? = nil

    @State private var symbolID: UUID?
    @State private var date = Date()
    @State private var title = ""
    @State private var source = ""
    @State private var text = ""

    private let sourceSuggestions = ["ChatGPT", "Perplexity", "Claude", "Gemini", "Moneycontrol", "Economic Times", "Business Standard"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add News Summary" : "Edit News Summary")
                .font(.title2.weight(.semibold))

            Form {
                Picker("About", selection: $symbolID) {
                    Text("Market / general").tag(UUID?.none)
                    Divider()
                    ForEach(store.symbols.sorted { $0.ticker < $1.ticker }) { s in
                        Text(s.ticker).tag(Optional(s.id))
                    }
                }
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
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                Text("Saved summaries are included when you use the AI features.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            if let e = existing {
                symbolID = e.symbolID; date = e.date; title = e.title; source = e.source; text = e.text
            } else {
                symbolID = defaultSymbolID
            }
        }
    }

    private func save() {
        var n = existing ?? NewsItem()
        n.symbolID = symbolID
        n.date = date
        n.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        n.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        n.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.title.isEmpty {
            // Use the first line of the summary as a headline.
            n.title = String(n.text.split(separator: "\n").first?.prefix(90) ?? "News")
        }
        store.upsert(n)
        dismiss()
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
    var openSymbol: (UUID) -> Void

    private enum Filter: Hashable { case all, market, symbol(UUID) }
    @State private var filter: Filter = .all
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
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("News")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("News summaries you collect from AI tools and sites, pasted in by date. They also feed the AI features.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Show", selection: $filter) {
                        Text("All").tag(Filter.all)
                        Text("Market / general").tag(Filter.market)
                        Divider()
                        ForEach(store.symbols.sorted { $0.ticker < $1.ticker }) { s in
                            Text(s.ticker).tag(Filter.symbol(s.id))
                        }
                    }
                    .frame(width: 260)
                    Spacer()
                    Button { adding = true } label: { Label("Add News Summary", systemImage: "plus") }
                }

                if items.isEmpty {
                    Card {
                        Text("No news saved yet. Copy a summary from ChatGPT, Perplexity or a news site, click Add News Summary, and paste it in.")
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
        }
        .sheet(item: $editing) { n in
            NewsEditor(existing: n).environmentObject(store)
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

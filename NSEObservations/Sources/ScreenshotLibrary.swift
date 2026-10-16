import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Stock search (journal first, then the NSE list)

struct StockSearchField: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    @Binding var ticker: String?
    @Binding var name: String
    @State private var query = ""
    @FocusState private var focused: Bool

    private var suggestions: [ListedSymbol] {
        guard ticker?.uppercased() != query.uppercased() else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let journal = store.symbols
            .filter { $0.ticker.localizedCaseInsensitiveContains(q) || $0.displayName.localizedCaseInsensitiveContains(q) }
            .prefix(4)
            .map { ListedSymbol(symbol: $0.ticker, name: $0.displayName, series: "") }
        let listed = directory.search(q, limit: 8).filter { l in !journal.contains { $0.symbol == l.symbol } }
        return Array((journal + listed).prefix(7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Stock", text: $query, prompt: Text("Which stock? Type a symbol or company, e.g. RELIANCE, tata"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
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
            } else if let t = ticker {
                Label("\(t)\(name.isEmpty ? "" : " — \(name)")\(store.existingSymbol(ticker: t) == nil ? " · will be added to Watching" : "")",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .onAppear {
            if let t = ticker { query = t } else { focused = true }
        }
    }

    private func pick(_ item: ListedSymbol) {
        ticker = item.symbol
        name = item.name
        query = item.symbol
        focused = false
    }
}

// MARK: - Quick capture

struct PendingShot: Identifiable {
    let id = UUID()
    let image: NSImage
    var date: Date
}

struct NewScreenshotSheet: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    @Environment(\.dismiss) private var dismiss

    var presetSymbolID: UUID? = nil
    var initial: [(image: NSImage, date: Date)] = []
    /// Called with the new screenshot ids (oldest first) after saving.
    var onCreated: ([UUID]) -> Void = { _ in }

    @State private var ticker: String?
    @State private var name = ""
    @State private var pending: [PendingShot] = []
    @State private var dropTargeted = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Screenshot").font(.title2.weight(.semibold))

            StockSearchField(ticker: $ticker, name: $name)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Screenshots").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                    Button { pending += ShotImport.chooseFiles().map { PendingShot(image: $0.image, date: $0.date) } } label: {
                        Label("Choose…", systemImage: "photo.badge.plus")
                    }
                }
                .controlSize(.small)

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 10) {
                        ForEach($pending) { $p in
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: p.image).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 200, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    Button { pending.removeAll { $0.id == p.id } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.white, Color.black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(4)
                                }
                                DatePicker("", selection: $p.date, displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .frame(width: 200)
                            }
                        }
                        dropBox
                    }
                    .padding(.vertical, 2)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }

            HStack {
                Text(pending.count > 1 ? "\(pending.count) screenshots will be added." : "After saving you can write on the screenshot.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pending.count == 1 ? "Save & Annotate" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticker == nil || pending.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onAppear {
            if let id = presetSymbolID, let s = store.symbol(id) { ticker = s.ticker; name = s.displayName }
            pending = initial.map { PendingShot(image: $0.image, date: $0.date) }
            if pending.isEmpty, let img = ImageIO.pasteboardImage() {
                // Most screenshots arrive via the clipboard: offer it right away.
                pending = [PendingShot(image: img, date: Date())]
                message = "Added the image on your clipboard. Remove it if that's not the one."
            }
        }
    }

    private var dropBox: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
            Text("Drop images here").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 120)
        .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            ShotImport.handleDrop(providers) { items in
                pending += items.map { PendingShot(image: $0.image, date: $0.date) }
            }
            return true
        }
    }

    private func paste() {
        if let img = ImageIO.pasteboardImage() {
            pending.append(PendingShot(image: img, date: Date()))
            message = nil
        } else {
            message = "No image on the clipboard. In TradingView use the camera icon ▸ Copy chart image."
        }
    }

    private func save() {
        guard let t = ticker else { return }
        let symbol: TrackedSymbol
        if let s = store.existingSymbol(ticker: t) {
            symbol = s
        } else {
            let s = TrackedSymbol(ticker: t, displayName: name, status: .watching)
            store.upsert(s)
            symbol = s
        }
        let ids = store.addChartShots(pending.map { ($0.image, $0.date) }, symbolID: symbol.id)
        dismiss()
        onCreated(ids)
    }
}

// MARK: - Library: all screenshots, organised by date

struct ScreenshotLibraryView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    var openSymbol: (UUID) -> Void

    @State private var grouping: TimelineGrouping = .day
    @State private var stockFilter: UUID?
    @State private var search = ""
    @State private var capture: CaptureRequest?
    @State private var editing: ShotRef?
    @State private var dropTargeted = false
    @State private var series: [String: QuoteSeries] = [:]

    struct CaptureRequest: Identifiable {
        let id = UUID()
        var items: [(image: NSImage, date: Date)]
    }
    struct ShotRef: Identifiable { let id: UUID }

    private var shots: [ChartShot] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.data.chartShots
            .filter { stockFilter == nil || $0.symbolID == stockFilter }
            .filter { s in
                guard !q.isEmpty else { return true }
                if s.caption.lowercased().contains(q) { return true }
                if s.annotations.contains(where: { $0.text.lowercased().contains(q) }) { return true }
                return store.symbol(s.symbolID)?.ticker.lowercased().contains(q) ?? false
            }
            .sorted { $0.date > $1.date }
    }

    private struct Period: Identifiable {
        let id: Date
        let title: String
        let shots: [ChartShot]
    }

    private var periods: [Period] {
        var cal = Calendar.ist
        cal.firstWeekday = 2
        let g = Dictionary(grouping: shots) { cal.dateInterval(of: grouping.component, for: $0.date)?.start ?? $0.date }
        return g.keys.sorted(by: >).map { Period(id: $0, title: grouping.title(for: $0), shots: g[$0] ?? []) }
    }

    private var stocksWithShots: [TrackedSymbol] {
        store.symbols.filter { s in store.data.chartShots.contains { $0.symbolID == s.id } }.sorted { $0.ticker < $1.ticker }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screenshots")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Your TradingView charts by date, with what you wrote on them.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { capture = CaptureRequest(items: []) } label: {
                        Label("New Screenshot", systemImage: "plus")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("New Screenshot (⌥⌘N)")
                }

                HStack(spacing: 12) {
                    Picker("Group by", selection: $grouping) {
                        ForEach(TimelineGrouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Picker("Stock", selection: $stockFilter) {
                        Text("All stocks").tag(UUID?.none)
                        Divider()
                        ForEach(stocksWithShots) { s in Text(s.ticker).tag(Optional(s.id)) }
                    }
                    .frame(width: 200)
                    TextField("Search your notes and labels", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Spacer()
                }

                dropBanner

                if shots.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.data.chartShots.isEmpty ? "No screenshots yet" : "No screenshots match").font(.headline)
                            Text(store.data.chartShots.isEmpty
                                 ? "In TradingView, use the camera icon ▸ Copy chart image, then press ⌥⌘N here — the image on your clipboard is picked up automatically. Or drop saved screenshot files onto this page."
                                 : "Try another stock or search.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(periods) { p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.title).font(.title3.weight(.semibold))
                        Text("\(p.shots.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(p.shots) { shot in
                            ChartShotCard(shot: shot, outcome: outcome(shot), showTicker: true, showDay: grouping != .day) {
                                editing = ShotRef(id: shot.id)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1300, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Screenshots")
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            ShotImport.collect(providers) { items in
                if !items.isEmpty { capture = CaptureRequest(items: items) }
            }
            return true
        }
        .sheet(item: $capture) { req in
            NewScreenshotSheet(presetSymbolID: stockFilter, initial: req.items) { ids in
                if ids.count == 1, let id = ids.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editing = ShotRef(id: id) }
                }
            }
            .environmentObject(store)
            .environmentObject(directory)
        }
        .sheet(item: $editing) { ref in
            ChartShotEditor(shotID: ref.id).environmentObject(store)
        }
        .task(id: store.data.chartShots.count) {
            series = await loadSeries(for: stocksWithShots, store: store)
        }
    }

    private var dropBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(.secondary)
            Text("Drop screenshot files anywhere on this page, or press ⌥⌘N to add the chart image on your clipboard.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35)))
    }

    private func outcome(_ shot: ChartShot) -> ObservationOutcome? {
        guard let s = store.symbol(shot.symbolID), let c = series[s.yahooSymbol]?.candles else { return nil }
        return ObservationOutcome.compute(for: shot.date, candles: c)
    }
}

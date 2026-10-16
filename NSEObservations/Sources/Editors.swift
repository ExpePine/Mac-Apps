import SwiftUI

// MARK: - Symbol

struct SymbolEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let existing: TrackedSymbol?
    var onSave: (TrackedSymbol) -> Void = { _ in }

    @State private var ticker = ""
    @State private var name = ""
    @State private var status: SymbolStatus = .watching
    @State private var tags = ""
    @State private var thesis = ""
    @State private var checking = false
    @State private var warning: String?
    @State private var confirmedWithoutData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add Symbol" : "Edit \(existing!.ticker)")
                .font(.title2.weight(.semibold))

            Form {
                TextField("NSE symbol", text: $ticker, prompt: Text("e.g. RELIANCE, TATAMOTORS, M&M"))
                    .disabled(existing != nil)
                TextField("Name", text: $name, prompt: Text("Filled in automatically if found"))
                Picker("List", selection: $status) {
                    ForEach(SymbolStatus.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                TextField("Tags", text: $tags, prompt: Text("comma separated, e.g. auto, breakout"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thesis").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $thesis)
                        .font(.body)
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking Yahoo Finance…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmedWithoutData ? "Save Anyway" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticker.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let e = existing {
                ticker = e.ticker; name = e.displayName; status = e.status
                tags = e.tags.joined(separator: ", "); thesis = e.thesis
            }
        }
    }

    private func save() async {
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        if existing == nil, store.existingSymbol(ticker: t) != nil {
            warning = "\(t) is already in your journal."
            return
        }
        var s = existing ?? TrackedSymbol(ticker: t)
        s.displayName = name.trimmingCharacters(in: .whitespaces)
        s.status = status
        s.tags = Fmt.tags(from: tags)
        s.thesis = thesis

        if existing == nil && !confirmedWithoutData {
            checking = true
            defer { checking = false }
            do {
                let series = try await MarketDataService.shared.series(
                    for: s.yahooSymbol, from: Date().addingTimeInterval(-14 * 86_400), force: true)
                if s.displayName.isEmpty, let n = series.name { s.displayName = n }
            } catch {
                warning = "Couldn't confirm \(s.yahooSymbol) on Yahoo Finance (\(error.localizedDescription)). Check the symbol, or save anyway and add notes offline."
                confirmedWithoutData = true
                return
            }
        }
        store.upsert(s)
        onSave(s)
        dismiss()
    }
}

// MARK: - Observation

struct ObservationEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let symbolID: UUID
    let existing: Observation?

    @State private var date = Date()
    @State private var timeframe: ChartTimeframe = .daily
    @State private var sentiment: Sentiment = .neutral
    @State private var text = ""
    @State private var tags = ""
    @State private var price = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Observation" : "Edit Observation")
                .font(.title2.weight(.semibold))

            Form {
                DatePicker("Observed on", selection: $date, displayedComponents: .date)
                Picker("Chart", selection: $timeframe) {
                    ForEach(ChartTimeframe.allCases) { Text($0.title).tag($0) }
                }
                Picker("Read", selection: $sentiment) {
                    ForEach(Sentiment.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Tags", text: $tags, prompt: Text("e.g. breakout, volume, 200dma"))
                TextField("Price you saw", text: $price, prompt: Text("optional"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What did you see on the chart?").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let e = existing {
                date = e.date; timeframe = e.timeframe; sentiment = e.sentiment; text = e.text
                tags = e.tags.joined(separator: ", ")
                price = e.notedPrice.map { String(format: "%.2f", $0) } ?? ""
            }
        }
    }

    private func save() {
        var o = existing ?? Observation(symbolID: symbolID)
        o.date = date
        o.timeframe = timeframe
        o.sentiment = sentiment
        o.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        o.tags = Fmt.tags(from: tags)
        o.notedPrice = Double(price.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
        store.upsert(o)
        dismiss()
    }
}

// MARK: - Trade

struct TradeEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let symbolID: UUID
    let existing: Trade?

    @State private var side: TradeSide = .buy
    @State private var date = Date()
    @State private var qty = ""
    @State private var price = ""
    @State private var note = ""

    private var qtyValue: Double? { Double(qty.replacingOccurrences(of: ",", with: "")) }
    private var priceValue: Double? { Double(price.replacingOccurrences(of: ",", with: "")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Log Trade" : "Edit Trade")
                .font(.title2.weight(.semibold))
            Form {
                Picker("Side", selection: $side) {
                    ForEach(TradeSide.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Quantity", text: $qty)
                TextField("Price (₹)", text: $price)
                TextField("Note", text: $note, prompt: Text("optional — why you took it"))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var t = existing ?? Trade(symbolID: symbolID)
                    t.side = side; t.date = date
                    t.quantity = qtyValue ?? 0; t.price = priceValue ?? 0; t.note = note
                    store.upsert(t)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((qtyValue ?? 0) <= 0 || (priceValue ?? 0) <= 0)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let e = existing {
                side = e.side; date = e.date
                qty = AIContext.formatQty(e.quantity)
                price = String(format: "%.2f", e.price); note = e.note
            }
        }
    }
}

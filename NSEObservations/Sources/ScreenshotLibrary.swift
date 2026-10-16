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

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// All notes live in one JSON file in the app's Application Support folder.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var data = AppData()
    @Published var lastError: String?

    let fileURL: URL

    /// `fileURL`/`seed` are only used by screenshot mode, so sample data never touches your journal.
    init(fileURL custom: URL? = nil, seed: AppData? = nil) {
        if let custom {
            fileURL = custom
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let dir = base.appendingPathComponent("NSEObservations", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("observations.json")
        }
        if let seed {
            data = seed
            save()
        } else {
            load()
        }
    }

    // MARK: Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let raw = try Data(contentsOf: fileURL)
            data = try Self.decoder.decode(AppData.self, from: raw)
        } catch {
            // Keep the unreadable file aside instead of overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            lastError = "Couldn't read saved notes (\(error.localizedDescription)). A copy was kept at \(backup.lastPathComponent)."
        }
    }

    private func save() {
        do {
            let raw = try Self.encoder.encode(data)
            try raw.write(to: fileURL, options: .atomic)
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Queries

    var symbols: [TrackedSymbol] { data.symbols }

    func symbol(_ id: UUID) -> TrackedSymbol? { data.symbols.first { $0.id == id } }

    func symbols(with status: SymbolStatus) -> [TrackedSymbol] {
        data.symbols.filter { $0.status == status }.sorted { $0.ticker < $1.ticker }
    }

    func observations(for symbolID: UUID) -> [Observation] {
        data.observations.filter { $0.symbolID == symbolID }.sorted { $0.date > $1.date }
    }

    func trades(for symbolID: UUID) -> [Trade] {
        data.trades.filter { $0.symbolID == symbolID }.sorted { $0.date < $1.date }
    }

    func analyses(for symbolID: UUID?, kind: AnalysisKind) -> [SavedAnalysis] {
        data.analyses.filter { $0.symbolID == symbolID && $0.kind == kind }.sorted { $0.createdAt > $1.createdAt }
    }

    func observationCount(for symbolID: UUID) -> Int {
        data.observations.reduce(0) { $0 + ($1.symbolID == symbolID ? 1 : 0) }
    }

    func lastObservationDate(for symbolID: UUID) -> Date? {
        data.observations.filter { $0.symbolID == symbolID }.map(\.date).max()
    }

    /// Net quantity held and average buy price (simple average-cost method).
    func position(for symbolID: UUID) -> (qty: Double, avg: Double)? {
        var qty = 0.0, cost = 0.0
        for t in trades(for: symbolID) {
            switch t.side {
            case .buy:
                cost += t.quantity * t.price
                qty += t.quantity
            case .sell:
                guard qty > 0 else { continue }
                let avg = cost / qty
                let q = min(t.quantity, qty)
                qty -= q
                cost -= q * avg
            }
        }
        return qty > 0 ? (qty, cost / qty) : nil
    }

    func matches(_ s: TrackedSymbol, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        if s.ticker.lowercased().contains(q) || s.displayName.lowercased().contains(q) { return true }
        if s.tags.contains(where: { $0.contains(q) }) || s.thesis.lowercased().contains(q) { return true }
        return data.observations.contains {
            $0.symbolID == s.id && ($0.text.lowercased().contains(q) || $0.tags.contains(where: { $0.contains(q) }))
        }
    }

    // MARK: Mutations

    func upsert(_ symbol: TrackedSymbol) {
        if let i = data.symbols.firstIndex(where: { $0.id == symbol.id }) {
            data.symbols[i] = symbol
        } else {
            data.symbols.append(symbol)
        }
        save()
    }

    func existingSymbol(ticker: String) -> TrackedSymbol? {
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        return data.symbols.first { $0.ticker.uppercased() == t }
    }

    func deleteSymbol(_ id: UUID) {
        data.symbols.removeAll { $0.id == id }
        data.observations.removeAll { $0.symbolID == id }
        data.trades.removeAll { $0.symbolID == id }
        data.analyses.removeAll { $0.symbolID == id }
        save()
    }

    func setStatus(_ status: SymbolStatus, for id: UUID) {
        guard let i = data.symbols.firstIndex(where: { $0.id == id }) else { return }
        data.symbols[i].status = status
        save()
    }

    func upsert(_ obs: Observation) {
        var o = obs
        o.updatedAt = Date()
        if let i = data.observations.firstIndex(where: { $0.id == o.id }) {
            data.observations[i] = o
        } else {
            data.observations.append(o)
        }
        save()
    }

    func deleteObservation(_ id: UUID) {
        data.observations.removeAll { $0.id == id }
        save()
    }

    func upsert(_ trade: Trade) {
        if let i = data.trades.firstIndex(where: { $0.id == trade.id }) {
            data.trades[i] = trade
        } else {
            data.trades.append(trade)
        }
        save()
    }

    func deleteTrade(_ id: UUID) {
        data.trades.removeAll { $0.id == id }
        save()
    }

    func add(_ analysis: SavedAnalysis) {
        data.analyses.append(analysis)
        // Keep the newest 10 per (symbol, kind) so the file stays small.
        let same = data.analyses.filter { $0.symbolID == analysis.symbolID && $0.kind == analysis.kind }
            .sorted { $0.createdAt > $1.createdAt }
        if same.count > 10 {
            let drop = Set(same.dropFirst(10).map(\.id))
            data.analyses.removeAll { drop.contains($0.id) }
        }
        save()
    }

    func deleteAnalysis(_ id: UUID) {
        data.analyses.removeAll { $0.id == id }
        save()
    }

    func appendChat(_ msg: ChatMessage) {
        data.chat.append(msg)
        save()
    }

    func clearChat() {
        data.chat.removeAll()
        save()
    }

    // MARK: Import / export

    func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NSE-Observations-\(Fmt.isoDay.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.encoder.encode(data).write(to: url, options: .atomic)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Merges a backup: items with the same id are replaced by the backup's version.
    func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try Self.decoder.decode(AppData.self, from: Data(contentsOf: url))
            func merge<T: Identifiable>(_ a: [T], _ b: [T]) -> [T] where T.ID == UUID {
                var dict = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
                for item in b { dict[item.id] = item }
                return Array(dict.values)
            }
            data.symbols = merge(data.symbols, incoming.symbols)
            data.observations = merge(data.observations, incoming.observations)
            data.trades = merge(data.trades, incoming.trades)
            data.analyses = merge(data.analyses, incoming.analyses)
            data.chat = merge(data.chat, incoming.chat).sorted { $0.date < $1.date }
            save()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    func revealDataFile() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

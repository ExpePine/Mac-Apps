import Foundation

/// One tradable name from NSE's equity list (or a built-in index).
struct ListedSymbol: Identifiable, Hashable {
    var id: String { symbol }
    var symbol: String
    var name: String
    var series: String
    var isIndex: Bool = false
}

/// The full NSE equity list used for search-as-you-type.
/// Source order: a copy refreshed from NSE (weekly), else the CSV bundled in the app.
@MainActor
final class SymbolDirectory: ObservableObject {
    @Published private(set) var entries: [ListedSymbol] = []
    @Published private(set) var updated: Date?
    @Published private(set) var sourceDescription = "Built-in list"
    @Published private(set) var refreshing = false
    @Published var refreshError: String?

    /// NSE's published list of listed equities. NSE may block automated requests; the app then keeps its current list.
    static let remoteURLs = [
        "https://nsearchives.nseindia.com/content/equities/EQUITY_L.csv",
        "https://archives.nseindia.com/content/equities/EQUITY_L.csv"
    ]

    /// Yahoo Finance codes for common NSE indices. The Add Symbol check confirms each one against Yahoo.
    static let indices: [ListedSymbol] = [
        ("^NSEI", "Nifty 50"),
        ("^NSEBANK", "Nifty Bank"),
        ("^CNXIT", "Nifty IT"),
        ("^CNXAUTO", "Nifty Auto"),
        ("^CNXPHARMA", "Nifty Pharma"),
        ("^CNXFMCG", "Nifty FMCG"),
        ("^CNXMETAL", "Nifty Metal"),
        ("^CNXREALTY", "Nifty Realty"),
        ("^CNXENERGY", "Nifty Energy"),
        ("^CNXPSUBANK", "Nifty PSU Bank"),
        ("^INDIAVIX", "India VIX")
    ].map { ListedSymbol(symbol: $0.0, name: $0.1, series: "INDEX", isIndex: true) }

    private let cacheURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("NSEObservations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("nse_equities.csv")
        loadLocal()
    }

    var equityCount: Int { entries.filter { !$0.isIndex }.count }

    private func loadLocal() {
        if let data = try? Data(contentsOf: cacheURL) {
            let parsed = Self.parse(data)
            if parsed.count > 100 {
                apply(parsed)
                let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
                updated = attrs?[.modificationDate] as? Date
                sourceDescription = "Refreshed from NSE"
                return
            }
        }
        if let url = Bundle.main.url(forResource: "nse_equities", withExtension: "csv"),
           let data = try? Data(contentsOf: url) {
            apply(Self.parse(data))
            sourceDescription = "Built-in list"
        } else {
            apply([])
            sourceDescription = "No list bundled"
        }
    }

    private func apply(_ equities: [ListedSymbol]) {
        // One row per symbol; prefer the regular EQ series when NSE lists several.
        var bySymbol: [String: ListedSymbol] = [:]
        for e in equities {
            if let existing = bySymbol[e.symbol], existing.series == "EQ" { continue }
            bySymbol[e.symbol] = e
        }
        entries = Self.indices + bySymbol.values.sorted { $0.symbol < $1.symbol }
    }

    func refreshIfStale() async {
        let age = updated.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 7 * 86_400 { await refresh(userInitiated: false) }
    }

    func refresh(userInitiated: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var lastError = "no response"
        for s in Self.remoteURLs {
            guard let url = URL(string: s) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            req.setValue("text/csv,*/*", forHTTPHeaderField: "Accept")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = "HTTP \(http.statusCode)"
                    continue
                }
                let parsed = Self.parse(data)
                guard parsed.count > 500 else {
                    lastError = "unexpected file contents"
                    continue
                }
                try data.write(to: cacheURL, options: .atomic)
                apply(parsed)
                updated = Date()
                sourceDescription = "Refreshed from NSE"
                refreshError = nil
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        // A failed background refresh is silent; the current list keeps working.
        if userInitiated {
            refreshError = "Couldn't refresh from NSE (\(lastError)). Keeping the current list."
        }
    }

    // MARK: Search

    func search(_ query: String, limit: Int = 10) -> [ListedSymbol] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !q.isEmpty else { return [] }
        var scored: [(Int, ListedSymbol)] = []
        for e in entries {
            let name = e.name.uppercased()
            let sym = e.symbol.hasPrefix("^") ? String(e.symbol.dropFirst()) : e.symbol
            let score: Int
            if sym == q { score = 0 }
            else if sym.hasPrefix(q) { score = 1 }
            else if name.hasPrefix(q) { score = 2 }
            else if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { score = 3 }
            else if sym.contains(q) { score = 4 }
            else if q.count >= 3, name.contains(q) { score = 5 }
            else { continue }
            scored.append((score, e))
        }
        return scored
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1.symbol.count, $0.1.symbol) < ($1.1.symbol.count, $1.1.symbol) }
            .prefix(limit)
            .map(\.1)
    }

    func lookup(_ symbol: String) -> ListedSymbol? {
        let s = symbol.uppercased()
        return entries.first { $0.symbol == s }
    }

    // MARK: CSV

    /// Reads NSE's EQUITY_L.csv (SYMBOL, NAME OF COMPANY, SERIES, …). Also accepts any CSV whose
    /// header has a column containing "SYMBOL" and one containing "NAME"; without a header,
    /// column 1 is the symbol and column 2 the name.
    nonisolated static func parse(_ data: Data) -> [ListedSymbol] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let rows = csvRows(text)
        guard let header = rows.first else { return [] }
        let upper = header.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        var symCol = upper.firstIndex { $0 == "SYMBOL" } ?? upper.firstIndex { $0.contains("SYMBOL") }
        var nameCol = upper.firstIndex { $0.contains("NAME") }
        let seriesCol = upper.firstIndex { $0.contains("SERIES") }
        var body = rows.dropFirst()
        if symCol == nil || nameCol == nil {
            symCol = 0; nameCol = 1
            body = rows[...]   // no header row
        }
        guard let sc = symCol, let nc = nameCol else { return [] }

        var out: [ListedSymbol] = []
        out.reserveCapacity(body.count)
        for r in body {
            guard r.count > max(sc, nc) else { continue }
            let sym = r[sc].trimmingCharacters(in: .whitespaces).uppercased()
            let name = r[nc].trimmingCharacters(in: .whitespaces)
            guard !sym.isEmpty, sym.count <= 20, !sym.contains(" ") else { continue }
            let series = seriesCol.flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces).uppercased() : nil } ?? ""
            out.append(ListedSymbol(symbol: sym, name: name, series: series))
        }
        return out
    }

    /// Minimal RFC 4180 reader: quoted fields, doubled quotes, commas and newlines inside quotes.
    nonisolated static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

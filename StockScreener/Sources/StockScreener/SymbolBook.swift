import Foundation

/// Symbols you add by hand (on top of the sheet) and sheet symbols you hide.
struct ManualSymbol: Codable, Identifiable, Equatable {
    var id: String { symbol }
    var symbol: String
    var name = ""
    var industry = ""
    var links: [String] = []          // per chart (Chart 1, Chart 2…); "" = use the learned pattern
    var note = ""
    var addedAt = Date()
    var foundOnYahoo: Bool?           // nil = not checked yet
    var lastPrice: Double?
    var yahooIndustry = ""            // Yahoo's own sector / industry wording (for reference)
}

struct SymbolBook: Codable {
    var manual: [ManualSymbol] = []
    var hidden: [String] = []         // sheet symbols removed from the app

    private static var url: URL { AppFolders.base.appendingPathComponent("symbols.json") }
    static func load() -> SymbolBook {
        guard let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(SymbolBook.self, from: d) else { return SymbolBook() }
        return b
    }
    func save() {
        try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url, options: .atomic) }
    }

    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for p in ["NSE:", "NSE%3A", "BSE:"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if s.hasSuffix(".NS") { s = String(s.dropLast(3)) }
        return s
    }

    /// Applies hidden symbols and adds manual ones as rows (blank except symbol / name / industry columns).
    func apply(to t: SheetTable, label: Int?, sector: Int?, name: Int?) -> SheetTable {
        guard let label, !(manual.isEmpty && hidden.isEmpty) else { return t }
        let hide = Set(hidden)
        var rows = t.rows.filter { !hide.contains($0.text(label).trimmingCharacters(in: .whitespaces).uppercased()) }
        let present = Set(rows.map { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() })
        let n = t.headers.count
        var nextID = (t.rows.map(\.id).max() ?? 0) + 1_000_000
        for m in manual where !present.contains(m.symbol) && !hide.contains(m.symbol) {
            var cells = [String](repeating: "", count: n)
            cells[label] = m.symbol
            if let s = sector, s < n { cells[s] = m.industry }
            if let c = name, c < n, c != label { cells[c] = m.name }
            rows.append(SheetRow(id: nextID, cells: cells, numbers: [Double?](repeating: nil, count: n)))
            nextID += 1
        }
        return SheetTable(headers: t.headers, rows: rows, originalHeaders: t.originalHeaders)
    }
}

extension YahooClient {
    /// Company name and Yahoo's sector / industry from the search endpoint (unofficial; any field may be missing).
    static func profile(_ symbol: String) async -> (name: String, sector: String, industry: String)? {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(yahooSymbol(symbol))&quotesCount=3&newsCount=0") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any],
              let quotes = json["quotes"] as? [[String: Any]] else { return nil }
        let want = symbol.uppercased() + ".NS"
        guard let q = quotes.first(where: { ($0["symbol"] as? String)?.uppercased() == want }) ?? quotes.first else { return nil }
        let name = (q["longname"] as? String) ?? (q["shortname"] as? String) ?? ""
        let sector = (q["sectorDisp"] as? String) ?? (q["sector"] as? String) ?? ""
        let industry = (q["industryDisp"] as? String) ?? (q["industry"] as? String) ?? ""
        return (name, sector, industry)
    }
}

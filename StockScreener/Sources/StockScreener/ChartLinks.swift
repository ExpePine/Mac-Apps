import Foundation

/// Chart links per stock, imported from a Google Sheet (Symbol + one or more link columns),
/// plus a learned template so stocks that aren't in the sheet still get a chart.
struct ChartLinkBook: Codable {
    var columns: [String] = []                 // link column names, e.g. ["Link1", "Link2"]
    var links: [String: [String]] = [:]        // SYMBOL → one link per column ("" if blank)
    var templates: [String] = []               // per column, link with {SYMBOL} in place of the stock
    var importedAt = Date.distantPast

    private static var url: URL { AppFolders.base.appendingPathComponent("chart_links.json") }
    static func load() -> ChartLinkBook {
        guard let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(ChartLinkBook.self, from: d) else { return ChartLinkBook() }
        return b
    }
    func save() {
        try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url, options: .atomic) }
    }

    static func encode(_ symbol: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        return symbol.addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
    }

    /// Builds the book from a sheet: the symbol column plus every column that holds links.
    static func from(_ table: SheetTable, symbolColumn: String) -> ChartLinkBook {
        var book = ChartLinkBook()
        book.importedAt = Date()
        // Header cells can carry stray line breaks / spaces (e.g. "\nSymbol")
        let table = SheetTable(headers: table.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                               rows: table.rows, originalHeaders: table.originalHeaders)
        let symCol = table.index(of: symbolColumn)
            ?? table.headers.firstIndex { ["symbol", "ticker", "stock", "nse symbol"].contains($0.lowercased()) } ?? 0
        let linkCols = table.headers.indices.filter { c in
            c != symCol && table.rows.contains { $0.text(c).lowercased().hasPrefix("http") }
        }
        book.columns = linkCols.map { table.headers[$0] }
        for r in table.rows {
            let sym = r.text(symCol).trimmingCharacters(in: .whitespaces).uppercased()
            guard !sym.isEmpty else { continue }
            book.links[sym] = linkCols.map { r.text($0).trimmingCharacters(in: .whitespaces) }
        }
        // Learn the most common pattern per column: the link with the stock's symbol replaced by {SYMBOL}
        for (k, _) in linkCols.enumerated() {
            var counts: [String: Int] = [:]
            for (sym, ls) in book.links where k < ls.count && !ls[k].isEmpty {
                let l = ls[k]
                for form in [encode(sym), sym, sym.replacingOccurrences(of: "&", with: "%26")] where l.contains(form) {
                    counts[l.replacingOccurrences(of: form, with: "{SYMBOL}"), default: 0] += 1
                    break
                }
            }
            book.templates.append(counts.max { $0.value < $1.value }?.key ?? "")
        }
        return book
    }

    /// TradingView layout id in a chart link: …/chart/I7dkKisW/?symbol=… → "I7dkKisW" ("" = default chart).
    static func layoutID(_ link: String) -> String {
        guard let r = link.range(of: "/chart/") else { return "" }
        let rest = link[r.upperBound...]
        let id = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return String(id)
    }

    /// Swaps the layout id in a TradingView link: …/chart/OLD/?… → …/chart/NEW/?… (adds it if the link has none).
    static func withLayout(_ link: String, _ id: String) -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let r = link.range(of: "/chart/") else { return link }
        let old = layoutID(link)
        let start = r.upperBound
        if old.isEmpty { return link.replacingCharacters(in: start..<start, with: id + "/") }
        let end = link.index(start, offsetBy: old.count)
        return link.replacingCharacters(in: start..<end, with: id)
    }

    /// Layouts used in a link column, most used first: [(id, number of stocks)].
    func layouts(column: Int) -> [(id: String, count: Int)] {
        var n: [String: Int] = [:]
        for ls in links.values where column < ls.count && !ls[column].isEmpty { n[Self.layoutID(ls[column]), default: 0] += 1 }
        return n.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }

    /// The chart link for a stock: its own link from the sheet, else the learned pattern, else TradingView's default.
    func url(for symbol: String, column: Int = 0, fallbackTemplate: String) -> URL? {
        let sym = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        if let ls = links[sym], column < ls.count, !ls[column].isEmpty, let u = URL(string: ls[column]) { return u }
        let t = column < templates.count && !templates[column].isEmpty ? templates[column] : fallbackTemplate
        guard !t.isEmpty else { return nil }
        return URL(string: t.replacingOccurrences(of: "{SYMBOL}", with: Self.encode(sym)))
    }
}

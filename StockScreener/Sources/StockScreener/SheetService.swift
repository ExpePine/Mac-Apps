import Foundation
import CryptoKit

enum SheetError: LocalizedError {
    case http(Int)
    case notCSV
    case empty

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "Google Sheets returned HTTP \(code). Check the link and sharing settings."
        case .notCSV:
            return "Got a web page instead of data. The sheet is probably private — set sharing to \"Anyone with the link → Viewer\" or use File → Share → Publish to web."
        case .empty:
            return "The sheet tab is empty."
        }
    }
}

enum SheetService {

    /// Converts whatever link the user pastes into a CSV download URL.
    /// Supports: normal share/edit links (keeps the gid = tab), "Publish to web" links,
    /// links that are already CSV, or a bare sheet ID.
    static func csvURL(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Already a CSV link
        if s.contains("output=csv") || s.contains("format=csv") || s.contains("tqx=out:csv") {
            return URL(string: s)
        }

        // "Publish to web" link: /spreadsheets/d/e/<pubId>/pubhtml?...
        if s.contains("/spreadsheets/d/e/") {
            guard var comps = URLComponents(string: s) else { return nil }
            comps.path = comps.path.replacingOccurrences(of: "/pubhtml", with: "/pub")
            var items = (comps.queryItems ?? []).filter { $0.name != "output" }
            items.append(URLQueryItem(name: "output", value: "csv"))
            comps.queryItems = items
            comps.fragment = nil
            return comps.url
        }

        // Normal link: /spreadsheets/d/<id>/edit#gid=<gid>
        if let r = s.range(of: "/spreadsheets/d/") {
            let id = s[r.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard !id.isEmpty else { return nil }
            var gid: String?
            if let g = s.range(of: #"gid=\d+"#, options: .regularExpression) {
                gid = String(s[g].dropFirst(4))
            }
            return exportURL(id: String(id), gid: gid)
        }

        // Bare sheet ID
        if s.range(of: #"^[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil {
            return exportURL(id: s, gid: nil)
        }
        return nil
    }

    private static func exportURL(id: String, gid: String?) -> URL? {
        var comps = URLComponents(string: "https://docs.google.com/spreadsheets/d/\(id)/export")
        var items = [URLQueryItem(name: "format", value: "csv")]
        if let gid { items.append(URLQueryItem(name: "gid", value: gid)) }
        comps?.queryItems = items
        return comps?.url
    }

    static func fetch(from url: URL) async throws -> (table: SheetTable, hash: String) {
        let request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 60)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SheetError.http(http.statusCode)
        }
        // Parse off the main thread so the windows stay responsive.
        return try await Task.detached(priority: .userInitiated) {
            try SheetService.parse(data)
        }.value
    }

    static func parse(_ data: Data) throws -> (table: SheetTable, hash: String) {
        guard let text = String(data: data, encoding: .utf8) else { throw SheetError.notCSV }

        let start = text.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines).prefix(15).lowercased()
        if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") {
            throw SheetError.notCSV
        }

        let csv = CSVParser.parse(text)
        guard let headerRow = csv.first else { throw SheetError.empty }

        // Clean + de-duplicate headers
        var seen: [String: Int] = [:]
        let headers: [String] = headerRow.enumerated().map { index, raw in
            var name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Column \(index + 1)" }
            if let n = seen[name] {
                seen[name] = n + 1
                name = "\(name) (\(n + 1))"
            } else {
                seen[name] = 1
            }
            return name
        }

        var rows: [SheetRow] = []
        rows.reserveCapacity(max(0, csv.count - 1))
        let width = headers.count
        for (i, raw) in csv.dropFirst().enumerated() {
            if raw.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            var cells = raw
            if cells.count < width { cells.append(contentsOf: repeatElement("", count: width - cells.count)) }
            if cells.count > width { cells.removeLast(cells.count - width) }
            rows.append(SheetRow(id: i, cells: cells, numbers: cells.map { NumberParser.parse($0) }))
        }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (SheetTable(headers: headers, rows: rows), hash)
    }
}

/// Minimal RFC-4180 style CSV parser (handles quoted fields, "" escapes, commas/newlines inside quotes).
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(String(field))
                    field = String.UnicodeScalarView()
                case "\n", "\r":
                    row.append(String(field))
                    field = String.UnicodeScalarView()
                    rows.append(row)
                    row = []
                    if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }
}

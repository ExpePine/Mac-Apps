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

/// Where the data comes from and how fresh Google said it was.
struct FetchInfo: Equatable {
    var sourceKind: String       // "Live sheet" or "Published copy"
    var tab: String              // e.g. "tab gid 123", "first tab"
    var cacheAgeSeconds: Int?    // Age header: >0 means a cache answered
    var lastModified: Date?
}

enum SheetService {

    /// Fresh connection with no local cache, so every fetch goes to Google.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    /// Describes a link: live sheet vs "Publish to web" copy, and which tab.
    static func describe(_ input: String) -> (kind: String, tab: String, isPublished: Bool) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let published = s.contains("/spreadsheets/d/e/")
        var tab = "first tab"
        if let g = s.range(of: #"gid=\d+"#, options: .regularExpression) {
            tab = "tab gid \(s[g].dropFirst(4))"
        }
        return (published ? "Published copy" : "Live sheet", tab, published)
    }

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

    /// Adds a unique parameter so no cache between here and Google can answer with an old copy.
    static func cacheBusted(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (comps.queryItems ?? []).filter { $0.name != "_ts" }
        items.append(URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps.queryItems = items
        return comps.url ?? url
    }

    static func fetch(from url: URL) async throws -> (table: SheetTable, hash: String, ageSeconds: Int?, lastModified: Date?) {
        var request = URLRequest(url: cacheBusted(url),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 60)
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await session.data(for: request)

        var age: Int?
        var modified: Date?
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else { throw SheetError.http(http.statusCode) }
            age = (http.value(forHTTPHeaderField: "Age")).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let lm = http.value(forHTTPHeaderField: "Last-Modified") {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                modified = f.date(from: lm)
            }
        }
        // Parse off the main thread so the windows stay responsive.
        let parsed = try await Task.detached(priority: .userInitiated) {
            try SheetService.parse(data)
        }.value
        return (parsed.table, parsed.hash, age, modified)
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

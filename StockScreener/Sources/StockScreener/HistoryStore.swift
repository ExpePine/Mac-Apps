import Foundation

/// Daily snapshots of the sheet for the 30-day animation.
///
/// One file per trading day: the downloaded CSV compressed with Apple's LZFSE
/// (typically 5–10× smaller), in ~/Library/Application Support/StockScreener/History/.
/// Older days are deleted automatically after `keepDays`.
enum HistoryStore {

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("StockScreener/History", isDirectory: true)
    }

    private static func fileURL(_ day: String) -> URL {
        folder.appendingPathComponent("\(day).csv.lzfse")
    }

    static func exists(_ day: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(day).path)
    }

    /// Saves (or replaces) the snapshot for `day` ("yyyy-MM-dd") and prunes old days.
    static func save(csv: Data, day: String, keepDays: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let compressed = try (csv as NSData).compressed(using: .lzfse) as Data
        try compressed.write(to: fileURL(day), options: .atomic)
        prune(keepDays: keepDays)
    }

    /// Stored days, oldest first.
    static func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".csv.lzfse") }
            .map { String($0.dropLast(".csv.lzfse".count)) }
            .sorted()
    }

    static func load(_ day: String) -> Data? {
        guard let data = try? Data(contentsOf: fileURL(day)) else { return nil }
        return try? (data as NSData).decompressed(using: .lzfse) as Data
    }

    static func totalBytes() -> Int {
        days().reduce(0) { sum, day in
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(day).path)
            return sum + ((attrs?[.size] as? Int) ?? 0)
        }
    }

    static func prune(keepDays: Int) {
        let all = days()
        guard all.count > keepDays else { return }
        for day in all.prefix(all.count - keepDays) {
            try? FileManager.default.removeItem(at: fileURL(day))
        }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(fromKey key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    // MARK: Reading one stock's history

    struct Point: Identifiable {
        var id: String { day }
        let day: String
        let date: Date
        let row: SheetRow           // cells laid out in the CURRENT column order
    }

    /// Finds `symbol` in every stored day. Columns are matched by their sheet (original) names,
    /// so the result lines up with today's table even if columns moved.
    static func series(symbol: String, labelOriginalHeader: String, currentOriginalHeaders: [String]) -> [Point] {
        let needle = symbol.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var points: [Point] = []

        for (i, day) in days().enumerated() {
            guard let data = load(day), let text = String(data: data, encoding: .utf8),
                  let date = date(fromKey: day) else { continue }

            // Header line, then only lines that could contain the symbol (fast scan).
            var lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" })[...]
            guard let headerLine = lines.popFirst() else { continue }
            let headers = SheetService.cleanHeaders(CSVParser.parse(String(headerLine)).first ?? [])
            guard let labelIndex = headers.firstIndex(where: {
                SheetTable.normalize($0) == SheetTable.normalize(labelOriginalHeader)
            }) else { continue }

            var match: [String]?
            for line in lines where line.range(of: needle, options: .caseInsensitive) != nil {
                guard let cells = CSVParser.parse(String(line)).first, labelIndex < cells.count else { continue }
                if cells[labelIndex].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(needle) == .orderedSame {
                    match = cells
                    break
                }
            }
            guard let cells = match else { continue }

            // Re-order into today's columns.
            var byName: [String: Int] = [:]
            for (j, h) in headers.enumerated() where byName[SheetTable.normalize(h)] == nil {
                byName[SheetTable.normalize(h)] = j
            }
            let aligned = currentOriginalHeaders.map { name -> String in
                guard let j = byName[SheetTable.normalize(name)], j < cells.count else { return "" }
                return cells[j]
            }
            points.append(Point(day: day, date: date,
                                row: SheetRow(id: i, cells: aligned, numbers: aligned.map { NumberParser.parse($0) })))
        }
        return points
    }
}

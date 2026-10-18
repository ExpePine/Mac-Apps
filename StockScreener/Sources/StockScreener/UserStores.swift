import Foundation
import AppKit

/// ~/Library/Application Support/StockScreener
enum AppFolders {
    static var base: URL { HistoryStore.folder.deletingLastPathComponent() }
    static func folder(_ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Screenshots (per symbol, with vector annotations)

/// One drawn mark. Points are 0…1 of the image width/height, so they survive resizing.
struct Annotation: Codable, Identifiable, Equatable {
    enum Tool: String, Codable, CaseIterable { case pen, highlighter, line, arrow, rectangle, ellipse, text }
    var id = UUID()
    var tool: Tool
    var color: String            // hex "#RRGGBB"
    var width: Double            // points at 1000-px image width
    var points: [CGPoint]
    var text = ""
}

struct ScreenshotMeta: Codable {
    var note = ""
    var annotations: [Annotation] = []
}

struct Screenshot: Identifiable, Hashable {
    var id: String { url.path }
    let symbol: String
    let url: URL                 // the image
    let date: Date
    static func == (a: Screenshot, b: Screenshot) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum ScreenshotStore {
    static var root: URL { AppFolders.folder("Screenshots") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func safe(_ symbol: String) -> String {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        return String(s.map { $0.isLetter || $0.isNumber || "-_&.".contains($0) ? $0 : "_" })
    }

    static func folder(for symbol: String) -> URL {
        root.appendingPathComponent(safe(symbol), isDirectory: true)
    }

    /// Newest screenshot date per symbol folder (for the S column).
    static func index() -> [String: Date] {
        let fm = FileManager.default
        var out: [String: Date] = [:]
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let files = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
            let dates = files.filter { $0.hasSuffix(".png") }.compactMap { stamp.date(from: String($0.dropLast(4).prefix(15))) }
            if let newest = dates.max() { out[dir] = newest }
        }
        return out
    }

    /// Newest first.
    static func list(_ symbol: String) -> [Screenshot] {
        let dir = folder(for: symbol)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".png") }.compactMap { name in
            guard let d = stamp.date(from: String(name.dropLast(4).prefix(15))) else { return nil }
            return Screenshot(symbol: symbol, url: dir.appendingPathComponent(name), date: d)
        }.sorted { $0.date > $1.date }
    }

    static func symbolsWithShots() -> [String] {
        index().keys.sorted()
    }

    @discardableResult
    static func save(_ image: NSImage, symbol: String, date: Date = Date()) throws -> Screenshot {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dir = folder(for: symbol)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = stamp.string(from: date)
        var url = dir.appendingPathComponent(name + ".png")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {      // two in the same second
            name = stamp.string(from: date) + "-\(n)"; n += 1
            url = dir.appendingPathComponent(name + ".png")
        }
        try png.write(to: url, options: .atomic)
        return Screenshot(symbol: symbol, url: url, date: date)
    }

    static func metaURL(_ shot: Screenshot) -> URL { shot.url.deletingPathExtension().appendingPathExtension("json") }

    static func meta(_ shot: Screenshot) -> ScreenshotMeta {
        guard let data = try? Data(contentsOf: metaURL(shot)),
              let m = try? JSONDecoder().decode(ScreenshotMeta.self, from: data) else { return ScreenshotMeta() }
        return m
    }

    static func saveMeta(_ meta: ScreenshotMeta, for shot: Screenshot) {
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: metaURL(shot), options: .atomic) }
    }

    static func delete(_ shot: Screenshot) {
        try? FileManager.default.trashItem(at: shot.url, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: metaURL(shot), resultingItemURL: nil)
    }
}

// MARK: - Watchlists

struct WatchItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var symbol: String
    var addedAt = Date()
    var addedDay: String                 // yyyy-MM-dd (data day)
    var addedPrice: Double?
    var priceSource = ""                 // "Yahoo" or the sheet column it came from
    var note = ""
}

struct Watchlist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [WatchItem] = []
}

enum WatchlistStore {
    private static var url: URL { AppFolders.base.appendingPathComponent("watchlists.json") }

    static func load() -> [Watchlist] {
        guard let data = try? Data(contentsOf: url),
              let lists = try? JSONDecoder().decode([Watchlist].self, from: data), !lists.isEmpty else {
            return [Watchlist(name: "Watchlist")]
        }
        return lists
    }

    static func save(_ lists: [Watchlist]) {
        try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lists) { try? data.write(to: url, options: .atomic) }
    }
}

/// Returns for one watchlist item, from daily closes.
struct WatchReturns {
    var now: Double?
    var nowDay: String?
    var sinceAdded: Double?              // %
    var day1: Double?
    var day5: Double?
    var month1: Double?                  // 21 trading days
    var maxSinceAdded: Double?           // best close since added, %
    var fromPeak: Double?                // now vs best close since added, %
    var benchmark: Double?               // Nifty 50 over the same period, %
    var tradingDays: Int?

    static func compute(_ item: WatchItem, series: PriceSeries?, benchmark: PriceSeries?) -> WatchReturns {
        var r = WatchReturns()
        guard let s = series, let last = s.closes.last, let lastDay = s.lastDay else { return r }
        r.now = last
        r.nowDay = lastDay
        let n = s.closes.count
        func back(_ k: Int) -> Double? { n > k && s.closes[n - 1 - k] > 0 ? (last / s.closes[n - 1 - k] - 1) * 100 : nil }
        r.day1 = back(1); r.day5 = back(5); r.month1 = back(21)
        let start = item.addedPrice ?? s.index(onOrBefore: item.addedDay).map { s.closes[$0] }
        if let start, start > 0 {
            r.sinceAdded = (last / start - 1) * 100
            if let i = s.index(onOrBefore: item.addedDay) {
                r.tradingDays = n - 1 - i
                let peak = s.closes[i...].max() ?? last
                r.maxSinceAdded = (peak / start - 1) * 100
                r.fromPeak = (last / peak - 1) * 100
            }
        }
        if let b = benchmark, let bl = b.closes.last, let j = b.index(onOrBefore: item.addedDay), b.closes[j] > 0 {
            r.benchmark = (bl / b.closes[j] - 1) * 100
        }
        return r
    }
}

// MARK: - Notes & Pine scripts

struct TextDoc: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case requirements, pine
        var folderName: String { self == .requirements ? "MV2 Requirements" : "Pine Scripts" }
        var title: String { self == .requirements ? "MV2 Build Requirements" : "Pine Scripts" }
        var ext: String { self == .requirements ? "md" : "pine" }
    }
    var id: String { url.path }
    let kind: Kind
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var modified: Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }
}

enum TextDocStore {
    static func folder(_ kind: TextDoc.Kind) -> URL { AppFolders.folder(kind.folderName) }

    static func list(_ kind: TextDoc.Kind) -> [TextDoc] {
        let dir = folder(kind)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var docs = names.filter { $0.hasSuffix("." + kind.ext) }
            .map { TextDoc(kind: kind, url: dir.appendingPathComponent($0)) }
        if docs.isEmpty && kind == .requirements {
            if let d = try? create(kind, name: "MV2 Build Requirements", text: requirementsTemplate) { docs = [d] }
        }
        return docs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func read(_ doc: TextDoc) -> String {
        (try? String(contentsOf: doc.url, encoding: .utf8)) ?? ""
    }

    static func write(_ text: String, to doc: TextDoc) {
        try? text.write(to: doc.url, atomically: true, encoding: .utf8)
    }

    static func uniqueURL(_ kind: TextDoc.Kind, name: String) -> URL {
        let dir = folder(kind)
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "Untitled" : clean
        var url = dir.appendingPathComponent(base + "." + kind.ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)." + kind.ext); n += 1
        }
        return url
    }

    static func create(_ kind: TextDoc.Kind, name: String, text: String = "") throws -> TextDoc {
        let url = uniqueURL(kind, name: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return TextDoc(kind: kind, url: url)
    }

    static func rename(_ doc: TextDoc, to name: String) -> TextDoc? {
        let url = uniqueURL(doc.kind, name: name)
        do { try FileManager.default.moveItem(at: doc.url, to: url); return TextDoc(kind: doc.kind, url: url) } catch { return nil }
    }

    static func delete(_ doc: TextDoc) {
        try? FileManager.default.trashItem(at: doc.url, resultingItemURL: nil)
    }

    static let requirementsTemplate = """
    # MV2 Build Requirements

    ## Goal

    ## Data sources

    ## Columns
    | Column | Meaning | Formula / source |
    |---|---|---|

    ## Rules / filters

    ## Open questions

    """

    static let pineTemplate = """
    //@version=6
    indicator("My script", overlay=true)

    """
}

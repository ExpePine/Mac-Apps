import Foundation
import SwiftUI

// MARK: - Symbols

enum SymbolStatus: String, Codable, CaseIterable, Identifiable {
    case holding, watching, observationTG, observationOPN, exited, archived
    var id: String { rawValue }

    var title: String {
        switch self {
        case .holding: return "Holding"
        case .watching: return "Watching"
        case .observationTG: return "Observation / TG"
        case .observationOPN: return "Observation / OPN"
        case .exited: return "Exited"
        case .archived: return "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .holding: return "briefcase.fill"
        case .watching: return "eye.fill"
        case .observationTG: return "binoculars.fill"
        case .observationOPN: return "magnifyingglass.circle.fill"
        case .exited: return "arrow.uturn.left.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .holding: return .green
        case .watching: return .blue
        case .observationTG: return .purple
        case .observationOPN: return .teal
        case .exited: return .orange
        case .archived: return .secondary
        }
    }
}

struct TrackedSymbol: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// NSE symbol as you type it, e.g. RELIANCE, M&M, BAJAJ-AUTO.
    /// A value containing "." or starting with "^" is passed to Yahoo unchanged (e.g. ^NSEI).
    var ticker: String
    var displayName: String = ""
    var status: SymbolStatus = .watching
    var addedAt: Date = Date()
    var thesis: String = ""
    var tags: [String] = []

    var yahooSymbol: String {
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("^") || t.contains(".") { return t }
        return t + ".NS"
    }
}

// MARK: - Observations

enum Sentiment: String, Codable, CaseIterable, Identifiable {
    case bullish, neutral, bearish
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .bullish: return .green
        case .neutral: return .gray
        case .bearish: return .red
        }
    }
    var systemImage: String {
        switch self {
        case .bullish: return "arrow.up.right"
        case .neutral: return "minus"
        case .bearish: return "arrow.down.right"
        }
    }
}

enum ChartTimeframe: String, Codable, CaseIterable, Identifiable {
    case intraday, daily, weekly, monthly
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Observation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var symbolID: UUID
    /// The day you looked at the chart.
    var date: Date = Date()
    var timeframe: ChartTimeframe = .daily
    var sentiment: Sentiment = .neutral
    var text: String = ""
    var tags: [String] = []
    /// Optional price you noted yourself; outcomes use market data when available.
    var notedPrice: Double? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Chart screenshots: file names inside the app's Attachments folder.
    var attachments: [String]? = nil

    var imageFiles: [String] { attachments ?? [] }
}

// MARK: - News summaries (pasted by you)

struct NewsItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// nil = general market news, not tied to one stock.
    var symbolID: UUID?
    var date: Date = Date()
    var title: String = ""
    /// Where the summary came from, e.g. ChatGPT, Perplexity, Moneycontrol.
    var source: String = ""
    var text: String = ""
    var createdAt: Date = Date()
    /// NewsTag raw values.
    var tags: [String]? = nil

    var newsTags: [NewsTag] { (tags ?? []).compactMap(NewsTag.init(rawValue:)) }
}

enum NewsTag: String, Codable, CaseIterable, Identifiable {
    case multibagger, shortRise, patternBreakerGainer, patternBreakerLoser
    var id: String { rawValue }

    var title: String {
        switch self {
        case .multibagger: return "Multibagger"
        case .shortRise: return "Short rise"
        case .patternBreakerGainer: return "Pattern breaker – Gainer"
        case .patternBreakerLoser: return "Pattern breaker – Loser"
        }
    }

    var systemImage: String {
        switch self {
        case .multibagger: return "star.fill"
        case .shortRise: return "arrow.up.forward"
        case .patternBreakerGainer: return "chart.line.uptrend.xyaxis"
        case .patternBreakerLoser: return "chart.line.downtrend.xyaxis"
        }
    }

    var color: Color {
        switch self {
        case .multibagger: return .purple
        case .shortRise: return .teal
        case .patternBreakerGainer: return .green
        case .patternBreakerLoser: return .red
        }
    }
}

// MARK: - Pine Script library

struct ScriptVersion: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var number: Int
    var date: Date = Date()
    var code: String
    /// What changed in this version.
    var note: String = ""
    var linesAdded: Int? = nil
    var linesRemoved: Int? = nil
    /// File written to the app's PineScripts folder for this version.
    var fileName: String? = nil
}

struct PineScript: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var notes: String = ""
    var symbolIDs: [UUID] = []
    var createdAt: Date = Date()
    var versions: [ScriptVersion] = []

    var latest: ScriptVersion? { versions.max { $0.number < $1.number } }
    var updatedAt: Date { versions.map(\.date).max() ?? createdAt }
}

// MARK: - Trades

enum TradeSide: String, Codable, CaseIterable, Identifiable {
    case buy, sell
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color { self == .buy ? .green : .red }
}

struct Trade: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var symbolID: UUID
    var side: TradeSide = .buy
    var date: Date = Date()
    var quantity: Double = 1
    var price: Double = 0
    var note: String = ""
}

// MARK: - AI

enum AnalysisKind: String, Codable {
    case summary, priceComparison, patterns
    var title: String {
        switch self {
        case .summary: return "Summary"
        case .priceComparison: return "Notes vs Price"
        case .patterns: return "Cross-Symbol Patterns"
        }
    }
}

struct SavedAnalysis: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: AnalysisKind
    var symbolID: UUID?
    var text: String
    var model: String
    var createdAt: Date = Date()
}

struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant }
    var id: UUID = UUID()
    var role: Role
    var content: String
    var date: Date = Date()
}

// MARK: - Root document

struct AppData: Codable {
    var version: Int = 2
    var symbols: [TrackedSymbol] = []
    var observations: [Observation] = []
    var trades: [Trade] = []
    var analyses: [SavedAnalysis] = []
    var chat: [ChatMessage] = []
    var news: [NewsItem] = []
    var scripts: [PineScript] = []
}

extension AppData {
    /// Tolerates files from older versions of the app that lack newer sections.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        symbols = try c.decodeIfPresent([TrackedSymbol].self, forKey: .symbols) ?? []
        observations = try c.decodeIfPresent([Observation].self, forKey: .observations) ?? []
        trades = try c.decodeIfPresent([Trade].self, forKey: .trades) ?? []
        analyses = try c.decodeIfPresent([SavedAnalysis].self, forKey: .analyses) ?? []
        chat = try c.decodeIfPresent([ChatMessage].self, forKey: .chat) ?? []
        news = try c.decodeIfPresent([NewsItem].self, forKey: .news) ?? []
        scripts = try c.decodeIfPresent([PineScript].self, forKey: .scripts) ?? []
    }
}

// MARK: - Line diff (for Pine Script versions)

enum LineDiff: Hashable {
    case same(String), added(String), removed(String)

    /// LCS-based line diff. Returns nil when the inputs are too large to compare quickly.
    static func compute(_ old: [String], _ new: [String]) -> [LineDiff]? {
        let n = old.count, m = new.count
        guard n * m <= 6_000_000 else { return nil }
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * w + j] = old[i] == new[j]
                        ? table[(i + 1) * w + j + 1] + 1
                        : max(table[(i + 1) * w + j], table[i * w + j + 1])
                }
            }
        }
        var out: [LineDiff] = []
        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] { out.append(.same(old[i])); i += 1; j += 1 }
            else if table[(i + 1) * w + j] >= table[i * w + j + 1] { out.append(.removed(old[i])); i += 1 }
            else { out.append(.added(new[j])); j += 1 }
        }
        while i < n { out.append(.removed(old[i])); i += 1 }
        while j < m { out.append(.added(new[j])); j += 1 }
        return out
    }

    static func lines(_ code: String) -> [String] {
        code.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }
}

// MARK: - Market data

struct Candle: Identifiable, Hashable {
    var id: Date { date }
    var date: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double
}

struct ObservationOutcome {
    var referenceDate: Date
    var referenceClose: Double
    var after5: Double?     // % change 5 trading days later
    var after20: Double?    // % change 20 trading days later
    var sinceThen: Double   // % change to latest close
    var maxUp: Double       // best % move (high) since
    var maxDown: Double     // worst % move (low) since

    static func compute(for date: Date, candles: [Candle]) -> ObservationOutcome? {
        let day = Calendar.ist.startOfDay(for: date)
        guard let idx = candles.firstIndex(where: { $0.date >= day }),
              let last = candles.last else { return nil }
        let ref = candles[idx].close
        guard ref > 0 else { return nil }
        func pct(_ v: Double) -> Double { (v - ref) / ref * 100 }
        let after = candles[idx...]
        let hi = after.map(\.high).max() ?? ref
        let lo = after.map(\.low).min() ?? ref
        return ObservationOutcome(
            referenceDate: candles[idx].date,
            referenceClose: ref,
            after5: idx + 5 < candles.count ? pct(candles[idx + 5].close) : nil,
            after20: idx + 20 < candles.count ? pct(candles[idx + 20].close) : nil,
            sinceThen: pct(last.close),
            maxUp: pct(hi),
            maxDown: pct(lo)
        )
    }
}

// MARK: - Helpers

extension Calendar {
    static let ist: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
        return c
    }()
}

enum Fmt {
    static let price: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func rupees(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "₹" + (price.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%@%.2f%%", v >= 0 ? "+" : "", v)
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()

    static let isoDayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return f
    }()

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return f
    }()

    static func tags(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "#" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

extension Double {
    var changeColor: Color { self > 0 ? .green : (self < 0 ? .red : .secondary) }
}

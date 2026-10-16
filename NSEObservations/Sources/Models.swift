import Foundation
import SwiftUI

// MARK: - Symbols

enum SymbolStatus: String, Codable, CaseIterable, Identifiable {
    case holding, watching, exited, archived
    var id: String { rawValue }

    var title: String {
        switch self {
        case .holding: return "Holding"
        case .watching: return "Watching"
        case .exited: return "Exited"
        case .archived: return "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .holding: return "briefcase.fill"
        case .watching: return "eye.fill"
        case .exited: return "arrow.uturn.left.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .holding: return .green
        case .watching: return .blue
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
    var version: Int = 1
    var symbols: [TrackedSymbol] = []
    var observations: [Observation] = []
    var trades: [Trade] = []
    var analyses: [SavedAnalysis] = []
    var chat: [ChatMessage] = []
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

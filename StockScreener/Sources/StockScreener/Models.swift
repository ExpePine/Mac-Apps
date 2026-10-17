import SwiftUI

// MARK: - Sheet data

struct SheetRow: Identifiable {
    let id: Int
    let values: [String: String]   // column header -> cell text
}

// MARK: - Rules

enum RuleOperator: String, Codable, CaseIterable, Identifiable {
    case greaterThan = ">"
    case greaterOrEqual = "≥"
    case lessThan = "<"
    case lessOrEqual = "≤"
    case equals = "="
    case notEquals = "≠"
    case between = "between"
    case contains = "contains"
    case notContains = "doesn't contain"

    var id: String { rawValue }
    var needsSecondValue: Bool { self == .between }
}

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case green, red, yellow, orange, blue, purple

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .green:  return .green
        case .red:    return .red
        case .yellow: return .yellow
        case .orange: return .orange
        case .blue:   return .blue
        case .purple: return .purple
        }
    }
}

enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case all = "All rules (AND)"
    case any = "Any rule (OR)"
    var id: String { rawValue }
}

struct Rule: Identifiable, Codable, Equatable {
    var id = UUID()
    var isEnabled = true
    var column = ""
    var op: RuleOperator = .greaterThan
    var value = ""
    var value2 = ""                         // only used by "between"
    var color: HighlightColor = .green      // only used by highlight rules

    func matches(_ row: [String: String]) -> Bool {
        guard let cell = row[column] else { return false }

        switch op {
        case .contains:
            return cell.localizedCaseInsensitiveContains(value)
        case .notContains:
            return !cell.localizedCaseInsensitiveContains(value)
        case .equals, .notEquals:
            let isEqual: Bool
            if let a = NumberParser.parse(cell), let b = NumberParser.parse(value) {
                isEqual = a == b
            } else {
                isEqual = cell.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(value.trimmingCharacters(in: .whitespaces)) == .orderedSame
            }
            return op == .equals ? isEqual : !isEqual
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between:
            guard let a = NumberParser.parse(cell), let b = NumberParser.parse(value) else { return false }
            switch op {
            case .greaterThan:    return a > b
            case .greaterOrEqual: return a >= b
            case .lessThan:       return a < b
            case .lessOrEqual:    return a <= b
            case .between:
                guard let c = NumberParser.parse(value2) else { return false }
                return a >= min(b, c) && a <= max(b, c)
            default:
                return false
            }
        }
    }
}

// MARK: - Settings (persisted)

struct AppSettings: Codable {
    var sheetLink = ""           // pasted once in Settings; stored only on this Mac
    var refreshMinutes = 5
    var matchMode: MatchMode = .all
    var filterRules: [Rule] = []
    var highlightRules: [Rule] = []
    var staleAfterHours = 24     // warn if the sheet content hasn't changed for this long
    var dateColumn = ""          // optional: column that holds each row's data date

    init() {}

    // Tolerant decoding so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        sheetLink      = try c.decodeIfPresent(String.self, forKey: .sheetLink) ?? d.sheetLink
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? d.refreshMinutes
        matchMode      = try c.decodeIfPresent(MatchMode.self, forKey: .matchMode) ?? d.matchMode
        filterRules    = try c.decodeIfPresent([Rule].self, forKey: .filterRules) ?? d.filterRules
        highlightRules = try c.decodeIfPresent([Rule].self, forKey: .highlightRules) ?? d.highlightRules
        staleAfterHours = try c.decodeIfPresent(Int.self, forKey: .staleAfterHours) ?? d.staleAfterHours
        dateColumn     = try c.decodeIfPresent(String.self, forKey: .dateColumn) ?? d.dateColumn
    }
}

/// Tracks whether the sheet's content is actually changing.
struct FreshnessState: Codable {
    var dataHash: String?        // SHA-256 of the last downloaded CSV
    var lastChangedAt: Date?     // when we last saw the content change
    var lastCheckedAt: Date?     // when we last fetched successfully
}

enum Persistence {
    private static let settingsKey = "StockScreener.settings.v1"
    private static let freshnessKey = "StockScreener.freshness.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    static func loadFreshness() -> FreshnessState {
        guard let data = UserDefaults.standard.data(forKey: freshnessKey),
              let state = try? JSONDecoder().decode(FreshnessState.self, from: data) else {
            return FreshnessState()
        }
        return state
    }

    static func saveFreshness(_ state: FreshnessState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: freshnessKey)
        }
    }
}

// MARK: - Number parsing

/// Turns cell text like "1,234.5", "₹2,450", "-3.2%", "12.4 B", "850 Cr" into a Double.
enum NumberParser {
    static func parse(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "—" || s == "-" { return nil }

        s = s.replacingOccurrences(of: "\u{2212}", with: "-")  // unicode minus
        for junk in ["₹", "$", ",", "%", "+", " ", "\u{00A0}", "\u{202F}"] {
            s = s.replacingOccurrences(of: junk, with: "")
        }

        var multiplier = 1.0
        let suffixes: [(String, Double)] = [
            ("Cr", 1e7), ("cr", 1e7), ("L", 1e5),
            ("K", 1e3), ("k", 1e3), ("M", 1e6), ("B", 1e9), ("T", 1e12)
        ]
        for (suffix, mult) in suffixes where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            multiplier = mult
            break
        }

        guard let value = Double(s) else { return nil }
        return value * multiplier
    }
}

// MARK: - Date parsing

/// Parses common sheet date formats. Ambiguous dates like 05/06/2026 are read as dd/MM (Indian style).
enum DateParser {
    private static let formatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
            "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy",
            "dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm", "dd-MM-yyyy",
            "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy",
            "dd-MMM-yyyy", "dd MMM yyyy", "d MMM yyyy", "MMM d, yyyy"
        ]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = pattern
            f.isLenient = false
            return f
        }
    }()

    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

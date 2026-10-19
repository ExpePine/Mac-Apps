import SwiftUI
import AppKit

// MARK: - Sheet data (parsed once per download)

/// One data row. `cells` is the raw text; `numbers` is each cell parsed as a number once, up front,
/// so filters, sorting and coloring never re-parse text.
struct SheetRow: Identifiable {
    let id: Int                 // 0-based data row; the sheet row number is id + 2
    let cells: [String]
    let numbers: [Double?]

    @inline(__always) func text(_ column: Int) -> String {
        column < cells.count ? cells[column] : ""
    }

    @inline(__always) func number(_ column: Int) -> Double? {
        column < numbers.count ? numbers[column] : nil
    }
}

struct SheetTable {
    var headers: [String] = []           // names shown everywhere (your real names, if set)
    var originalHeaders: [String] = []   // names exactly as in the Google Sheet
    var rows: [SheetRow] = []
    private var lookup: [String: Int] = [:]

    init() {}

    init(headers: [String], rows: [SheetRow], originalHeaders: [String]? = nil) {
        self.headers = headers
        self.rows = rows
        self.originalHeaders = originalHeaders ?? headers
        for (i, h) in headers.enumerated() where lookup[Self.normalize(h)] == nil {
            lookup[Self.normalize(h)] = i
        }
        // The sheet's own names keep working too (e.g. in an old formula).
        for (i, h) in self.originalHeaders.enumerated() where lookup[Self.normalize(h)] == nil {
            lookup[Self.normalize(h)] = i
        }
    }

    /// Same data with your real column names applied. Blank or clashing names fall back to the sheet's name.
    func renamed(with aliases: [String: String]) -> SheetTable {
        var used = Set<String>()
        var display: [String] = []
        // Columns you renamed claim their names first; the rest keep the sheet name unless it's taken.
        let wanted = originalHeaders.map { orig -> String in
            let a = (aliases[orig] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return a.isEmpty ? orig : a
        }
        let renamedFirst = originalHeaders.indices.sorted { a, b in
            (wanted[a] != originalHeaders[a] ? 0 : 1, a) < (wanted[b] != originalHeaders[b] ? 0 : 1, b)
        }
        var result = Array(repeating: "", count: originalHeaders.count)
        for i in renamedFirst {
            var name = wanted[i]
            if used.contains(Self.normalize(name)) { name = originalHeaders[i] }
            if used.contains(Self.normalize(name)) { name = "\(originalHeaders[i]) (\(i + 1))" }
            used.insert(Self.normalize(name))
            result[i] = name
        }
        display = result
        return SheetTable(headers: display, rows: rows, originalHeaders: originalHeaders)
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Column index by name, ignoring case and surrounding spaces.
    func index(of name: String) -> Int? {
        let key = Self.normalize(name)
        return key.isEmpty ? nil : lookup[key]
    }
}

// MARK: - Conditions

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
    case startsWith = "starts with"
    case hasValue = "has a value"
    case isEmpty = "is empty"

    var id: String { rawValue }
    var needsSecondValue: Bool { self == .between }
    var needsValue: Bool { self != .hasValue && self != .isEmpty }
    /// Operators that can compare against another column.
    var allowsColumnTarget: Bool {
        [.greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .equals, .notEquals].contains(self)
    }
}

enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case all = "All rules (AND)"
    case any = "Any rule (OR)"
    case notAny = "None of (NOT)"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All of (AND)"
        case .any: return "Any of (OR)"
        case .notAny: return "None of (NOT)"
        }
    }
}

/// Simple single-column rule. Used by cell color rules.
struct Rule: Identifiable, Codable, Equatable {
    var id = UUID()
    var isEnabled = true
    var column = ""
    var op: RuleOperator = .greaterThan
    var value = ""
    var value2 = ""

    init(id: UUID = UUID(), isEnabled: Bool = true, column: String = "", op: RuleOperator = .greaterThan,
         value: String = "", value2: String = "") {
        self.id = id; self.isEnabled = isEnabled; self.column = column
        self.op = op; self.value = value; self.value2 = value2
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        column    = (try? c.decodeIfPresent(String.self, forKey: .column)) ?? ""
        op        = (try? c.decodeIfPresent(RuleOperator.self, forKey: .op)) ?? .greaterThan
        value     = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
        value2    = (try? c.decodeIfPresent(String.self, forKey: .value2)) ?? ""
    }
}

enum ConditionKind: String, Codable { case compare, formula }

enum CompareTarget: String, Codable, CaseIterable, Identifiable {
    case value = "Value"
    case column = "Column"
    var id: String { rawValue }
}

/// One condition in an advanced filter: either "column op value/other column", or a formula.
struct FilterCondition: Identifiable, Codable, Equatable {
    var id = UUID()
    var isEnabled = true
    var kind: ConditionKind = .compare
    var column = ""
    var op: RuleOperator = .greaterThan
    var target: CompareTarget = .value
    var value = ""
    var value2 = ""
    var otherColumn = ""
    var factor = "1"            // other column × factor (e.g. 1.02 = 2% above)
    var formula = ""

    init(kind: ConditionKind = .compare, column: String = "", op: RuleOperator = .greaterThan,
         target: CompareTarget = .value, value: String = "", value2: String = "",
         otherColumn: String = "", factor: String = "1", formula: String = "") {
        self.kind = kind; self.column = column; self.op = op; self.target = target
        self.value = value; self.value2 = value2; self.otherColumn = otherColumn
        self.factor = factor; self.formula = formula
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        id = v(.id, UUID()); isEnabled = v(.isEnabled, true); kind = v(.kind, .compare)
        column = v(.column, ""); op = v(.op, .greaterThan); target = v(.target, .value)
        value = v(.value, ""); value2 = v(.value2, ""); otherColumn = v(.otherColumn, "")
        factor = v(.factor, "1"); formula = v(.formula, "")
    }
}

/// A group of conditions and sub-groups combined with AND / OR / NOT.
struct FilterGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var isEnabled = true
    var mode: MatchMode = .all
    var conditions: [FilterCondition] = []
    var groups: [FilterGroup] = []

    init(mode: MatchMode = .all, conditions: [FilterCondition] = [], groups: [FilterGroup] = []) {
        self.mode = mode; self.conditions = conditions; self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        id = v(.id, UUID()); isEnabled = v(.isEnabled, true); mode = v(.mode, .all)
        conditions = v(.conditions, []); groups = v(.groups, [])
    }

    var activeCount: Int {
        guard isEnabled else { return 0 }
        return conditions.filter(\.isEnabled).count + groups.reduce(0) { $0 + $1.activeCount }
    }
}

// MARK: - Settings (persisted)

struct AppSettings: Codable {
    var sheetLink = ""           // pasted once in Settings; stored only on this Mac
    var refreshMinutes = 5
    var staleAfterHours = 24     // warn if the sheet content hasn't changed for this long
    var dateColumn = ""          // optional: column that holds each row's data date

    // Filter screen
    var triggerColumn = "D_Trigger"
    var labelColumn = ""                 // stock name column; "" = first sheet column
    var filterColumns: [String] = []     // visible columns, in order; empty = trigger column and after
    var filterSortColumn = "D_Trigger"
    var filterSortDescending = true
    var filterGroup = FilterGroup(conditions: [FilterCondition(column: "D_Trigger", op: .hasValue)])
    var cellRules: [CellRule] = []
    var columnAliases: [String: String] = [:]   // sheet column name -> your real name
    var frozenColumns = 1                       // columns pinned on the left of both tables
    var historyKeepDays = 45                    // used only when historyKeepForever is off
    var historyKeepForever = true               // keep every daily snapshot (training data for the neural net)
    var historyColumns: [String] = []           // columns shown in the animation; empty = Filter columns
    var tgThreshold = 7.0                       // Top Gainers: change% above this
    var nnGainThreshold = 30                    // monthly gainer: % gain within the window
    var nnWindowDays = 21                       // ~1 month of trading days
    var nnFeatures: [String] = []               // model inputs you picked; empty = auto-pick (Filter columns that are features)
    var changeCards: [ChangeCard] = ChangeCard.defaults(trigger: "D_Trigger")   // Changes screen
    var changeHideEmpty = false
    // Performance pane
    var perfStudies: [PerfStudy] = [PerfStudy()]
    var perfSheetLink = ""                      // the experiments sheet
    var perfSymbolColumn = ""                   // its stock-name column ("" = first column)
    var perfImportedColumns: [String] = []      // columns taken from the experiments sheet
    var perfCompareHorizon = 21                 // compare indicators on the return after this many trading days
    var perfCompareTarget = 20.0                // "+target %" for speed / hit rates
    var perfCompareStop = 10.0                  // "−stop %" for risk (which comes first)

    // Alerts
    var email = EmailSettings()
    var mv2 = MV2CheckSettings()
    var buyTriggers: [BuyTrigger] = [BuyTrigger()]

    init() {}

    // Tolerant decoding so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        sheetLink       = v(.sheetLink, d.sheetLink)
        refreshMinutes  = v(.refreshMinutes, d.refreshMinutes)
        staleAfterHours = v(.staleAfterHours, d.staleAfterHours)
        dateColumn      = v(.dateColumn, d.dateColumn)
        triggerColumn   = v(.triggerColumn, d.triggerColumn)
        labelColumn     = v(.labelColumn, d.labelColumn)
        filterColumns   = v(.filterColumns, d.filterColumns)
        filterSortColumn = v(.filterSortColumn, triggerColumn)
        filterSortDescending = v(.filterSortDescending, d.filterSortDescending)
        filterGroup     = v(.filterGroup, FilterGroup(conditions: [FilterCondition(column: triggerColumn, op: .hasValue)]))
        cellRules       = v(.cellRules, d.cellRules)
        columnAliases   = v(.columnAliases, d.columnAliases)
        frozenColumns   = v(.frozenColumns, d.frozenColumns)
        historyKeepDays = v(.historyKeepDays, d.historyKeepDays)
        historyKeepForever = v(.historyKeepForever, d.historyKeepForever)
        historyColumns  = v(.historyColumns, d.historyColumns)
        tgThreshold     = v(.tgThreshold, d.tgThreshold)
        nnGainThreshold = v(.nnGainThreshold, d.nnGainThreshold)
        nnWindowDays    = v(.nnWindowDays, d.nnWindowDays)
        nnFeatures      = v(.nnFeatures, d.nnFeatures)
        changeCards     = v(.changeCards, ChangeCard.defaults(trigger: triggerColumn))
        changeHideEmpty = v(.changeHideEmpty, d.changeHideEmpty)
        perfStudies     = v(.perfStudies, d.perfStudies)
        perfSheetLink   = v(.perfSheetLink, d.perfSheetLink)
        perfSymbolColumn = v(.perfSymbolColumn, d.perfSymbolColumn)
        perfImportedColumns = v(.perfImportedColumns, d.perfImportedColumns)
        perfCompareHorizon = v(.perfCompareHorizon, d.perfCompareHorizon)
        perfCompareTarget = v(.perfCompareTarget, d.perfCompareTarget)
        perfCompareStop = v(.perfCompareStop, d.perfCompareStop)
        email           = v(.email, d.email)
        mv2             = v(.mv2, d.mv2)
        buyTriggers     = v(.buyTriggers, d.buyTriggers)
    }
}

// MARK: - Cell colors (Filter screen)

/// Background shades a cell can be painted with.
enum Shade: String, Codable, CaseIterable, Identifiable {
    case none
    case lightGreen, green, darkGreen, teal
    case lightRed, red, darkRed
    case orange, yellow, blue, purple, grey

    var id: String { rawValue }

    var name: String {
        switch self {
        case .none:       return "Neutral"
        case .lightGreen: return "Light green"
        case .green:      return "Green"
        case .darkGreen:  return "Dark green"
        case .teal:       return "Teal"
        case .lightRed:   return "Light red"
        case .red:        return "Red"
        case .darkRed:    return "Dark red"
        case .orange:     return "Orange"
        case .yellow:     return "Yellow"
        case .blue:       return "Blue"
        case .purple:     return "Purple"
        case .grey:       return "Grey"
        }
    }

    private var rgba: (Double, Double, Double, Double)? {
        switch self {
        case .none:       return nil
        case .lightGreen: return (0.20, 0.78, 0.35, 0.18)
        case .green:      return (0.20, 0.78, 0.35, 0.40)
        case .darkGreen:  return (0.05, 0.55, 0.20, 0.65)
        case .teal:       return (0.10, 0.65, 0.65, 0.35)
        case .lightRed:   return (0.95, 0.25, 0.25, 0.18)
        case .red:        return (0.95, 0.25, 0.25, 0.40)
        case .darkRed:    return (0.70, 0.08, 0.10, 0.65)
        case .orange:     return (1.00, 0.55, 0.00, 0.35)
        case .yellow:     return (1.00, 0.85, 0.00, 0.40)
        case .blue:       return (0.20, 0.50, 1.00, 0.30)
        case .purple:     return (0.60, 0.35, 0.90, 0.30)
        case .grey:       return (0.50, 0.50, 0.50, 0.25)
        }
    }

    var color: Color? {
        rgba.map { Color(red: $0.0, green: $0.1, blue: $0.2).opacity($0.3) }
    }

    var nsColor: NSColor? {
        rgba.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) }
    }
}

/// "If <column> <op> <value>, paint the cell <shade>". Several rules per column; first match wins.
struct CellRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var condition = Rule()
    var shade: Shade = .green
}

// MARK: - Alert settings

struct EmailSettings: Codable, Equatable {
    var host = "smtp.gmail.com"
    var port = 465
    var username = ""            // your Gmail address (also the sender). Password is in the Keychain.
    var recipients = ""          // comma-separated; empty = send to yourself
}

struct MV2CheckSettings: Codable, Equatable {
    var isEnabled = true
    var monthColumn = "D_month"
    var dayColumn = "D_day"
    var skipWeekends = true
    var subject = "MV2 not updated"
}

struct BuyTrigger: Identifiable, Codable, Equatable {
    var id = UUID()
    var isEnabled = false
    var name = "Buy trigger"
    var filter = FilterGroup()
    var recipients = ""          // empty = use the email settings' recipients
    var sendEmail = true         // email the matching stocks
    var alertInApp = true        // pop up in the app when it opens / when new data meets the rule
    var symbol = ""              // "" = every stock; otherwise only this stock (set from its E button)

    init(isEnabled: Bool = false, name: String = "Buy trigger") {
        self.isEnabled = isEnabled
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, name, filter, recipients, sendEmail, alertInApp, symbol
        case conditions, matchMode   // older versions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        isEnabled  = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        name       = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Buy trigger"
        recipients = (try? c.decodeIfPresent(String.self, forKey: .recipients)) ?? ""
        sendEmail  = (try? c.decodeIfPresent(Bool.self, forKey: .sendEmail)) ?? true
        alertInApp = (try? c.decodeIfPresent(Bool.self, forKey: .alertInApp)) ?? true
        symbol     = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? ""
        if let f = try? c.decodeIfPresent(FilterGroup.self, forKey: .filter) {
            filter = f
        } else {
            // Upgrade from the simple condition list.
            let old = (try? c.decodeIfPresent([Rule].self, forKey: .conditions)) ?? []
            let mode = (try? c.decodeIfPresent(MatchMode.self, forKey: .matchMode)) ?? .all
            filter = FilterGroup(mode: mode, conditions: old.map {
                var fc = FilterCondition(column: $0.column, op: $0.op, value: $0.value, value2: $0.value2)
                fc.isEnabled = $0.isEnabled
                return fc
            })
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(name, forKey: .name)
        try c.encode(filter, forKey: .filter)
        try c.encode(recipients, forKey: .recipients)
        try c.encode(sendEmail, forKey: .sendEmail)
        try c.encode(alertInApp, forKey: .alertInApp)
        try c.encode(symbol, forKey: .symbol)
    }
}

/// One line in the Alerts window's history.
struct AlertLogEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
    var success: Bool
}

/// Remembers what was already emailed today, so alerts aren't repeated.
struct AlertState: Codable {
    var day = ""                     // yyyy-MM-dd the sets below belong to
    var mv2Alerted = false
    var buySent: [String: [String]] = [:]   // trigger id -> row keys already emailed today
    var log: [AlertLogEntry] = []
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
    private static let alertKey = "StockScreener.alerts.v1"

    private static func load<T: Decodable>(_ key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return decoded
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> AppSettings { load(settingsKey, default: AppSettings()) }
    static func save(_ settings: AppSettings) { save(settings, settingsKey) }
    static func loadFreshness() -> FreshnessState { load(freshnessKey, default: FreshnessState()) }
    static func saveFreshness(_ state: FreshnessState) { save(state, freshnessKey) }
    static func loadAlertState() -> AlertState { load(alertKey, default: AlertState()) }
    static func saveAlertState(_ state: AlertState) { save(state, alertKey) }
}

// MARK: - Number parsing

/// Turns cell text like "1,234.5", "₹2,450", "-3.2%", "12.4 B", "850 Cr" into a Double.
enum NumberParser {
    static func parse(_ raw: String) -> Double? {
        // Fast path: most cells are plain numbers or plain text.
        if let d = Double(raw) { return d }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "—" || s == "-" { return nil }
        if let d = Double(s) { return d }
        // Text with no digits (symbols, names) can never be a number.
        guard s.contains(where: { $0.isNumber }) else { return nil }

        s = s.replacingOccurrences(of: "\u{2212}", with: "-")  // unicode minus
        for junk in ["₹", "$", ",", "%", "+", " ", "\u{00A0}", "\u{202F}"] where s.contains(junk) {
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
        // Cheap rejection before trying formatters: dates have digits and a separator.
        guard s.count >= 6, s.count <= 25, s.contains(where: { $0.isNumber }),
              s.contains(where: { $0 == "-" || $0 == "/" || $0 == " " }) else { return nil }
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

import Foundation

/// One card on the Changes screen: a condition on how a stock changed between two days.
struct ChangeCard: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case increased, decreased, changed, crossedAbove, crossedBelow, appeared, cleared
        case enteredFilter, leftFilter, newStock, droppedStock

        var title: String {
            switch self {
            case .increased: return "Went up"
            case .decreased: return "Went down"
            case .changed: return "Changed"
            case .crossedAbove: return "Crossed above"
            case .crossedBelow: return "Crossed below"
            case .appeared: return "Got a value (was blank)"
            case .cleared: return "Became blank"
            case .enteredFilter: return "Entered the Filter list"
            case .leftFilter: return "Left the Filter list"
            case .newStock: return "New stock in the sheet"
            case .droppedStock: return "Stock gone from the sheet"
            }
        }
        /// Needs a column to compare.
        var needsColumn: Bool { ![.enteredFilter, .leftFilter, .newStock, .droppedStock].contains(self) }
        /// Uses the amount field.
        var needsAmount: Bool { [.increased, .decreased, .changed, .crossedAbove, .crossedBelow].contains(self) }
        var usesUnit: Bool { [.increased, .decreased, .changed].contains(self) }
    }
    enum Unit: String, Codable, CaseIterable { case absolute, percent }
    enum Scope: String, Codable, CaseIterable {
        case all, filter, watchlists
        var title: String {
            switch self {
            case .all: return "All stocks"
            case .filter: return "Only stocks in the Filter list"
            case .watchlists: return "Only stocks in my watchlists"
            }
        }
    }

    var id = UUID()
    var isEnabled = true
    var name = ""
    var kind: Kind = .increased
    var column = ""                 // compared column (or shown column for Filter / new-stock cards)
    var amount = 0.0
    var unit: Unit = .absolute
    var scope: Scope = .all
    var color = "#34C759"

    init(name: String, kind: Kind, column: String = "", amount: Double = 0, unit: Unit = .absolute,
         scope: Scope = .all, color: String) {
        self.name = name; self.kind = kind; self.column = column; self.amount = amount
        self.unit = unit; self.scope = scope; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        id = v(.id, UUID()); isEnabled = v(.isEnabled, true); name = v(.name, ""); kind = v(.kind, .increased)
        column = v(.column, ""); amount = v(.amount, 0); unit = v(.unit, .absolute); scope = v(.scope, .all)
        color = v(.color, "#34C759")
    }

    /// e.g. "RSI_14 went up by ≥ 5", "D_Trigger got a value".
    var describe: String {
        func n(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...2))) }
        let u = unit == .percent ? "%" : ""
        switch kind {
        case .increased: return amount > 0 ? "\(column) went up by ≥ \(n(amount))\(u)" : "\(column) went up"
        case .decreased: return amount > 0 ? "\(column) went down by ≥ \(n(amount))\(u)" : "\(column) went down"
        case .changed: return amount > 0 ? "\(column) changed by ≥ \(n(amount))\(u) either way" : "\(column) changed"
        case .crossedAbove: return "\(column) crossed above \(n(amount))"
        case .crossedBelow: return "\(column) crossed below \(n(amount))"
        case .appeared: return "\(column) got a value (was blank)"
        case .cleared: return "\(column) became blank"
        case .enteredFilter: return "Now passes the Filter conditions, didn't before"
        case .leftFilter: return "Passed the Filter conditions before, not now"
        case .newStock: return "In the sheet now, not before"
        case .droppedStock: return "In the sheet before, not now"
        }
    }

    static func defaults(trigger: String) -> [ChangeCard] {
        [
            ChangeCard(name: "Entered Filter", kind: .enteredFilter, column: trigger, color: "#34C759"),
            ChangeCard(name: "Left Filter", kind: .leftFilter, column: trigger, color: "#FF3B30"),
            ChangeCard(name: "\(trigger) appeared", kind: .appeared, column: trigger, color: "#FF9500"),
            ChangeCard(name: "\(trigger) went up", kind: .increased, column: trigger, scope: .filter, color: "#007AFF"),
            ChangeCard(name: "New in sheet", kind: .newStock, column: trigger, color: "#AF52DE"),
        ]
    }
}

struct ChangeItem: Identifiable {
    var id: String { symbol }
    let symbol: String
    let old: String
    let new: String
    let delta: Double?
    let percent: Double?
}

struct ChangeResult {
    var items: [ChangeItem] = []
    var problem: String?            // e.g. column not found
}

enum ChangeEngine {
    /// Compares `current` with `previous` (same column layout) for one card.
    static func evaluate(_ card: ChangeCard, current: SheetTable, previous: SheetTable, label: Int,
                         filterNow: Set<String>, filterBefore: Set<String>, watch: Set<String>) -> ChangeResult {
        var result = ChangeResult()
        func key(_ r: SheetRow) -> String { r.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
        var now: [String: SheetRow] = [:], before: [String: SheetRow] = [:]
        for r in current.rows { let k = key(r); if !k.isEmpty, now[k] == nil { now[k] = r } }
        for r in previous.rows { let k = key(r); if !k.isEmpty, before[k] == nil { before[k] = r } }

        let col = current.index(of: card.column)
        if card.kind.needsColumn && col == nil {
            result.problem = card.column.isEmpty ? "Pick a column for this card" : "Column \(card.column) not found"
            return result
        }
        func inScope(_ s: String) -> Bool {
            switch card.scope {
            case .all: return true
            case .filter: return filterNow.contains(s) || (card.kind == .leftFilter && filterBefore.contains(s))
            case .watchlists: return watch.contains(s)
            }
        }
        func shown(_ r: SheetRow?) -> String {
            guard let r, let c = col else { return "" }
            return r.text(c)
        }
        func item(_ s: String, _ a: SheetRow?, _ b: SheetRow?) -> ChangeItem {
            var d: Double?, p: Double?
            if let c = col, let x = a?.number(c), let y = b?.number(c) {
                d = x - y
                p = y != 0 ? (x - y) / abs(y) * 100 : nil
            }
            return ChangeItem(symbol: s, old: shown(b), new: shown(a), delta: d, percent: p)
        }

        var out: [ChangeItem] = []
        switch card.kind {
        case .enteredFilter:
            for s in filterNow.subtracting(filterBefore) where inScope(s) { out.append(item(s, now[s], before[s])) }
        case .leftFilter:
            for s in filterBefore.subtracting(filterNow) where inScope(s) { out.append(item(s, now[s], before[s])) }
        case .newStock:
            for (s, r) in now where before[s] == nil && inScope(s) { out.append(item(s, r, nil)) }
        case .droppedStock:
            for (s, r) in before where now[s] == nil && inScope(s) { out.append(item(s, nil, r)) }
        default:
            guard let c = col else { break }
            for (s, a) in now where inScope(s) {
                guard let b = before[s] else { continue }
                let x = a.number(c), y = b.number(c)
                let ta = a.text(c).trimmingCharacters(in: .whitespaces), tb = b.text(c).trimmingCharacters(in: .whitespaces)
                func bigEnough(_ diff: Double) -> Bool {
                    let size = card.unit == .percent ? (y.map { $0 != 0 ? abs(diff) / abs($0) * 100 : .infinity } ?? 0) : abs(diff)
                    return card.amount > 0 ? size >= card.amount : size > 1e-12
                }
                var hit = false
                switch card.kind {
                case .increased: if let x, let y, x > y { hit = bigEnough(x - y) }
                case .decreased: if let x, let y, x < y { hit = bigEnough(x - y) }
                case .changed:
                    if let x, let y { hit = x != y && bigEnough(x - y) } else { hit = ta != tb && card.amount == 0 }
                case .crossedAbove: if let x, let y { hit = y <= card.amount && x > card.amount }
                case .crossedBelow: if let x, let y { hit = y >= card.amount && x < card.amount }
                case .appeared: hit = tb.isEmpty && !ta.isEmpty
                case .cleared: hit = !tb.isEmpty && ta.isEmpty
                default: break
                }
                if hit { out.append(item(s, a, b)) }
            }
        }
        // Biggest changes first; otherwise alphabetical
        result.items = out.sorted { l, r in
            let a = abs(l.percent ?? l.delta ?? 0), b = abs(r.percent ?? r.delta ?? 0)
            return a != b ? a > b : l.symbol < r.symbol
        }
        return result
    }

    static func symbols(_ t: SheetTable, label: Int, where predicate: RowPredicate?) -> Set<String> {
        Set((predicate.map { t.rows.filter($0) } ?? t.rows).map { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty })
    }
}

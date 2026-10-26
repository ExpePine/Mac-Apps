import Foundation
import AppKit

typealias RowPredicate = (SheetRow) -> Bool

// MARK: - Compiling filters
//
// Filters are turned into closures once (column names resolved to indices, numbers parsed),
// then run over every row. This is what keeps filtering fast on big sheets.

enum FilterCompiler {

    /// nil means "no active conditions" (every row passes). Problems are appended to `issues`.
    static func compile(_ group: FilterGroup, table: SheetTable, issues: inout [String]) -> RowPredicate? {
        guard group.isEnabled else { return nil }
        var parts: [RowPredicate] = []
        for c in group.conditions where c.isEnabled {
            if let p = compile(c, table: table, issues: &issues) { parts.append(p) }
        }
        for g in group.groups {
            if let p = compile(g, table: table, issues: &issues) { parts.append(p) }
        }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            let only = parts[0]
            return group.mode == .notAny ? { !only($0) } : only
        }
        switch group.mode {
        case .all:    return { row in parts.allSatisfy { $0(row) } }
        case .any:    return { row in parts.contains { $0(row) } }
        case .notAny: return { row in !parts.contains { $0(row) } }
        }
    }

    static func compile(_ c: FilterCondition, table: SheetTable, issues: inout [String]) -> RowPredicate? {
        if c.kind == .formula {
            let text = c.formula.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            do {
                return try Formula.compile(text, table: table).predicate
            } catch {
                issues.append("Formula \"\(text)\": \(error.localizedDescription)")
                return nil
            }
        }

        guard !c.column.isEmpty else { return nil }
        guard let col = table.index(of: c.column) else {
            if !table.headers.isEmpty { issues.append("Column \"\(c.column)\" not found") }
            return nil
        }

        switch c.op {
        case .hasValue:
            return { hasValue($0.text(col)) }
        case .isEmpty:
            return { !hasValue($0.text(col)) }
        case .contains, .notContains, .startsWith:
            let needle = c.value.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return nil }
            switch c.op {
            case .contains:    return { $0.text(col).range(of: needle, options: .caseInsensitive) != nil }
            case .notContains: return { $0.text(col).range(of: needle, options: .caseInsensitive) == nil }
            default:           return { $0.text(col).range(of: needle, options: [.caseInsensitive, .anchored]) != nil }
            }
        case .between:
            guard let a = NumberParser.parse(c.value), let b = NumberParser.parse(c.value2) else { return nil }
            let lo = min(a, b), hi = max(a, b)
            return { row in row.number(col).map { $0 >= lo && $0 <= hi } ?? false }
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .equals, .notEquals:
            let op = c.op
            if c.target == .column {
                guard !c.otherColumn.isEmpty else { return nil }
                guard let other = table.index(of: c.otherColumn) else {
                    if !table.headers.isEmpty { issues.append("Column \"\(c.otherColumn)\" not found") }
                    return nil
                }
                let factor = NumberParser.parse(c.factor) ?? 1
                return { row in
                    guard let x = row.number(col), let y = row.number(other) else {
                        // Fall back to text equality for non-numeric columns.
                        if op == .equals || op == .notEquals {
                            let same = row.text(col).caseInsensitiveCompare(row.text(other)) == .orderedSame
                            return op == .equals ? same : !same
                        }
                        return false
                    }
                    return compare(x, op, y * factor)
                }
            }
            let raw = c.value.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            if let b = NumberParser.parse(raw) {
                return { row in
                    guard let x = row.number(col) else { return op == .notEquals }
                    return compare(x, op, b)
                }
            }
            // Text value: only = and ≠ make sense.
            guard op == .equals || op == .notEquals else {
                issues.append("\"\(raw)\" isn't a number, so \(c.column) \(op.rawValue) \(raw) can't be checked")
                return nil
            }
            return { row in
                let same = row.text(col).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(raw) == .orderedSame
                return op == .equals ? same : !same
            }
        }
    }

    /// Columns a filter refers to (used to pick what to show in buy-trigger emails).
    static func referencedColumns(_ group: FilterGroup, table: SheetTable) -> [Int] {
        var out: [Int] = []
        func add(_ i: Int?) { if let i, !out.contains(i) { out.append(i) } }
        func walk(_ g: FilterGroup) {
            guard g.isEnabled else { return }
            for c in g.conditions where c.isEnabled {
                if c.kind == .formula {
                    for i in (try? Formula.compile(c.formula, table: table).columns) ?? [] { add(i) }
                } else {
                    add(table.index(of: c.column))
                    if c.target == .column { add(table.index(of: c.otherColumn)) }
                }
            }
            g.groups.forEach(walk)
        }
        walk(group)
        return out
    }

    @inline(__always) static func compare(_ x: Double, _ op: RuleOperator, _ y: Double) -> Bool {
        switch op {
        case .greaterThan:    return x > y
        case .greaterOrEqual: return x >= y
        case .lessThan:       return x < y
        case .lessOrEqual:    return x <= y
        case .equals:         return abs(x - y) < 1e-9
        case .notEquals:      return abs(x - y) >= 1e-9
        default:              return false
        }
    }

    /// Blank, 0, FALSE, "-" and similar count as "no value".
    static func hasValue(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        switch s.lowercased() {
        case "0", "-", "—", "false", "no", "n/a", "na", "#n/a", "0.0": return false
        default: return true
        }
    }
}

// MARK: - Cell coloring

/// Pre-compiled cell color rules: column index -> ordered (test, color) pairs.
final class CellPainter {
    private var rules: [Int: [(RowPredicate, NSColor)]] = [:]
    private var onlyNew: [Int: [Bool]] = [:]
    /// The same stock's row on the previous stored day (for "only when it just became true").
    var previous: ((SheetRow) -> SheetRow?)?

    init() {}

    init(_ cellRules: [CellRule], table: SheetTable, previous: ((SheetRow) -> SheetRow?)? = nil) {
        self.previous = previous
        var ignored: [String] = []
        for rule in cellRules where rule.condition.isEnabled {
            guard let col = table.index(of: rule.condition.column), let color = rule.shade.nsColor else {
                // A "Neutral" rule still stops later rules for that column.
                if let col = table.index(of: rule.condition.column), rule.shade == .none {
                    let c = rule.condition
                    if let p = FilterCompiler.compile(FilterCondition(column: c.column, op: c.op, value: c.value, value2: c.value2),
                                                      table: table, issues: &ignored) {
                        rules[col, default: []].append((p, .clear))
                        onlyNew[col, default: []].append(false)
                    }
                }
                continue
            }
            let c = rule.condition
            if let p = FilterCompiler.compile(FilterCondition(column: c.column, op: c.op, value: c.value, value2: c.value2),
                                              table: table, issues: &ignored) {
                rules[col, default: []].append((p, color))
                onlyNew[col, default: []].append(rule.onlyNew ?? false)
            }
        }
    }

    var isEmpty: Bool { rules.isEmpty }

    func color(for row: SheetRow, column: Int) -> NSColor? {
        guard let list = rules[column] else { return nil }
        let fresh = onlyNew[column] ?? []
        for (k, (test, color)) in list.enumerated() where test(row) {
            if k < fresh.count, fresh[k] {
                // ✓ only when it just became true: skip if it was already true the previous day
                guard let previous, let old = previous(row) else { continue }
                if test(old) { continue }
            }
            return color == .clear ? nil : color
        }
        return nil
    }
}

// MARK: - Sorting

enum SortKey: Comparable {
    case number(Double)
    case date(Date)
    case text(String)
    case empty

    static func make(_ row: SheetRow, column: Int) -> SortKey {
        if let n = row.number(column) { return .number(n) }
        let s = row.text(column).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return .empty }
        if let d = DateParser.parse(s) { return .date(d) }
        return .text(s.lowercased())
    }

    private var rank: Int {
        switch self { case .number: return 0; case .date: return 1; case .text: return 2; case .empty: return 3 }
    }

    static func < (a: SortKey, b: SortKey) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return x < y
        case let (.date(x), .date(y)):     return x < y
        case let (.text(x), .text(y)):     return x.localizedStandardCompare(y) == .orderedAscending
        default:                           return a.rank < b.rank
        }
    }
}

enum Sorter {
    /// Sorts by one column. Blank cells always go last; ties keep sheet order.
    static func sort(_ rows: [SheetRow], column: Int, descending: Bool) -> [SheetRow] {
        let keyed = rows.map { (SortKey.make($0, column: column), $0) }
        return keyed.sorted { a, b in
            if case .empty = a.0, case .empty = b.0 { return a.1.id < b.1.id }
            if case .empty = a.0 { return false }
            if case .empty = b.0 { return true }
            if a.0 == b.0 { return a.1.id < b.1.id }
            return descending ? b.0 < a.0 : a.0 < b.0
        }.map(\.1)
    }
}

// MARK: - Formula language
//
//   CLOSE > EMA_20 * 1.02 AND (RSI_14 >= 60 OR [Vol Ratio] > 2)
//
// Columns: plain names (letters, digits, _) or [Any Name] in brackets; case doesn't matter.
// Operators: + - * /  > >= < <= = != <>  AND OR NOT (also && || !)  and parentheses.
// Text in 'quotes'. Functions: abs, round, min, max, pct(a, b), empty(x), contains(x, 'text'), startswith(x, 'text').

enum FormulaValue {
    case number(Double)
    case text(String)
    case bool(Bool)
    case null

    var number: Double? {
        switch self {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var truthy: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .text(let s): return !s.isEmpty
        case .null: return false
        }
    }

    var textValue: String {
        switch self {
        case .text(let s): return s
        case .number(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        }
    }
}

struct FormulaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CompiledFormula {
    let predicate: RowPredicate
    let columns: [Int]
}

enum Formula {
    typealias Eval = (SheetRow) -> FormulaValue

    private enum Token: Equatable {
        case number(Double), text(String), ident(String), column(String)
        case op(String), lparen, rparen, comma, end
    }

    static func compile(_ source: String, table: SheetTable) throws -> CompiledFormula {
        var parser = Parser(tokens: try tokenize(source), table: table)
        let eval = try parser.parseExpression()
        guard parser.peek == .end else { throw FormulaError(message: "Unexpected \(describe(parser.peek))") }
        return CompiledFormula(predicate: { eval($0).truthy }, columns: parser.columns)
    }

    private static func describe(_ t: Token) -> String {
        switch t {
        case .number(let d): return "number \(d)"
        case .text(let s): return "'\(s)'"
        case .ident(let s): return "\"\(s)\""
        case .column(let s): return "[\(s)]"
        case .op(let s): return "\"\(s)\""
        case .lparen: return "\"(\""
        case .rparen: return "\")\""
        case .comma: return "\",\""
        case .end: return "end of formula"
        }
    }

    // MARK: Tokenizer

    private static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                // Something like 20D would be a column name, not a number.
                if j < chars.count, chars[j].isLetter || chars[j] == "_" {
                    while j < chars.count, isIdentChar(chars[j]) { j += 1 }
                    tokens.append(.ident(String(chars[i..<j])))
                } else {
                    guard let d = Double(String(chars[i..<j])) else {
                        throw FormulaError(message: "Bad number \(String(chars[i..<j]))")
                    }
                    tokens.append(.number(d))
                }
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, isIdentChar(chars[j]) { j += 1 }
                tokens.append(.ident(String(chars[i..<j])))
                i = j
                continue
            }
            if c == "[" {
                guard let close = chars[(i + 1)...].firstIndex(of: "]") else {
                    throw FormulaError(message: "Missing ] after [")
                }
                tokens.append(.column(String(chars[(i + 1)..<close])))
                i = close + 1
                continue
            }
            if c == "'" || c == "\"" || c == "‘" || c == "“" {
                let closing: Character = c == "‘" ? "’" : (c == "“" ? "”" : c)
                guard let close = chars[(i + 1)...].firstIndex(of: closing) else {
                    throw FormulaError(message: "Missing closing quote")
                }
                tokens.append(.text(String(chars[(i + 1)..<close])))
                i = close + 1
                continue
            }
            switch c {
            case "(": tokens.append(.lparen); i += 1; continue
            case ")": tokens.append(.rparen); i += 1; continue
            case ",": tokens.append(.comma); i += 1; continue
            default: break
            }
            let two = i + 1 < chars.count ? String(chars[i...(i + 1)]) : ""
            if [">=", "<=", "!=", "<>", "==", "&&", "||"].contains(two) {
                tokens.append(.op(two)); i += 2; continue
            }
            if "+-*/><=!≥≤≠".contains(c) {
                let mapped: String
                switch c {
                case "≥": mapped = ">="
                case "≤": mapped = "<="
                case "≠": mapped = "!="
                default: mapped = String(c)
                }
                tokens.append(.op(mapped)); i += 1; continue
            }
            throw FormulaError(message: "Unexpected character \"\(c)\"")
        }
        tokens.append(.end)
        return tokens
    }

    // MARK: Parser → closures

    private struct Parser {
        let tokens: [Token]
        let table: SheetTable
        var pos = 0
        var columns: [Int] = []

        init(tokens: [Token], table: SheetTable) {
            self.tokens = tokens
            self.table = table
        }

        var peek: Token { tokens[pos] }

        mutating func next() -> Token {
            let t = tokens[pos]
            if pos < tokens.count - 1 { pos += 1 }
            return t
        }

        func isKeyword(_ t: Token, _ word: String) -> Bool {
            if case .ident(let s) = t, s.uppercased() == word { return true }
            return false
        }

        mutating func parseExpression() throws -> Eval { try parseOr() }

        mutating func parseOr() throws -> Eval {
            var left = try parseAnd()
            while isKeyword(peek, "OR") || peek == .op("||") {
                _ = next()
                let l = left, r = try parseAnd()
                left = { row in .bool(l(row).truthy || r(row).truthy) }
            }
            return left
        }

        mutating func parseAnd() throws -> Eval {
            var left = try parseNot()
            while isKeyword(peek, "AND") || peek == .op("&&") {
                _ = next()
                let l = left, r = try parseNot()
                left = { row in .bool(l(row).truthy && r(row).truthy) }
            }
            return left
        }

        mutating func parseNot() throws -> Eval {
            if isKeyword(peek, "NOT") || peek == .op("!") {
                _ = next()
                let inner = try parseNot()
                return { row in .bool(!inner(row).truthy) }
            }
            return try parseComparison()
        }

        mutating func parseComparison() throws -> Eval {
            let left = try parseAdditive()
            guard case .op(let o) = peek, [">", ">=", "<", "<=", "=", "==", "!=", "<>"].contains(o) else {
                return left
            }
            _ = next()
            let right = try parseAdditive()
            return { row in .bool(Formula.compareValues(left(row), o, right(row))) }
        }

        mutating func parseAdditive() throws -> Eval {
            var left = try parseMultiplicative()
            while case .op(let o) = peek, o == "+" || o == "-" {
                _ = next()
                let l = left, r = try parseMultiplicative()
                left = { row in
                    guard let a = l(row).number, let b = r(row).number else { return .null }
                    return .number(o == "+" ? a + b : a - b)
                }
            }
            return left
        }

        mutating func parseMultiplicative() throws -> Eval {
            var left = try parseUnary()
            while case .op(let o) = peek, o == "*" || o == "/" {
                _ = next()
                let l = left, r = try parseUnary()
                left = { row in
                    guard let a = l(row).number, let b = r(row).number else { return .null }
                    if o == "/" { return b == 0 ? .null : .number(a / b) }
                    return .number(a * b)
                }
            }
            return left
        }

        mutating func parseUnary() throws -> Eval {
            if peek == .op("-") {
                _ = next()
                let inner = try parseUnary()
                return { row in inner(row).number.map { .number(-$0) } ?? .null }
            }
            if peek == .op("+") { _ = next() }
            return try parsePrimary()
        }

        mutating func columnEval(_ name: String) throws -> Eval {
            guard let i = table.index(of: name) else {
                throw FormulaError(message: "Unknown column \"\(name)\"")
            }
            if !columns.contains(i) { columns.append(i) }
            return { row in
                if let n = row.number(i) { return .number(n) }
                let s = row.text(i)
                return s.trimmingCharacters(in: .whitespaces).isEmpty ? .null : .text(s)
            }
        }

        mutating func parsePrimary() throws -> Eval {
            let t = next()
            switch t {
            case .number(let d):
                return { _ in .number(d) }
            case .text(let s):
                return { _ in .text(s) }
            case .column(let name):
                return try columnEval(name)
            case .lparen:
                let inner = try parseExpression()
                guard next() == .rparen else { throw FormulaError(message: "Missing )") }
                return inner
            case .ident(let name):
                let upper = name.uppercased()
                if upper == "TRUE" { return { _ in .bool(true) } }
                if upper == "FALSE" { return { _ in .bool(false) } }
                if peek == .lparen, table.index(of: name) == nil || Formula.functions.contains(upper) {
                    _ = next()
                    var args: [Eval] = []
                    if peek != .rparen {
                        args.append(try parseExpression())
                        while peek == .comma {
                            _ = next()
                            args.append(try parseExpression())
                        }
                    }
                    guard next() == .rparen else { throw FormulaError(message: "Missing ) after \(name)(") }
                    return try Formula.function(upper, args)
                }
                return try columnEval(name)
            default:
                throw FormulaError(message: "Unexpected \(Formula.describe(t))")
            }
        }
    }

    static let functions: Set<String> = ["ABS", "ROUND", "MIN", "MAX", "PCT", "EMPTY", "CONTAINS", "STARTSWITH"]

    fileprivate static func function(_ name: String, _ args: [Eval]) throws -> Eval {
        func need(_ n: Int) throws {
            guard args.count == n else { throw FormulaError(message: "\(name.lowercased())() needs \(n) value\(n == 1 ? "" : "s")") }
        }
        switch name {
        case "ABS":
            try need(1); let a = args[0]
            return { row in a(row).number.map { .number(Swift.abs($0)) } ?? .null }
        case "ROUND":
            guard args.count == 1 || args.count == 2 else { throw FormulaError(message: "round() needs 1 or 2 values") }
            let a = args[0], digits = args.count == 2 ? args[1] : nil
            return { row in
                guard let x = a(row).number else { return .null }
                let p = pow(10, digits?(row).number ?? 0)
                return .number((x * p).rounded() / p)
            }
        case "MIN", "MAX":
            guard !args.isEmpty else { throw FormulaError(message: "\(name.lowercased())() needs at least 1 value") }
            let isMin = name == "MIN"
            return { row in
                let nums = args.compactMap { $0(row).number }
                guard let v = isMin ? nums.min() : nums.max() else { return .null }
                return .number(v)
            }
        case "PCT":   // percent change from b to a: (a - b) / b * 100
            try need(2); let a = args[0], b = args[1]
            return { row in
                guard let x = a(row).number, let y = b(row).number, y != 0 else { return .null }
                return .number((x - y) / y * 100)
            }
        case "EMPTY":
            try need(1); let a = args[0]
            return { row in
                if case .null = a(row) { return .bool(true) }
                return .bool(!FilterCompiler.hasValue(a(row).textValue))
            }
        case "CONTAINS", "STARTSWITH":
            try need(2); let a = args[0], b = args[1]
            let anchored = name == "STARTSWITH"
            return { row in
                let hay = a(row).textValue, needle = b(row).textValue
                guard !needle.isEmpty else { return .bool(false) }
                let opts: String.CompareOptions = anchored ? [.caseInsensitive, .anchored] : .caseInsensitive
                return .bool(hay.range(of: needle, options: opts) != nil)
            }
        default:
            throw FormulaError(message: "Unknown function \(name.lowercased())()")
        }
    }

    fileprivate static func compareValues(_ a: FormulaValue, _ op: String, _ b: FormulaValue) -> Bool {
        if case .null = a { return op == "!=" || op == "<>" ? !isNull(b) : false }
        if case .null = b { return op == "!=" || op == "<>" }
        if let x = a.number, let y = b.number {
            switch op {
            case ">": return x > y
            case ">=": return x >= y
            case "<": return x < y
            case "<=": return x <= y
            case "=", "==": return abs(x - y) < 1e-9
            default: return abs(x - y) >= 1e-9
            }
        }
        let order = a.textValue.trimmingCharacters(in: .whitespaces)
            .localizedCaseInsensitiveCompare(b.textValue.trimmingCharacters(in: .whitespaces))
        switch op {
        case ">": return order == .orderedDescending
        case ">=": return order != .orderedAscending
        case "<": return order == .orderedAscending
        case "<=": return order != .orderedDescending
        case "=", "==": return order == .orderedSame
        default: return order != .orderedSame
        }
    }

    private static func isNull(_ v: FormulaValue) -> Bool {
        if case .null = v { return true }
        return false
    }
}

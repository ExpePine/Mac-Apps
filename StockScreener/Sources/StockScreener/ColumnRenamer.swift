import Foundation

/// When you rename columns, every saved reference (filters, formulas, colors, triggers, MV2, sort…)
/// is switched to the new name so nothing breaks.
enum ColumnRenamer {

    /// `pairs`: old name -> new name (matched ignoring case). Each reference is renamed at most once.
    static func rename(_ settings: AppSettings, pairs: [(old: String, new: String)]) -> AppSettings {
        guard !pairs.isEmpty else { return settings }
        var map: [String: String] = [:]
        for p in pairs where map[SheetTable.normalize(p.old)] == nil {
            map[SheetTable.normalize(p.old)] = p.new
        }
        func r(_ name: String) -> String { map[SheetTable.normalize(name)] ?? name }

        var s = settings
        s.triggerColumn = r(s.triggerColumn)
        s.labelColumn = r(s.labelColumn)
        s.filterSortColumn = r(s.filterSortColumn)
        s.filterColumns = s.filterColumns.map(r)
        s.nnFeatures = s.nnFeatures.map(r)
        s.changeCards = s.changeCards.map { var c = $0; c.column = r(c.column); return c }
        s.perfStudies = s.perfStudies.map { st in
            var c = st
            if c.source == .main { c.column = r(c.column) }
            if c.splitBy.hasPrefix("main:") { c.splitBy = "main:" + r(String(c.splitBy.dropFirst(5))) }
            return c
        }
        s.dateColumn = r(s.dateColumn)
        s.mv2.monthColumn = r(s.mv2.monthColumn)
        s.mv2.dayColumn = r(s.mv2.dayColumn)
        for i in s.cellRules.indices { s.cellRules[i].condition.column = r(s.cellRules[i].condition.column) }
        s.filterGroup = rename(s.filterGroup, map)
        for i in s.buyTriggers.indices { s.buyTriggers[i].filter = rename(s.buyTriggers[i].filter, map) }
        return s
    }

    private static func rename(_ group: FilterGroup, _ map: [String: String]) -> FilterGroup {
        var g = group
        for i in g.conditions.indices {
            let c = g.conditions[i]
            g.conditions[i].column = map[SheetTable.normalize(c.column)] ?? c.column
            g.conditions[i].otherColumn = map[SheetTable.normalize(c.otherColumn)] ?? c.otherColumn
            g.conditions[i].formula = renameInFormula(c.formula, map)
        }
        g.groups = g.groups.map { rename($0, map) }
        return g
    }

    private static let keywords: Set<String> = ["AND", "OR", "NOT", "TRUE", "FALSE"]

    /// How a column name should be written in a formula: bare if it's a simple word, otherwise [in brackets].
    static func formulaName(_ name: String) -> String {
        let simple = name.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil
        return simple && !keywords.contains(name.uppercased()) ? name : "[\(name)]"
    }

    /// Replaces column names inside a formula, leaving 'text', numbers, functions and keywords alone.
    static func renameInFormula(_ formula: String, _ map: [String: String]) -> String {
        guard !formula.isEmpty else { return formula }
        let chars = Array(formula)
        var out = ""
        var i = 0
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }

        while i < chars.count {
            let c = chars[i]
            // Quoted text: copy as-is.
            if c == "'" || c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += 1 }
                out += String(chars[i..<min(j + 1, chars.count)])
                i = j + 1
                continue
            }
            // [Bracketed name]
            if c == "[" {
                guard let close = chars[(i + 1)...].firstIndex(of: "]") else {
                    out += String(chars[i...]); break
                }
                let name = String(chars[(i + 1)..<close])
                if let new = map[SheetTable.normalize(name)] {
                    out += formulaName(new)
                } else {
                    out += String(chars[i...close])
                }
                i = close + 1
                continue
            }
            // Bare word
            if c.isLetter || c == "_" || c.isNumber {
                var j = i
                while j < chars.count, isIdent(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                // Function call? (next non-space char is "(")
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let isCall = k < chars.count && chars[k] == "(" && Formula.functions.contains(word.uppercased())
                if !isCall, !keywords.contains(word.uppercased()), let new = map[SheetTable.normalize(word)] {
                    out += formulaName(new)
                } else {
                    out += word
                }
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

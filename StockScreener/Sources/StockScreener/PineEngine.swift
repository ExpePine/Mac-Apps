import Foundation

// A small Pine Script interpreter: runs your indicators bar by bar on a stock's daily data, the way TradingView does.
// It covers the common part of Pine v4/v5 (variables, var, :=, if / else, for, functions, ternaries, history [n],
// the usual ta.* / math.* functions, input.*, plot / plotshape / plotchar / hline / alertcondition). What it can't run
// is listed as "issues" — Groq can rewrite those parts into what it can run.

// MARK: - Syntax tree

indirect enum PExpr {
    case num(Double)
    case str(String)
    case ident(String)
    case hist(PExpr, PExpr, Int)                 // x[n] (site id: history of an expression)
    case unary(String, PExpr)
    case bin(String, PExpr, PExpr)
    case tern(PExpr, PExpr, PExpr)
    case call(String, [PExpr], [String: PExpr], Int)
    case list([PExpr])
}

indirect enum PStmt {
    case decl(String, PExpr, Bool)               // name, value, `var`
    case assign(String, String, PExpr)           // name, := / += / -= / *= / /=, value
    case tupleDecl([String], PExpr)
    case expr(PExpr)
    case ifs(PExpr, [PStmt], [PStmt])
    case loop(String, PExpr, PExpr, PExpr?, [PStmt])
    case fn(String, [String], [PStmt])
}

enum PVal {
    case n(Double)
    case s(String)
    case t([PVal])
    var num: Double { if case .n(let d) = self { return d }; return .nan }
    var str: String? { if case .s(let s) = self { return s }; return nil }
    var truthy: Bool { let d = num; return !d.isNaN && d != 0 }
}

struct PineProgram {
    var title = ""
    var stmts: [PStmt] = []
    var functions: [String: ([String], [PStmt])] = [:]
    var issues: [String] = []                    // what can't run (with line numbers)
    var sheetColumns: [String] = []              // sheet("COL") used
    var sites = 0
}

// MARK: - Lexer + parser

enum PineParser {
    enum Tok: Equatable { case num(Double), str(String), id(String), op(String) }
    struct Line { let no: Int; let indent: Int; var toks: [Tok] }

    static let unsupportedPrefixes = ["request.", "array.", "matrix.", "map.", "label.", "line.", "box.", "table.", "linefill.",
                                      "strategy.", "polyline.", "chart.point", "ticker.", "timeframe.change", "str.split", "log."]
    static let ignoredCalls: Set<String> = ["indicator", "study", "strategy", "fill", "bgcolor", "barcolor", "plotcandle", "plotbar",
                                            "plotarrow", "library", "export", "max_bars_back", "runtime.error"]

    static func parse(_ source: String) -> PineProgram {
        var prog = PineProgram()
        var lines = logicalLines(source, issues: &prog.issues)
        var site = 0
        var i = 0
        let top = block(&lines, &i, indent: 0, prog: &prog, site: &site)
        prog.stmts = top
        prog.sites = site
        // calls nobody can run
        var seen = Set<String>()
        func walkE(_ e: PExpr) {
            switch e {
            case .call(let n, let a, let named, _):
                if prog.functions[n] == nil && !PineRun.knows(n) && !ignoredCalls.contains(n) && !seen.contains(n) {
                    seen.insert(n); prog.issues.append("\(n)() isn't supported")
                }
                if n == "sheet", let f = a.first, case .str(let c) = f { prog.sheetColumns.append(c) }
                a.forEach(walkE); named.values.forEach(walkE)
            case .hist(let a, let b, _): walkE(a); walkE(b)
            case .unary(_, let a): walkE(a)
            case .bin(_, let a, let b): walkE(a); walkE(b)
            case .tern(let a, let b, let c): walkE(a); walkE(b); walkE(c)
            case .list(let xs): xs.forEach(walkE)
            case .ident(let n):
                if unsupportedPrefixes.contains(where: { n.hasPrefix($0) }) && !seen.contains(n) { seen.insert(n); prog.issues.append("\(n) isn't supported") }
            default: break
            }
        }
        func walkS(_ s: PStmt) {
            switch s {
            case .decl(_, let e, _), .assign(_, _, let e), .tupleDecl(_, let e), .expr(let e): walkE(e)
            case .ifs(let c, let a, let b): walkE(c); a.forEach(walkS); b.forEach(walkS)
            case .loop(_, let a, let b, let c, let body): walkE(a); walkE(b); if let c { walkE(c) }; body.forEach(walkS)
            case .fn(_, _, let body): body.forEach(walkS)
            }
        }
        prog.stmts.forEach(walkS)
        prog.functions.values.forEach { $0.1.forEach(walkS) }
        return prog
    }

    // MARK: lines

    private static func logicalLines(_ src: String, issues: inout [String]) -> [Line] {
        let raw = src.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var out: [Line] = []
        var k = 0
        while k < raw.count {
            let text = stripComment(raw[k])
            if text.trimmingCharacters(in: .whitespaces).isEmpty { k += 1; continue }
            let indent = text.prefix(while: { $0 == " " }).count
            var toks = tokenize(text, line: k + 1, issues: &issues)
            let no = k + 1
            k += 1
            // continuation lines: open brackets, a trailing operator, or a next line indented by a non-multiple of 4
            while k < raw.count {
                let depth = toks.reduce(0) { (d: Int, t: Tok) -> Int in
                    if case .op(let o) = t { if o == "(" || o == "[" { return d + 1 }; if o == ")" || o == "]" { return d - 1 } }
                    return d
                }
                let nextText = stripComment(raw[k])
                if nextText.trimmingCharacters(in: .whitespaces).isEmpty { if depth > 0 { k += 1; continue } else { break } }
                let ni = nextText.prefix(while: { $0 == " " }).count
                var trailing = false
                if let l = toks.last {
                    if case .op(let o) = l { trailing = [",", "+", "-", "*", "/", "?", ":", "==", "!=", "<", ">", "<=", ">=", "=", ":="].contains(o) }
                    if case .id(let w) = l { trailing = w == "and" || w == "or" }
                }
                if depth > 0 || trailing || (ni > indent && ni % 4 != 0) {
                    toks += tokenize(nextText, line: k + 1, issues: &issues); k += 1
                } else { break }
            }
            out.append(Line(no: no, indent: indent / 4, toks: toks))
        }
        return out
    }

    private static func stripComment(_ s: String) -> String {
        var inStr: Character? = nil
        var prev: Character = " "
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if let q = inStr { if c == q { inStr = nil } }
            else if c == "\"" || c == "'" { inStr = c }
            else if c == "/" && prev == "/" { return String(s[..<s.index(before: idx)]) }
            prev = c
            idx = s.index(after: idx)
        }
        return s
    }

    private static func tokenize(_ s: String, line: Int, issues: inout [String]) -> [Tok] {
        var t: [Tok] = []
        let ch = Array(s)
        var i = 0
        let two: Set<String> = [":=", "==", "!=", "<=", ">=", "=>", "+=", "-=", "*=", "/="]
        while i < ch.count {
            let c = ch[i]
            if c == " " { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < ch.count && ch[i + 1].isNumber) {
                var j = i
                while j < ch.count && (ch[j].isNumber || ch[j] == "." || ch[j] == "e" || ch[j] == "E" || ((ch[j] == "-" || ch[j] == "+") && j > i && (ch[j - 1] == "e" || ch[j - 1] == "E"))) { j += 1 }
                t.append(.num(Double(String(ch[i..<j])) ?? .nan)); i = j; continue
            }
            if c == "\"" || c == "'" {
                var j = i + 1
                while j < ch.count && ch[j] != c { j += 1 }
                t.append(.str(String(ch[(i + 1)..<min(j, ch.count)]))); i = j + 1; continue
            }
            if c == "#" {
                var j = i + 1
                while j < ch.count && ch[j].isHexDigit { j += 1 }
                t.append(.str(String(ch[i..<j]))); i = j; continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < ch.count && (ch[j].isLetter || ch[j].isNumber || ch[j] == "_" || ch[j] == ".") { j += 1 }
                t.append(.id(String(ch[i..<j]))); i = j; continue
            }
            if i + 1 < ch.count, two.contains(String([c, ch[i + 1]])) { t.append(.op(String([c, ch[i + 1]]))); i += 2; continue }
            if "+-*/%<>=?:()[],".contains(c) { t.append(.op(String(c))); i += 1; continue }
            issues.append("line \(line): unexpected '\(c)'"); i += 1
        }
        return t
    }

    // MARK: statements

    private static let typeWords: Set<String> = ["float", "int", "bool", "string", "color", "series", "simple", "const", "label", "line"]

    private static func block(_ lines: inout [Line], _ i: inout Int, indent: Int, prog: inout PineProgram, site: inout Int) -> [PStmt] {
        var out: [PStmt] = []
        while i < lines.count && lines[i].indent >= indent {
            if lines[i].indent > indent { prog.issues.append("line \(lines[i].no): unexpected indent"); i += 1; continue }
            if let s = statement(&lines, &i, indent: indent, prog: &prog, site: &site) { out.append(s) }
        }
        return out
    }

    private static func statement(_ lines: inout [Line], _ i: inout Int, indent: Int, prog: inout PineProgram, site: inout Int) -> PStmt? {
        let line = lines[i]
        var toks = line.toks
        i += 1
        guard let first = toks.first else { return nil }
        if case .id(let w) = first {
            switch w {
            case "if":
                var p = P(toks: Array(toks.dropFirst()), site: site)
                let cond = p.expr(); site = p.site
                let body = block(&lines, &i, indent: indent + 1, prog: &prog, site: &site)
                var other: [PStmt] = []
                if i < lines.count, lines[i].indent == indent, case .id("else")? = lines[i].toks.first {
                    let rest = Array(lines[i].toks.dropFirst())
                    if case .id("if")? = rest.first {
                        lines[i].toks = rest                       // "else if …" = an if inside the else
                        if let s = statement(&lines, &i, indent: indent, prog: &prog, site: &site) { other = [s] }
                    } else {
                        i += 1
                        other = block(&lines, &i, indent: indent + 1, prog: &prog, site: &site)
                    }
                }
                return .ifs(cond, body, other)
            case "for":
                // for i = a to b [by s]
                guard toks.count > 3, case .id(let v) = toks[1] else { prog.issues.append("line \(line.no): for … isn't understood"); return nil }
                if case .id("in")? = toks.dropFirst(2).first { prog.issues.append("line \(line.no): for … in isn't supported"); _ = block(&lines, &i, indent: indent + 1, prog: &prog, site: &site); return nil }
                var p = P(toks: Array(toks.dropFirst(3)), site: site)
                let a = p.expr()
                guard p.eatId("to") else { prog.issues.append("line \(line.no): for needs 'to'"); return nil }
                let b = p.expr()
                var by: PExpr? = nil
                if p.eatId("by") { by = p.expr() }
                site = p.site
                let body = block(&lines, &i, indent: indent + 1, prog: &prog, site: &site)
                return .loop(v, a, b, by, body)
            case "while", "switch", "import", "method", "type", "export", "enum":
                prog.issues.append("line \(line.no): '\(w)' isn't supported")
                _ = block(&lines, &i, indent: indent + 1, prog: &prog, site: &site)
                return nil
            case "var", "varip":
                toks.removeFirst()
                while toks.count > 2, case .id(let tw) = toks[0], typeWords.contains(tw), case .id = toks[1] { toks.removeFirst() }
                guard toks.count > 2, case .id(let name) = toks[0], toks[1] == .op("=") else { prog.issues.append("line \(line.no): var … isn't understood"); return nil }
                var p = P(toks: Array(toks.dropFirst(2)), site: site)
                let e = p.expr(); site = p.site
                return .decl(name, e, true)
            default: break
            }
            // type words before a declaration: float x = …
            while toks.count > 2, case .id(let tw) = toks[0], typeWords.contains(tw), case .id = toks[1], toks[2] == .op("=") { toks.removeFirst() }
            // function: f(a, b) => …
            if toks.count > 2, case .id(let name) = toks[0], toks[1] == .op("("), let close = matching(toks, 1), close + 1 < toks.count, toks[close + 1] == .op("=>") {
                var params: [String] = []
                var seg: [Tok] = []
                func flush() {
                    let head = seg.firstIndex(of: .op("=")).map { Array(seg[..<$0]) } ?? seg
                    if case .id(let pn)? = head.last { params.append(pn) }
                    seg = []
                }
                var depth = 0
                for t in toks[2..<close] {
                    if case .op(let o) = t {
                        if o == "(" || o == "[" { depth += 1 }
                        if o == ")" || o == "]" { depth -= 1 }
                        if o == "," && depth == 0 { flush(); continue }
                    }
                    seg.append(t)
                }
                if !seg.isEmpty { flush() }
                let rest = Array(toks[(close + 2)...])
                var body: [PStmt]
                if rest.isEmpty {
                    body = block(&lines, &i, indent: indent + 1, prog: &prog, site: &site)
                } else {
                    var p = P(toks: rest, site: site)
                    body = [.expr(p.expr())]; site = p.site
                }
                prog.functions[name] = (params, body)
                return .fn(name, params, body)
            }
            // assignment / declaration
            if toks.count > 2, case .id(let name) = toks[0], case .op(let o) = toks[1] {
                if [":=", "+=", "-=", "*=", "/="].contains(o) {
                    var p = P(toks: Array(toks.dropFirst(2)), site: site)
                    let e = p.expr(); site = p.site
                    return .assign(name, o, e)
                }
                if o == "=" {
                    if case .id(let w2) = toks[2], w2 == "if" || w2 == "switch" {
                        prog.issues.append("line \(line.no): '\(name) = \(w2) …' (if / switch as a value) isn't supported")
                        _ = block(&lines, &i, indent: indent + 1, prog: &prog, site: &site)
                        return nil
                    }
                    var p = P(toks: Array(toks.dropFirst(2)), site: site)
                    let e = p.expr(); site = p.site
                    if !p.atEnd { prog.issues.append("line \(line.no): couldn't read the whole line") }
                    return .decl(name, e, false)
                }
            }
        }
        // [a, b] = f(…)
        if first == .op("["), let close = matching(toks, 0), close + 1 < toks.count, toks[close + 1] == .op("=") {
            let names: [String] = toks[1..<close].compactMap { if case .id(let n) = $0 { return n }; return nil }
            var p = P(toks: Array(toks[(close + 2)...]), site: site)
            let e = p.expr(); site = p.site
            return .tupleDecl(names, e)
        }
        var p = P(toks: toks, site: site)
        let e = p.expr(); site = p.site
        if !p.atEnd { prog.issues.append("line \(line.no): couldn't read the whole line") }
        return .expr(e)
    }

    private static func matching(_ t: [Tok], _ open: Int) -> Int? {
        var d = 0
        for k in open..<t.count {
            if case .op(let o) = t[k] {
                if o == "(" || o == "[" { d += 1 }
                if o == ")" || o == "]" { d -= 1; if d == 0 { return k } }
            }
        }
        return nil
    }

    // MARK: expressions (precedence climbing)

    struct P {
        var toks: [Tok]
        var k = 0
        var site: Int
        init(toks: [Tok], site: Int) { self.toks = toks; self.site = site }
        var atEnd: Bool { k >= toks.count }
        func peek() -> Tok? { k < toks.count ? toks[k] : nil }
        mutating func eatOp(_ o: String) -> Bool { if peek() == .op(o) { k += 1; return true }; return false }
        mutating func eatId(_ w: String) -> Bool { if peek() == .id(w) { k += 1; return true }; return false }
        mutating func nextSite() -> Int { site += 1; return site }

        mutating func expr() -> PExpr {
            let c = or()
            if eatOp("?") {
                let a = expr()
                _ = eatOp(":")
                let b = expr()
                return .tern(c, a, b)
            }
            return c
        }
        mutating func or() -> PExpr { var l = and(); while eatId("or") { l = .bin("or", l, and()) }; return l }
        mutating func and() -> PExpr { var l = eq(); while eatId("and") { l = .bin("and", l, eq()) }; return l }
        mutating func eq() -> PExpr {
            var l = cmp()
            while true { if eatOp("==") { l = .bin("==", l, cmp()) } else if eatOp("!=") { l = .bin("!=", l, cmp()) } else { return l } }
        }
        mutating func cmp() -> PExpr {
            var l = add()
            while true {
                if eatOp("<=") { l = .bin("<=", l, add()) } else if eatOp(">=") { l = .bin(">=", l, add()) }
                else if eatOp("<") { l = .bin("<", l, add()) } else if eatOp(">") { l = .bin(">", l, add()) } else { return l }
            }
        }
        mutating func add() -> PExpr {
            var l = mul()
            while true { if eatOp("+") { l = .bin("+", l, mul()) } else if eatOp("-") { l = .bin("-", l, mul()) } else { return l } }
        }
        mutating func mul() -> PExpr {
            var l = unary()
            while true {
                if eatOp("*") { l = .bin("*", l, unary()) } else if eatOp("/") { l = .bin("/", l, unary()) }
                else if eatOp("%") { l = .bin("%", l, unary()) } else { return l }
            }
        }
        mutating func unary() -> PExpr {
            if eatOp("-") { return .unary("-", unary()) }
            if eatOp("+") { return unary() }
            if eatId("not") { return .unary("not", unary()) }
            return postfix()
        }
        mutating func postfix() -> PExpr {
            var e = primary()
            while true {
                if eatOp("[") {
                    let n = expr(); _ = eatOp("]")
                    e = .hist(e, n, nextSite())
                } else { return e }
            }
        }
        mutating func primary() -> PExpr {
            guard let t = peek() else { return .num(.nan) }
            k += 1
            switch t {
            case .num(let d): return .num(d)
            case .str(let s): return .str(s)
            case .op("("):
                let e = expr(); _ = eatOp(")"); return e
            case .op("["):
                var xs: [PExpr] = []
                while !atEnd && peek() != .op("]") { xs.append(expr()); _ = eatOp(",") }
                _ = eatOp("]")
                return .list(xs)
            case .id(let n):
                if n == "true" { return .num(1) }
                if n == "false" { return .num(0) }
                if n == "na" && peek() != .op("(") { return .num(.nan) }
                if eatOp("(") {
                    var args: [PExpr] = [], named: [String: PExpr] = [:]
                    while !atEnd && peek() != .op(")") {
                        if case .id(let an)? = peek(), k + 1 < toks.count, toks[k + 1] == .op("=") {
                            k += 2; named[an] = expr()
                        } else { args.append(expr()) }
                        if !eatOp(",") { break }
                    }
                    _ = eatOp(")")
                    return .call(n, args, named, nextSite())
                }
                return .ident(n)
            default: return .num(.nan)
            }
        }
    }
}

// MARK: - Running a program on one stock

struct PineInput {
    var symbol = ""
    var days: [String] = []
    var series: [String: [Double]] = [:]          // open high low close volume deliv_qty … (NaN = missing)
    var sheet: [String: [Double]] = [:]           // sheet("COL") per day (NaN where no stored sheet)
}

struct PinePlot {
    var site = 0
    var title = ""
    var kind = "line"                             // line · hist · step · shape · hline · alert
    var color = "#2962FF"
    var width = 1.0
    var values: [Double] = []
    var colors: [String?] = []
    var text = ""
    var location = "abovebar"
    var shape = "circle"
}

struct PineResult {
    var plots: [PinePlot] = []
    var errors: [String] = []
}

final class PineRun {
    let prog: PineProgram
    let input: PineInput
    let n: Int
    private var vars: [String: [Double]] = [:]
    private var svars: [String: PVal] = [:]
    private var isVar = Set<String>()
    private var varDone = Set<String>()
    private var bar = 0
    private var frames: [[String: PVal]] = []
    private var ctx = 0
    private var ta: [Int: TA] = [:]
    private final class PlotBox { var p = PinePlot() }
    private var plots: [Int: PlotBox] = [:]
    private var plotOrder: [Int] = []
    private var errors: [String] = []

    final class TA { var a: [Double] = []; var b: [Double] = []; var c: [Double] = []; var prev = Double.nan; var cum = 0.0; var count = 0 }

    init(_ prog: PineProgram, _ input: PineInput) {
        self.prog = prog; self.input = input; self.n = input.days.count
    }

    static let builtinSeries: Set<String> = ["open", "high", "low", "close", "volume", "hl2", "hlc3", "ohlc4", "hlcc4",
                                             "deliv_qty", "deliv_pct", "deliv_value", "nse_close", "delsmac", "dealsize", "dealbuy", "dealsell"]

    static let functions: Set<String> = [
        "ta.sma", "ta.ema", "ta.rma", "ta.wma", "ta.vwma", "ta.stdev", "ta.variance", "ta.dev", "ta.highest", "ta.lowest",
        "ta.highestbars", "ta.lowestbars", "ta.change", "ta.mom", "ta.roc", "ta.rsi", "ta.crossover", "ta.crossunder",
        "ta.cross", "ta.percentrank", "ta.barssince", "ta.valuewhen", "ta.cum", "ta.tr", "ta.atr", "ta.macd", "ta.bb",
        "ta.rising", "ta.falling", "ta.median", "ta.linreg", "ta.cci", "ta.mfi", "ta.obv", "ta.swma", "ta.hma",
        "math.abs", "math.max", "math.min", "math.round", "math.floor", "math.ceil", "math.sqrt", "math.log", "math.log10",
        "math.exp", "math.pow", "math.sign", "math.avg", "math.sum", "math.round_to_mintick",
        "nz", "na", "fixnan", "int", "float", "bool", "str.tostring", "str.format", "str.contains", "color.new", "color.rgb",
        "input", "input.int", "input.float", "input.bool", "input.source", "input.string", "input.color", "input.timeframe",
        "input.session", "input.symbol", "input.price", "input.time", "input.text_area",
        "plot", "plotshape", "plotchar", "hline", "alertcondition", "alert", "sheet",
        "sma", "ema", "rma", "wma", "stdev", "highest", "lowest", "change", "mom", "roc", "rsi", "crossover", "crossunder",
        "cross", "percentrank", "barssince", "valuewhen", "cum", "atr", "abs", "max", "min", "round", "floor", "ceil",
        "sqrt", "log", "exp", "pow", "sign", "avg", "sum", "tostring", "color", "iff", "rising", "falling", "tr", "vwma",
        "dev", "variance", "macd", "bb", "linreg"]
    static func knows(_ f: String) -> Bool { functions.contains(f) }

    func run(maxBars: Int? = nil) -> PineResult {
        let start = maxBars.map { max(0, n - $0) } ?? 0
        func collect(_ ss: [PStmt]) {
            for s in ss {
                switch s {
                case .decl(let name, _, true): isVar.insert(name)
                case .ifs(_, let a, let b): collect(a); collect(b)
                case .loop(_, _, _, _, let body): collect(body)
                default: break
                }
            }
        }
        collect(prog.stmts)
        for b in start..<n {
            bar = b
            // `var` variables keep their value from the bar before
            if b > start { for v in isVar where vars[v] != nil { vars[v]![b] = vars[v]![b - 1] } }
            exec(prog.stmts)
            if errors.count > 5 { break }
        }
        var r = PineResult()
        r.plots = plotOrder.compactMap { plots[$0]?.p }
        r.errors = errors
        return r
    }

    // MARK: statements

    private func exec(_ stmts: [PStmt]) {
        for s in stmts { _ = execOne(s) }
    }

    @discardableResult
    private func execOne(_ s: PStmt) -> PVal {
        switch s {
        case .decl(let name, let e, let isV):
            if isV {
                if frames.isEmpty {
                    if varDone.contains(name) { return get(name) }
                    varDone.insert(name)
                } else {
                    let key = name + "#\(ctx)"
                    if varDone.contains(key) { return get(name) }
                    varDone.insert(key)
                }
            }
            let v = eval(e)
            set(name, v)
            return v
        case .assign(let name, let op, let e):
            let v = eval(e)
            var out = v
            if op != ":=" {
                let a = get(name).num, b = v.num
                switch op {
                case "+=": out = .n(a + b)
                case "-=": out = .n(a - b)
                case "*=": out = .n(a * b)
                default: out = .n(a / b)
                }
            }
            set(name, out)
            return out
        case .tupleDecl(let names, let e):
            let v = eval(e)
            if case .t(let xs) = v { for (k, nm) in names.enumerated() { set(nm, k < xs.count ? xs[k] : .n(.nan)) } }
            else { for nm in names { set(nm, v) } }
            return v
        case .expr(let e):
            return eval(e)
        case .ifs(let c, let a, let b):
            var last: PVal = .n(.nan)
            for s2 in (eval(c).truthy ? a : b) { last = execOne(s2) }
            return last
        case .loop(let v, let a, let b, let by, let body):
            let from = eval(a).num, to = eval(b).num
            var step = by.map { eval($0).num } ?? (to >= from ? 1 : -1)
            if step == 0 || step.isNaN { step = 1 }
            var x = from, guardN = 0
            while (step > 0 ? x <= to : x >= to) && guardN < 5000 {
                set(v, .n(x))
                for s2 in body { execOne(s2) }
                x += step; guardN += 1
            }
            return .n(.nan)
        case .fn:
            return .n(.nan)
        }
    }

    // MARK: variables

    private func set(_ name: String, _ v: PVal) {
        if !frames.isEmpty { frames[frames.count - 1][name] = v; return }
        switch v {
        case .n(let d):
            if vars[name] == nil { vars[name] = [Double](repeating: .nan, count: n) }
            vars[name]![bar] = d
            svars[name] = nil
        default:
            svars[name] = v
        }
    }

    private func get(_ name: String) -> PVal {
        if let f = frames.last, let v = f[name] { return v }
        if let v = svars[name] { return v }
        if let h = vars[name] { return .n(h[bar]) }
        return builtin(name, 0)
    }

    private func histOf(_ name: String, _ k: Int) -> Double {
        let i = bar - k
        guard i >= 0 else { return .nan }
        if let h = vars[name] { return h[i] }
        return builtin(name, k).num
    }

    private func src(_ key: String, _ k: Int) -> Double {
        let i = bar - k
        guard i >= 0, let a = input.series[key], i < a.count else { return .nan }
        return a[i]
    }

    private func builtin(_ name: String, _ k: Int) -> PVal {
        switch name {
        case "open", "high", "low", "close", "volume", "deliv_qty", "deliv_pct", "deliv_value", "nse_close", "delsmac", "dealsize", "dealbuy", "dealsell":
            return .n(src(name, k))
        case "hl2": return .n((src("high", k) + src("low", k)) / 2)
        case "hlc3": return .n((src("high", k) + src("low", k) + src("close", k)) / 3)
        case "ohlc4": return .n((src("open", k) + src("high", k) + src("low", k) + src("close", k)) / 4)
        case "hlcc4": return .n((src("high", k) + src("low", k) + 2 * src("close", k)) / 4)
        case "bar_index", "n": return .n(Double(bar - k))
        case "last_bar_index": return .n(Double(n - 1))
        case "barstate.islast", "barstate.islastconfirmedhistory": return .n(bar == n - 1 ? 1 : 0)
        case "barstate.isfirst": return .n(bar == 0 ? 1 : 0)
        case "barstate.isconfirmed", "barstate.ishistory": return .n(1)
        case "barstate.isrealtime", "barstate.isnew": return .n(0)
        case "math.pi": return .n(Double.pi)
        case "math.e": return .n(M_E)
        case "syminfo.ticker", "syminfo.tickerid", "syminfo.root": return .s(input.symbol)
        case "syminfo.mintick": return .n(0.05)
        case "timeframe.period": return .s("D")
        case "timeframe.isdaily": return .n(1)
        case "timeframe.isintraday", "timeframe.isweekly", "timeframe.ismonthly": return .n(0)
        case "year", "month", "dayofmonth", "dayofweek":
            let i = bar - k
            guard i >= 0, i < input.days.count else { return .n(.nan) }
            let p = input.days[i].split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return .n(.nan) }
            if name == "year" { return .n(Double(p[0])) }
            if name == "month" { return .n(Double(p[1])) }
            if name == "dayofmonth" { return .n(Double(p[2])) }
            var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
            let g = Calendar(identifier: .gregorian)
            return .n(Double(g.date(from: c).map { g.component(.weekday, from: $0) } ?? 0))
        case "ta.tr", "tr": return .n(trueRange(k))
        case "ta.obv": return .n(.nan)
        default: break
        }
        if let c = Self.colors[name] { return .s(c) }
        if name.hasPrefix("color.") { return .s("#2962FF") }
        if name.hasPrefix("location.") || name.hasPrefix("shape.") || name.hasPrefix("size.") || name.hasPrefix("plot.style")
            || name.hasPrefix("display.") || name.hasPrefix("hline.style") || name.hasPrefix("text.") || name.hasPrefix("position.")
            || name.hasPrefix("format.") || name.hasPrefix("scale.") || name.hasPrefix("extend.") || name.hasPrefix("xloc.")
            || name.hasPrefix("yloc.") || name.hasPrefix("font.") || name.hasPrefix("alert.") || name.hasPrefix("barmerge.") {
            return .s(name)
        }
        return .n(.nan)
    }

    static let colors: [String: String] = [
        "color.red": "#F23645", "color.green": "#089981", "color.blue": "#2962FF", "color.orange": "#FF9800", "color.yellow": "#FFEB3B",
        "color.purple": "#9C27B0", "color.white": "#FFFFFF", "color.black": "#363A45", "color.gray": "#787B86", "color.silver": "#B2B5BE",
        "color.lime": "#00E676", "color.teal": "#00897B", "color.aqua": "#00BCD4", "color.fuchsia": "#E040FB", "color.navy": "#311B92",
        "color.maroon": "#880E4F", "color.olive": "#808000",
        "red": "#F23645", "green": "#089981", "blue": "#2962FF", "orange": "#FF9800", "yellow": "#FFEB3B", "purple": "#9C27B0",
        "white": "#FFFFFF", "black": "#363A45", "gray": "#787B86", "silver": "#B2B5BE", "lime": "#00E676", "teal": "#00897B",
        "aqua": "#00BCD4", "fuchsia": "#E040FB", "navy": "#311B92", "maroon": "#880E4F", "olive": "#808000"]

    private func trueRange(_ k: Int) -> Double {
        let h = src("high", k), l = src("low", k), pc = src("close", k + 1)
        if pc.isNaN { return h - l }
        return max(h - l, abs(h - pc), abs(l - pc))
    }

    // MARK: expressions

    private func eval(_ e: PExpr) -> PVal {
        switch e {
        case .num(let d): return .n(d)
        case .str(let s): return .s(s)
        case .ident(let name): return get(name)
        case .list(let xs): return .t(xs.map { eval($0) })
        case .hist(let x, let kE, let site):
            let k = Int(eval(kE).num)
            if case .ident(let name) = x, frames.isEmpty || frames.last?[name] == nil { return .n(histOf(name, max(0, k))) }
            // history of an expression: remember its value on every bar
            let st = state(site)
            st.a.append(eval(x).num)
            let i = st.a.count - 1 - k
            return .n(i >= 0 ? st.a[i] : .nan)
        case .unary(let op, let x):
            let v = eval(x).num
            if op == "-" { return .n(-v) }
            return .n(v.isNaN ? .nan : (v == 0 ? 1 : 0))
        case .bin(let op, let a, let b):
            return binary(op, a, b)
        case .tern(let c, let a, let b):
            return eval(c).truthy ? eval(a) : eval(b)
        case .call(let name, let args, let named, let site):
            return call(name, args, named, site)
        }
    }

    private func binary(_ op: String, _ ae: PExpr, _ be: PExpr) -> PVal {
        if op == "and" { return .n(eval(ae).truthy && eval(be).truthy ? 1 : 0) }
        if op == "or" { return .n(eval(ae).truthy || eval(be).truthy ? 1 : 0) }
        let av = eval(ae), bv = eval(be)
        if case .s(let x) = av, case .s(let y) = bv {
            switch op {
            case "+": return .s(x + y)
            case "==": return .n(x == y ? 1 : 0)
            case "!=": return .n(x != y ? 1 : 0)
            default: return .n(.nan)
            }
        }
        if op == "+", case .s(let x) = av { return .s(x + fmtNum(bv.num)) }
        if op == "+", case .s(let y) = bv { return .s(fmtNum(av.num) + y) }
        let a = av.num, b = bv.num
        switch op {
        case "+": return .n(a + b)
        case "-": return .n(a - b)
        case "*": return .n(a * b)
        case "/": return .n(b == 0 ? .nan : a / b)
        case "%": return .n(b == 0 ? .nan : a.truncatingRemainder(dividingBy: b))
        case "==": return .n(a.isNaN || b.isNaN ? 0 : (a == b ? 1 : 0))
        case "!=": return .n(a.isNaN || b.isNaN ? 1 : (a != b ? 1 : 0))
        case "<": return .n(a.isNaN || b.isNaN ? 0 : (a < b ? 1 : 0))
        case "<=": return .n(a.isNaN || b.isNaN ? 0 : (a <= b ? 1 : 0))
        case ">": return .n(a.isNaN || b.isNaN ? 0 : (a > b ? 1 : 0))
        case ">=": return .n(a.isNaN || b.isNaN ? 0 : (a >= b ? 1 : 0))
        default: return .n(.nan)
        }
    }

    private func fmtNum(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(format: "%.4g", d)
    }

    private func state(_ site: Int) -> TA {
        let key = ctx &* 100_003 &+ site
        if let t = ta[key] { return t }
        let t = TA(); ta[key] = t; return t
    }

    private func arg(_ args: [PExpr], _ named: [String: PExpr], _ i: Int, _ names: [String]) -> PExpr? {
        for nm in names { if let e = named[nm] { return e } }
        return i < args.count ? args[i] : nil
    }

    private func num(_ args: [PExpr], _ named: [String: PExpr], _ i: Int, _ names: [String], _ def: Double = .nan) -> Double {
        guard let e = arg(args, named, i, names) else { return def }
        return eval(e).num
    }

    // MARK: calls

    private func call(_ rawName: String, _ args: [PExpr], _ named: [String: PExpr], _ site: Int) -> PVal {
        // Pine v4 names without the namespace
        let name = Self.v4[rawName] ?? rawName
        if let f = prog.functions[name] { return userCall(f.0, f.1, args, named, site) }
        switch name {
        case "plot": recordPlot(site, args, named, kind: "line"); return .n(.nan)
        case "plotshape", "plotchar": recordPlot(site, args, named, kind: "shape"); return .n(.nan)
        case "hline": recordPlot(site, args, named, kind: "hline"); return .n(.nan)
        case "alertcondition": recordPlot(site, args, named, kind: "alert"); return .n(.nan)
        case "sheet":
            guard let e = args.first, case .str(let c) = e, let a = input.sheet[c], bar < a.count else { return .n(.nan) }
            return .n(a[bar])
        case "input", "input.int", "input.float", "input.bool", "input.string", "input.color", "input.timeframe",
             "input.session", "input.symbol", "input.price", "input.time", "input.text_area", "input.source":
            guard let e = arg(args, named, 0, ["defval"]) else { return .n(.nan) }
            return eval(e)
        case "nz":
            let v = num(args, named, 0, ["source"])
            return .n(v.isNaN ? num(args, named, 1, ["replacement"], 0) : v)
        case "na": return .n(num(args, named, 0, ["x"]).isNaN ? 1 : 0)
        case "fixnan":
            let st = state(site), v = num(args, named, 0, ["source"])
            if !v.isNaN { st.prev = v }
            return .n(st.prev)
        case "int": let v = num(args, named, 0, ["x"]); return .n(v.isNaN ? .nan : v.rounded(.towardZero))
        case "float": return .n(num(args, named, 0, ["x"]))
        case "bool": return .n(eval(args.first ?? .num(0)).truthy ? 1 : 0)
        case "iff":
            guard !args.isEmpty else { return .n(.nan) }
            return eval(args[0]).truthy ? eval(args.count > 1 ? args[1] : .num(.nan)) : eval(args.count > 2 ? args[2] : .num(.nan))
        case "str.tostring": return .s(fmtNum(num(args, named, 0, ["value"])))
        case "str.format": return .s(args.first.flatMap { eval($0).str } ?? "")
        case "str.contains": return .n(0)
        case "color.new":
            let c = arg(args, named, 0, ["color"]).flatMap { eval($0).str } ?? "#2962FF"
            let t = num(args, named, 1, ["transp"], 0)
            return .s(Self.rgba(c, transp: t))
        case "color.rgb":
            let r = num(args, named, 0, ["red"], 0), g = num(args, named, 1, ["green"], 0), b = num(args, named, 2, ["blue"], 0)
            let t = num(args, named, 3, ["transp"], 0)
            return .s("rgba(\(Int(r)),\(Int(g)),\(Int(b)),\(String(format: "%.2f", max(0, min(1, 1 - t / 100)))))")
        case "alert": return .n(.nan)
        default: break
        }
        if name.hasPrefix("math.") { return mathCall(name, args, named, site) }
        if name.hasPrefix("ta.") { return taCall(name, args, named, site) }
        if PineParser.ignoredCalls.contains(name) { return .n(.nan) }
        return .n(.nan)
    }

    static let v4: [String: String] = [
        "sma": "ta.sma", "ema": "ta.ema", "rma": "ta.rma", "wma": "ta.wma", "stdev": "ta.stdev", "highest": "ta.highest",
        "lowest": "ta.lowest", "change": "ta.change", "mom": "ta.mom", "roc": "ta.roc", "rsi": "ta.rsi", "crossover": "ta.crossover",
        "crossunder": "ta.crossunder", "cross": "ta.cross", "percentrank": "ta.percentrank", "barssince": "ta.barssince",
        "valuewhen": "ta.valuewhen", "cum": "ta.cum", "atr": "ta.atr", "rising": "ta.rising", "falling": "ta.falling",
        "vwma": "ta.vwma", "dev": "ta.dev", "variance": "ta.variance", "macd": "ta.macd", "bb": "ta.bb", "linreg": "ta.linreg",
        "abs": "math.abs", "max": "math.max", "min": "math.min", "round": "math.round", "floor": "math.floor", "ceil": "math.ceil",
        "sqrt": "math.sqrt", "log": "math.log", "exp": "math.exp", "pow": "math.pow", "sign": "math.sign", "avg": "math.avg",
        "sum": "math.sum", "tostring": "str.tostring", "color": "color.new", "tr": "ta.tr"]

    static func rgba(_ c: String, transp t: Double) -> String {
        let a = max(0, min(1, 1 - (t.isNaN ? 0 : t) / 100))
        var h = c
        if h.hasPrefix("rgba(") {
            let p = h.dropFirst(5).dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count >= 3 { return "rgba(\(p[0]),\(p[1]),\(p[2]),\(String(format: "%.2f", a)))" }
            return h
        }
        guard h.hasPrefix("#") else { return h }
        h.removeFirst()
        guard h.count >= 6, let v = UInt32(h.prefix(6), radix: 16) else { return c }
        return "rgba(\((v >> 16) & 255),\((v >> 8) & 255),\(v & 255),\(String(format: "%.2f", a)))"
    }

    private func userCall(_ params: [String], _ body: [PStmt], _ args: [PExpr], _ named: [String: PExpr], _ site: Int) -> PVal {
        guard frames.count < 30 else { errors.append("functions nested too deep"); return .n(.nan) }
        var f: [String: PVal] = [:]
        for (k, p) in params.enumerated() {
            if let e = named[p] { f[p] = eval(e) } else if k < args.count { f[p] = eval(args[k]) }
        }
        let saved = ctx
        ctx = ctx &* 31 &+ site
        frames.append(f)
        var last: PVal = .n(.nan)
        for s in body { last = execOne(s) }
        frames.removeLast()
        ctx = saved
        return last
    }

    private func mathCall(_ name: String, _ args: [PExpr], _ named: [String: PExpr], _ site: Int) -> PVal {
        let a = num(args, named, 0, ["number", "source", "x", "base"])
        switch name {
        case "math.abs": return .n(abs(a))
        case "math.max": return .n(args.map { eval($0).num }.filter { !$0.isNaN }.max() ?? .nan)
        case "math.min": return .n(args.map { eval($0).num }.filter { !$0.isNaN }.min() ?? .nan)
        case "math.avg": let xs = args.map { eval($0).num }; return .n(xs.reduce(0, +) / Double(max(1, xs.count)))
        case "math.round":
            let p = num(args, named, 1, ["precision"], 0)
            if p.isNaN || p == 0 { return .n(a.rounded()) }
            let m = pow(10, p); return .n((a * m).rounded() / m)
        case "math.round_to_mintick": return .n((a * 20).rounded() / 20)
        case "math.floor": return .n(a.rounded(.down))
        case "math.ceil": return .n(a.rounded(.up))
        case "math.sqrt": return .n(a < 0 ? .nan : a.squareRoot())
        case "math.log": return .n(a <= 0 ? .nan : Foundation.log(a))
        case "math.log10": return .n(a <= 0 ? .nan : Foundation.log10(a))
        case "math.exp": return .n(Foundation.exp(a))
        case "math.pow": return .n(Foundation.pow(a, num(args, named, 1, ["exponent"])))
        case "math.sign": return .n(a.isNaN ? .nan : (a > 0 ? 1 : (a < 0 ? -1 : 0)))
        case "math.sum":
            let st = state(site); st.a.append(a)
            let len = Int(num(args, named, 1, ["length"], 1))
            return .n(window(st.a, len).map { $0.reduce(0, +) } ?? .nan)
        default: return .n(.nan)
        }
    }

    /// The last `len` values (nil until there are that many, or when one is na).
    private func window(_ xs: [Double], _ len: Int) -> ArraySlice<Double>? {
        guard len > 0, xs.count >= len else { return nil }
        let w = xs[(xs.count - len)...]
        if w.contains(where: { $0.isNaN }) { return nil }
        return w
    }

    private func taCall(_ name: String, _ args: [PExpr], _ named: [String: PExpr], _ site: Int) -> PVal {
        let st = state(site)
        func lenArg(_ i: Int) -> Int { max(1, Int(num(args, named, i, ["length"], 14))) }
        switch name {
        case "ta.sma", "ta.ema", "ta.rma", "ta.wma", "ta.stdev", "ta.variance", "ta.dev", "ta.median", "ta.swma", "ta.hma", "ta.linreg":
            let x = num(args, named, 0, ["source"])
            let len = name == "ta.swma" ? 4 : lenArg(1)
            st.a.append(x)
            return .n(movingStat(name, st, len, args, named))
        case "ta.vwma":
            let x = num(args, named, 0, ["source"]), len = lenArg(1), v = src("volume", 0)
            st.a.append(x * v); st.b.append(v)
            guard let p = window(st.a, len), let q = window(st.b, len) else { return .n(.nan) }
            let qs = q.reduce(0, +)
            return .n(qs == 0 ? .nan : p.reduce(0, +) / qs)
        case "ta.highest", "ta.lowest", "ta.highestbars", "ta.lowestbars":
            let hi = name.contains("highest")
            let oneArg = arg(args, named, 1, ["length"]) == nil
            let x = oneArg ? src(hi ? "high" : "low", 0) : num(args, named, 0, ["source"])
            let len = oneArg ? max(1, Int(num(args, named, 0, ["length"], 14))) : lenArg(1)
            st.a.append(x)
            guard let w = window(st.a, len) else { return .n(.nan) }
            let best = hi ? w.max()! : w.min()!
            if name.hasSuffix("bars") {
                let idx = (hi ? w.lastIndex(of: best) : w.lastIndex(of: best)) ?? w.endIndex - 1
                return .n(-Double(w.endIndex - 1 - idx))
            }
            return .n(best)
        case "ta.change", "ta.mom", "ta.roc":
            let x = num(args, named, 0, ["source"])
            let len = max(1, Int(num(args, named, 1, ["length"], name == "ta.change" ? 1 : 10)))
            st.a.append(x)
            let i = st.a.count - 1 - len
            guard i >= 0 else { return .n(.nan) }
            let p = st.a[i]
            if name == "ta.roc" { return .n(p == 0 ? .nan : (x - p) / p * 100) }
            return .n(x - p)
        case "ta.rsi":
            let x = num(args, named, 0, ["source"]), len = lenArg(1)
            st.a.append(x)
            guard st.a.count >= 2 else { return .n(.nan) }
            let ch = x - st.a[st.a.count - 2]
            let up = max(ch, 0), dn = max(-ch, 0)
            st.b.append(up); st.c.append(dn)
            let u = rma(&st.prev, st.b, len), d = rmaSecond(st, len)
            if u.isNaN || d.isNaN { return .n(.nan) }
            if d == 0 { return .n(100) }
            if u == 0 { return .n(0) }
            return .n(100 - 100 / (1 + u / d))
        case "ta.crossover", "ta.crossunder", "ta.cross":
            let a = num(args, named, 0, ["source1"]), b = num(args, named, 1, ["source2"])
            st.a.append(a); st.b.append(b)
            guard st.a.count >= 2 else { return .n(0) }
            let pa = st.a[st.a.count - 2], pb = st.b[st.b.count - 2]
            let over = a > b && pa <= pb, under = a < b && pa >= pb
            if name == "ta.crossover" { return .n(over ? 1 : 0) }
            if name == "ta.crossunder" { return .n(under ? 1 : 0) }
            return .n(over || under ? 1 : 0)
        case "ta.percentrank":
            let x = num(args, named, 0, ["source"]), len = lenArg(1)
            st.a.append(x)
            guard st.a.count > len, !x.isNaN else { return .n(.nan) }
            var c = 0
            for k in (st.a.count - 1 - len)..<(st.a.count - 1) where st.a[k] <= x { c += 1 }
            return .n(Double(c) / Double(len) * 100)
        case "ta.barssince":
            let c = eval(args.first ?? .num(0)).truthy
            if c { st.prev = 0 } else if !st.prev.isNaN { st.prev += 1 }
            return .n(st.prev)
        case "ta.valuewhen":
            let c = eval(args.first ?? .num(0)).truthy
            let v = num(args, named, 1, ["source"])
            let occ = Int(num(args, named, 2, ["occurrence"], 0))
            if c { st.a.append(v) }
            let i = st.a.count - 1 - max(0, occ)
            return .n(i >= 0 ? st.a[i] : .nan)
        case "ta.cum":
            let x = num(args, named, 0, ["source"])
            if !x.isNaN { st.cum += x }
            return .n(st.cum)
        case "ta.tr": return .n(trueRange(0))
        case "ta.atr":
            let len = max(1, Int(num(args, named, 0, ["length"], 14)))
            st.a.append(trueRange(0))
            return .n(rma(&st.prev, st.a, len))
        case "ta.rising", "ta.falling":
            let x = num(args, named, 0, ["source"]), len = lenArg(1)
            st.a.append(x)
            guard st.a.count > len else { return .n(0) }
            let prev = st.a[(st.a.count - 1 - len)..<(st.a.count - 1)]
            let ok = name == "ta.rising" ? prev.allSatisfy { x > $0 } : prev.allSatisfy { x < $0 }
            return .n(ok ? 1 : 0)
        case "ta.macd":
            let x = num(args, named, 0, ["source"])
            let f = max(1, Int(num(args, named, 1, ["fastlen"], 12))), sl = max(1, Int(num(args, named, 2, ["slowlen"], 26)))
            let sg = max(1, Int(num(args, named, 3, ["siglen"], 9)))
            st.a.append(x)
            let fe = emaOf(st, slot: 0, st.a, f), se = emaOf(st, slot: 1, st.a, sl)
            let m = fe - se
            st.b.append(m)
            let sig = emaOf(st, slot: 2, st.b.filter { !$0.isNaN }, sg, fresh: !m.isNaN)
            return .t([.n(m), .n(sig), .n(m - sig)])
        case "ta.bb":
            let x = num(args, named, 0, ["source"]), len = lenArg(1), mult = num(args, named, 2, ["mult"], 2)
            st.a.append(x)
            guard let w = window(st.a, len) else { return .t([.n(.nan), .n(.nan), .n(.nan)]) }
            let m = w.reduce(0, +) / Double(len)
            let sd = (w.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(len)).squareRoot()
            return .t([.n(m), .n(m + mult * sd), .n(m - mult * sd)])
        case "ta.cci":
            let x = num(args, named, 0, ["source"]), len = lenArg(1)
            st.a.append(x)
            guard let w = window(st.a, len) else { return .n(.nan) }
            let m = w.reduce(0, +) / Double(len)
            let md = w.reduce(0) { $0 + abs($1 - m) } / Double(len)
            return .n(md == 0 ? 0 : (x - m) / (0.015 * md))
        case "ta.mfi":
            let x = num(args, named, 0, ["series"]), len = lenArg(1), v = src("volume", 0)
            st.a.append(x)
            let prev = st.a.count >= 2 ? st.a[st.a.count - 2] : .nan
            st.b.append(x > prev ? x * v : 0); st.c.append(x < prev ? x * v : 0)
            guard let u = window(st.b, len), let d = window(st.c, len) else { return .n(.nan) }
            let us = u.reduce(0, +), ds = d.reduce(0, +)
            return .n(ds == 0 ? 100 : 100 - 100 / (1 + us / ds))
        default:
            return .n(.nan)
        }
    }

    private func movingStat(_ name: String, _ st: TA, _ len: Int, _ args: [PExpr], _ named: [String: PExpr]) -> Double {
        switch name {
        case "ta.sma":
            guard let w = window(st.a, len) else { return .nan }
            return w.reduce(0, +) / Double(len)
        case "ta.ema": return emaOf(st, slot: 0, st.a, len)
        case "ta.rma": return rma(&st.prev, st.a, len)
        case "ta.wma":
            guard let w = window(st.a, len) else { return .nan }
            var s = 0.0, ws = 0.0
            for (k, v) in w.enumerated() { let wt = Double(k + 1); s += v * wt; ws += wt }
            return s / ws
        case "ta.swma":
            guard let w = window(st.a, 4) else { return .nan }
            let a = Array(w)
            return a[0] / 6 + a[1] * 2 / 6 + a[2] * 2 / 6 + a[3] / 6
        case "ta.hma":
            return .nan
        case "ta.stdev", "ta.variance", "ta.dev":
            guard let w = window(st.a, len) else { return .nan }
            let m = w.reduce(0, +) / Double(len)
            if name == "ta.dev" { return w.reduce(0) { $0 + abs($1 - m) } / Double(len) }
            let v = w.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(len)       // population, as TradingView
            return name == "ta.variance" ? v : v.squareRoot()
        case "ta.median":
            guard let w = window(st.a, len) else { return .nan }
            let s = w.sorted(), m = s.count / 2
            return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
        case "ta.linreg":
            guard let w = window(st.a, len) else { return .nan }
            let off = num(args, named, 2, ["offset"], 0)
            let ys = Array(w), nn = Double(len)
            let xm = (nn - 1) / 2, ym = ys.reduce(0, +) / nn
            var sxy = 0.0, sxx = 0.0
            for (k, y) in ys.enumerated() { let dx = Double(k) - xm; sxy += dx * (y - ym); sxx += dx * dx }
            let slope = sxx == 0 ? 0 : sxy / sxx
            return ym + slope * (nn - 1 - xm - off)
        default: return .nan
        }
    }

    /// EMA seeded with the SMA of the first `len` values (as TradingView).
    private func emaOf(_ st: TA, slot: Int, _ xs: [Double], _ len: Int, fresh: Bool = true) -> Double {
        while st.c.count <= slot { st.c.append(.nan) }
        guard fresh, let x = xs.last, !x.isNaN else { return st.c[slot] }
        let alpha = 2.0 / Double(len + 1)
        if st.c[slot].isNaN {
            guard let w = window(xs, len) else { return .nan }
            st.c[slot] = w.reduce(0, +) / Double(len)
        } else {
            st.c[slot] = alpha * x + (1 - alpha) * st.c[slot]
        }
        return st.c[slot]
    }

    /// RMA (Wilder): alpha = 1/len, seeded with the SMA.
    private func rma(_ prev: inout Double, _ xs: [Double], _ len: Int) -> Double {
        guard let x = xs.last, !x.isNaN else { return prev }
        if prev.isNaN {
            guard let w = window(xs, len) else { return .nan }
            prev = w.reduce(0, +) / Double(len)
        } else {
            prev = (prev * Double(len - 1) + x) / Double(len)
        }
        return prev
    }

    private func rmaSecond(_ st: TA, _ len: Int) -> Double {
        // RSI's down-average lives in st.cum (NaN-seeded via a flag in st.count)
        guard let x = st.c.last, !x.isNaN else { return .nan }
        if st.count == 0 {
            guard let w = window(st.c, len) else { return .nan }
            st.cum = w.reduce(0, +) / Double(len); st.count = 1
        } else {
            st.cum = (st.cum * Double(len - 1) + x) / Double(len)
        }
        return st.cum
    }

    // MARK: outputs

    private func recordPlot(_ site: Int, _ args: [PExpr], _ named: [String: PExpr], kind: String) {
        let box: PlotBox
        if let b = plots[site] { box = b } else {
            box = PlotBox()
            var q = PinePlot()
            q.site = site; q.kind = kind
            q.values = [Double](repeating: .nan, count: n)
            q.colors = [String?](repeating: nil, count: n)
            if let t = arg(args, named, 1, ["title"]).flatMap({ eval($0).str }) { q.title = t }
            if q.title.isEmpty {
                switch kind {
                case "hline": q.title = "Level \(plotOrder.count + 1)"
                case "alert": q.title = "Alert \(plotOrder.count + 1)"
                case "shape": q.title = "Shape \(plotOrder.count + 1)"
                default: q.title = "Plot \(plotOrder.count + 1)"
                }
            }
            if kind == "shape" {
                q.text = named["text"].flatMap { eval($0).str } ?? named["char"].flatMap { eval($0).str } ?? ""
                q.location = named["location"].flatMap { eval($0).str }.map { $0.replacingOccurrences(of: "location.", with: "") } ?? "abovebar"
                q.shape = named["style"].flatMap { eval($0).str }.map { $0.replacingOccurrences(of: "shape.", with: "") } ?? "circle"
            }
            if kind == "line", let st = named["style"].flatMap({ eval($0).str }) {
                if st.contains("histogram") || st.contains("columns") || st.contains("area") { q.kind = "hist" }
                else if st.contains("step") { q.kind = "step" }
            }
            if let w = named["linewidth"] { let v = eval(w).num; if !v.isNaN { q.width = v } }
            box.p = q
            plots[site] = box
            plotOrder.append(site)
        }
        let v = eval(args.first ?? .num(.nan))
        if kind == "shape" || kind == "alert" { box.p.values[bar] = v.truthy ? 1 : .nan }
        else { box.p.values[bar] = v.num }
        if let ce = named["color"] {
            let c = eval(ce).str
            box.p.colors[bar] = c
            if let c, box.p.color == "#2962FF" || bar == n - 1 { box.p.color = c }
        }
    }
}

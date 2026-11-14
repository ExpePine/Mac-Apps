import Foundation

// MARK: - Custom series for Event Scan (Pine-like expressions on a stock's NSE history)
//
// Variables (per trading day):  close · dq (DELIV_QTY) · per (Deliv %) · value (DQ×close) · vol (traded qty)
//                               hit3 · delsma · dqprank · t3 · t3color · sma22 · sma66   (the built-in metrics)
// Functions:  sma(x,n) ema(x,n) highest(x,n) lowest(x,n) change(x,n) roc(x,n) prank(x,n) abs(x) max(a,b) min(a,b)
//             ("ta." prefix is allowed: ta.sma(close, 50))
// History:    x[1] = yesterday's x, close[5] = 5 days ago
// Operators:  + - * / and ( )
// Examples:   close / sma(close, 50)          roc(close, 5)          dq / sma(dq, 20)
//             value / highest(value, 300)     close - highest(close, 252)[1]

struct ScanCustom: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var expr: String
}

indirect enum ScanExpr: Sendable {
    case num(Double)
    case variable(String)
    case call(String, [ScanExpr])
    case lag(ScanExpr, Int)
    case neg(ScanExpr)
    case bin(Character, ScanExpr, ScanExpr)

    struct ParseError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    static let variables = ["close", "dq", "qty", "per", "value", "vol", "hit3", "delsma", "dqprank", "t3", "t3color", "sma22", "sma66"]
    static let functions = ["sma", "ema", "highest", "lowest", "change", "roc", "prank", "percentrank", "abs", "max", "min"]

    // MARK: Parsing

    static func parse(_ text: String) throws -> ScanExpr {
        var p = Parser(tokens: try tokenize(text))
        let e = try p.expr()
        guard p.i == p.tokens.count else { throw ParseError(message: "Unexpected “\(p.tokens[p.i])”") }
        return e
    }

    private static func tokenize(_ s: String) throws -> [String] {
        var out: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." { cur.append(ch) }
            else if ch == " " || ch == "\t" { flush() }
            else if "+-*/(),[]".contains(ch) { flush(); out.append(String(ch)) }
            else { throw ParseError(message: "Can't use “\(ch)” — use + - * / ( ) [ ]") }
        }
        flush()
        return out.map { $0.hasPrefix("ta.") ? String($0.dropFirst(3)) : $0 }
    }

    private struct Parser {
        let tokens: [String]
        var i = 0
        var peek: String? { i < tokens.count ? tokens[i] : nil }
        mutating func take() -> String? { defer { i += 1 }; return peek }
        mutating func expect(_ t: String) throws { guard take() == t else { throw ParseError(message: "Expected “\(t)”") } }

        mutating func expr() throws -> ScanExpr {
            var l = try term()
            while let t = peek, t == "+" || t == "-" { i += 1; l = .bin(Character(t), l, try term()) }
            return l
        }
        mutating func term() throws -> ScanExpr {
            var l = try unary()
            while let t = peek, t == "*" || t == "/" { i += 1; l = .bin(Character(t), l, try unary()) }
            return l
        }
        mutating func unary() throws -> ScanExpr {
            if peek == "-" { i += 1; return .neg(try unary()) }
            var e = try primary()
            while peek == "[" {
                i += 1
                guard let t = take(), let k = Int(t), k >= 0 else { throw ParseError(message: "x[n] needs a whole number of days") }
                try expect("]")
                e = .lag(e, k)
            }
            return e
        }
        mutating func primary() throws -> ScanExpr {
            guard let t = take() else { throw ParseError(message: "Formula ends too early") }
            if t == "(" { let e = try expr(); try expect(")"); return e }
            if let v = Double(t) { return .num(v) }
            if peek == "(" {
                guard ScanExpr.functions.contains(t) else { throw ParseError(message: "Unknown function “\(t)” — use \(ScanExpr.functions.joined(separator: ", "))") }
                i += 1
                var args: [ScanExpr] = []
                if peek != ")" {
                    args.append(try expr())
                    while peek == "," { i += 1; args.append(try expr()) }
                }
                try expect(")")
                let need = ["abs": 1, "max": 2, "min": 2][t] ?? 2
                guard args.count == need else { throw ParseError(message: "\(t)() needs \(need) value\(need == 1 ? "" : "s")") }
                if need == 2, !["max", "min"].contains(t) {
                    guard case .num(let n) = args[1], n >= 1 else { throw ParseError(message: "\(t)(x, n): n must be a number of days ≥ 1") }
                }
                return .call(t, args)
            }
            guard ScanExpr.variables.contains(t) else { throw ParseError(message: "Unknown name “\(t)” — use \(ScanExpr.variables.joined(separator: ", "))") }
            return .variable(t)
        }
    }

    // MARK: Evaluating on one stock

    func eval(_ s: DeliverySeries, cache: inout [String: [Double?]]) -> [Double?] {
        let n = s.close.count
        switch self {
        case .num(let v): return Array(repeating: v, count: n)
        case .variable(let name):
            if let c = cache[name] { return c }
            let v: [Double?]
            switch name {
            case "close": v = s.close.map { $0 }
            case "dq", "qty": v = s.qty.map { $0 }
            case "per": v = s.per.map { $0 }
            case "value": v = zip(s.qty, s.close).map { $0 * $1 }
            case "vol": v = zip(s.qty, s.per).map { $1 > 0 ? $0 * 100 / $1 : nil }
            case "hit3": v = ScanEngine.series(.hiT3, s)
            case "delsma": v = ScanEngine.series(.delSma, s)
            case "dqprank": v = ScanEngine.series(.dqPrank, s)
            case "t3": v = ScanEngine.series(.t3, s)
            case "t3color": v = ScanEngine.series(.t3Color, s)
            case "sma22": v = ScanEngine.series(.sma22, s)
            default: v = ScanEngine.series(.sma66, s)
            }
            cache[name] = v
            return v
        case .neg(let e): return e.eval(s, cache: &cache).map { $0.map { -$0 } }
        case .lag(let e, let k):
            let x = e.eval(s, cache: &cache)
            return x.indices.map { $0 - k >= 0 ? x[$0 - k] : nil }
        case .bin(let op, let a, let b):
            let x = a.eval(s, cache: &cache), y = b.eval(s, cache: &cache)
            return zip(x, y).map { p in
                guard let u = p.0, let v = p.1 else { return nil }
                switch op {
                case "+": return u + v
                case "-": return u - v
                case "*": return u * v
                default: return v == 0 ? nil : u / v
                }
            }
        case .call(let f, let args):
            let x = args[0].eval(s, cache: &cache)
            switch f {
            case "abs": return x.map { $0.map(Swift.abs) }
            case "max", "min":
                let y = args[1].eval(s, cache: &cache)
                return zip(x, y).map { p in guard let u = p.0, let v = p.1 else { return nil }; return f == "max" ? Swift.max(u, v) : Swift.min(u, v) }
            default:
                guard case .num(let nn) = args[1] else { return Array(repeating: nil, count: n) }
                let k = Int(nn)
                switch f {
                case "sma": return Self.sma(x, k)
                case "ema": return Self.ema(x, k)
                case "highest": return Self.extreme(x, k, max: true)
                case "lowest": return Self.extreme(x, k, max: false)
                case "change": return x.indices.map { i in i >= k ? (x[i].flatMap { a in x[i - k].map { a - $0 } }) : nil }
                case "roc": return x.indices.map { i in i >= k ? (x[i].flatMap { a in x[i - k].flatMap { $0 == 0 ? nil : (a / $0 - 1) * 100 } }) : nil }
                default: return Self.prank(x, k)
                }
            }
        }
    }

    // nil inside the window → nil (like Pine na)
    static func sma(_ x: [Double?], _ k: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        var sum = 0.0, nils = 0
        for i in x.indices {
            if let v = x[i] { sum += v } else { nils += 1 }
            if i >= k { if let o = x[i - k] { sum -= o } else { nils -= 1 } }
            if i >= k - 1, nils == 0 { out[i] = sum / Double(k) }
        }
        return out
    }

    static func ema(_ x: [Double?], _ k: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        let a = 2 / Double(k + 1)
        var prev: Double?
        var run: [Double] = []
        for i in x.indices {
            guard let v = x[i] else { prev = nil; run = []; continue }
            if let p = prev { prev = a * v + (1 - a) * p; out[i] = prev; continue }
            run.append(v)
            if run.count == k { prev = run.reduce(0, +) / Double(k); out[i] = prev }
        }
        return out
    }

    static func extreme(_ x: [Double?], _ k: Int, max: Bool) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        var dq: [Int] = [], head = 0, lastNil = -1
        for i in x.indices {
            guard let v = x[i] else { lastNil = i; continue }
            while dq.count > head, let w = x[dq.last!], max ? w <= v : w >= v { dq.removeLast() }
            dq.append(i)
            while head < dq.count, dq[head] <= i - k { head += 1 }
            if i - lastNil >= k, head < dq.count { out[i] = x[dq[head]] }
        }
        return out
    }

    /// % of the previous k values ≤ the current one (Pine ta.percentrank).
    static func prank(_ x: [Double?], _ k: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        for i in x.indices where i >= k {
            guard let v = x[i] else { continue }
            var c = 0, ok = true
            for j in (i - k)..<i { guard let w = x[j] else { ok = false; break }; if w <= v { c += 1 } }
            if ok { out[i] = Double(c) / Double(k) * 100 }
        }
        return out
    }
}

enum ScanCustomStore {
    static var all: [ScanCustom] {
        get { (UserDefaults.standard.data(forKey: "scan.customs")).flatMap { try? JSONDecoder().decode([ScanCustom].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "scan.customs") }
    }
}

import Foundation

/// Decides whether a column is a sensible model input ("feature") or something like a raw price,
/// a date, or a name that would only confuse the neural net.
enum ColumnKind: String {
    case feature, priceLevel, rawSize, date, identifier, text, constant

    var title: String {
        switch self {
        case .feature:    return "Feature"
        case .priceLevel: return "Price level"
        case .rawSize:    return "Raw size"
        case .date:       return "Date"
        case .identifier: return "Name / ID"
        case .text:       return "Text"
        case .constant:   return "No variation"
        }
    }

    /// Picked automatically?
    var isFeature: Bool { self == .feature }
}

struct ColumnProfile: Identifiable {
    var id: String { name }
    let name: String
    let kind: ColumnKind
    let reason: String
    let coverage: Double     // share of rows with a number
    let distinct: Int        // distinct numbers (capped at 1000)
    let inFilter: Bool       // visible on the Filter screen
}

enum FeatureClassifier {

    /// Name words that mean "relative / already scale-free" — these stay features even if they mention a price.
    private static let relativeWords: Set<String> = [
        "ratio", "pct", "percent", "chg", "change", "rsi", "score", "rank", "return", "ret", "gain", "dist",
        "distance", "slope", "roc", "adx", "mfi", "cci", "stoch", "trigger", "count", "flag", "signal",
        "strength", "momentum", "rel", "relative", "zscore", "z", "beta", "vs", "above", "below", "cross",
        "green", "red", "up", "down", "streak", "days"
    ]
    private static let priceWords: Set<String> = [
        "close", "open", "high", "low", "price", "ltp", "cmp", "vwap", "ema", "sma", "ma", "dma", "wma",
        "pivot", "support", "resistance", "target", "sl", "stoploss", "upper", "lower", "band", "ath", "atl",
        "prevclose", "52wh", "52wl", "hh", "ll", "atr", "bid", "ask", "entry", "exit"
    ]
    private static let sizeWords: Set<String> = [
        "volume", "vol", "turnover", "value", "mcap", "marketcap", "cap", "oi", "qty", "quantity", "shares", "trades"
    ]
    private static let dateWords: Set<String> = [
        "month", "day", "date", "year", "time", "week", "weekday", "dd", "mm", "yy", "yyyy", "timestamp"
    ]
    private static let idWords: Set<String> = [
        "symbol", "ticker", "name", "isin", "id", "code", "sno", "serial", "sr", "series", "sector", "industry", "company"
    ]

    /// Lower-case words of a column name: "D_close" → [d, close]; "EMA20" → [ema, 20]; "PrevClose" → [prev, close, prevclose].
    static func words(_ name: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prev: Character?
        func flush() { if !cur.isEmpty { out.append(cur.lowercased()); cur = "" } }
        for ch in name {
            if !(ch.isLetter || ch.isNumber) { flush(); prev = nil; continue }
            if let p = prev {
                let split = (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter)
                if split { flush() }
            }
            cur.append(ch); prev = ch
        }
        flush()
        let joined = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if out.count > 1 { out.append(joined) }
        return out
    }

    static func classify(name: String, numbers: [Double?], isLabel: Bool) -> (ColumnKind, String) {
        if isLabel { return (.identifier, "The stock name column") }
        if name == "NN_score" || name == "NN_conf" { return (.identifier, "The neural net's own output") }
        let w = Set(words(name))
        let n = numbers.count
        let nums = numbers.compactMap { $0 }
        let coverage = n == 0 ? 0 : Double(nums.count) / Double(n)

        if !w.isDisjoint(with: dateWords) { return (.date, "A calendar value, not a property of the stock") }
        if !w.isDisjoint(with: idWords) && coverage < 0.9 { return (.identifier, "Names or codes") }
        if coverage < 0.5 { return (.text, nums.isEmpty ? "No numbers" : "Mostly text") }

        let distinct = Set(nums)
        if distinct.count <= 1 { return (.constant, "Same value for every stock") }
        if w.contains("sno") || w.contains("serial") || w.contains("sr")
            || (!w.isDisjoint(with: idWords) && distinct.count == nums.count) {
            return (.identifier, "Row numbers / IDs")
        }
        if name.contains("%") || !w.isDisjoint(with: relativeWords) { return (.feature, "Scale-free value") }
        if !w.isDisjoint(with: priceWords) {
            return (.priceLevel, "₹ level — a ₹50 and a ₹5,000 stock differ only by price. Use a ratio column (e.g. close vs EMA %) instead")
        }
        if !w.isDisjoint(with: sizeWords) {
            return (.rawSize, "Raw size grows with the company — big stocks look different, not better. A ratio (e.g. Vol Ratio) is a better feature")
        }
        // Value check: positive values spanning a huge range look like prices or sizes.
        let sorted = nums.sorted()
        let p5 = sorted[sorted.count / 20], p95 = sorted[(sorted.count * 19) / 20], median = sorted[sorted.count / 2]
        if p5 > 0, median > 20, p95 / p5 > 40 {
            return (.priceLevel, "Values range \(Int(p5))–\(Int(p95)), like prices — likely a ₹ level")
        }
        return (.feature, distinct.isSubset(of: [0, 1]) ? "Yes/no flag" : "Numeric value")
    }

    static func profiles(table: SheetTable, label: Int?, filterColumns: [Int], sample: Int = 3000) -> [ColumnProfile] {
        let rows = table.rows.prefix(sample)
        let inFilter = Set(filterColumns)
        return table.headers.indices.map { c in
            let nums = rows.map { $0.number(c) }
            let (kind, reason) = classify(name: table.headers[c], numbers: nums, isLabel: c == label)
            let present = nums.compactMap { $0 }
            return ColumnProfile(name: table.headers[c], kind: kind, reason: reason,
                                 coverage: nums.isEmpty ? 0 : Double(present.count) / Double(nums.count),
                                 distinct: Set(present.prefix(5000)).count, inFilter: inFilter.contains(c))
        }
    }
}

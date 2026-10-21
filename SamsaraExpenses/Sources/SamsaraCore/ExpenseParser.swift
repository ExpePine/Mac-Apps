import Foundation

public struct ParseResult {
    public var expenses: [Expense]
    public var warnings: [String]
    public var header: [String]
}

public enum ParseError: LocalizedError, Equatable {
    case empty
    case missingColumns([String])

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The CSV is empty."
        case .missingColumns(let cols):
            return "The CSV is missing required column(s): \(cols.joined(separator: ", ")). Expected the Samsara export (ID, Product, Price, Category, Platform/Vendor, Saved By, Quantity, Date)."
        }
    }
}

public enum ExpenseParser {

    public static let exportHeader = ["ID", "Product", "Price", "Category", "Platform/Vendor", "Saved By", "Quantity", "Date"]

    private enum Field: CaseIterable {
        case id, product, price, category, vendor, savedBy, quantity, date

        var aliases: [String] {
            switch self {
            case .id: return ["id"]
            case .product: return ["product", "item", "name", "description"]
            case .price: return ["price", "amount", "total", "cost"]
            case .category: return ["category"]
            case .vendor: return ["platformvendor", "vendor", "platform", "store"]
            case .savedBy: return ["savedby", "user", "by", "addedby"]
            case .quantity: return ["quantity", "qty"]
            case .date: return ["date", "datetime", "createdat", "time"]
            }
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func parse(text: String, timeZone: TimeZone = .current) throws -> ParseResult {
        let rows = CSV.parse(text)
        guard let header = rows.first else { throw ParseError.empty }

        var index: [Field: Int] = [:]
        let normHeader = header.map(normalize)
        for field in Field.allCases {
            for alias in field.aliases {
                if let i = normHeader.firstIndex(of: alias) {
                    index[field] = i
                    break
                }
            }
        }
        var missing: [String] = []
        if index[.product] == nil { missing.append("Product") }
        if index[.price] == nil { missing.append("Price") }
        if !missing.isEmpty { throw ParseError.missingColumns(missing) }

        let dateParser = DateParser(timeZone: timeZone)
        var expenses: [Expense] = []
        var warnings: [String] = []
        var seenIDs = Set<String>()
        var noPrice = 0
        var noDate = 0

        for (n, row) in rows.dropFirst().enumerated() {
            func value(_ f: Field) -> String {
                guard let i = index[f], i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let product = cleanText(value(.product))
            let rawPrice = value(.price)
            if product.isEmpty && rawPrice.isEmpty { continue }

            var id = value(.id)
            if id.isEmpty || seenIDs.contains(id) { id = "row-\(n + 1)" }
            seenIDs.insert(id)

            let amount: Double
            if let p = parsePrice(rawPrice) {
                amount = p
            } else {
                amount = 0
                noPrice += 1
            }
            let date = dateParser.parse(value(.date))
            if date == nil { noDate += 1 }

            var category = cleanText(value(.category))
            if category.isEmpty { category = "Uncategorized" }

            expenses.append(Expense(
                id: id,
                product: product.isEmpty ? "(no name)" : product,
                amount: amount,
                category: category,
                vendor: cleanText(value(.vendor)),
                savedBy: cleanText(value(.savedBy)),
                quantity: value(.quantity),
                date: date,
                rawPrice: rawPrice
            ))
        }

        if noPrice > 0 { warnings.append("\(noPrice) row(s) have no price and count as ₹0.") }
        if noDate > 0 { warnings.append("\(noDate) row(s) have no valid date; they are left out of time-based charts.") }
        return ParseResult(expenses: expenses, warnings: warnings, header: header)
    }

    /// "₹59" → 59, "20.00" → 20, "1,500" → 1500, "₹50 ₹42" (MRP + price paid) → 42, "" → nil.
    public static func parsePrice(_ raw: String) -> Double? {
        let s = raw.replacingOccurrences(of: ",", with: "")
        guard let re = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return nil }
        let ns = s as NSString
        let values = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .compactMap { Double(ns.substring(with: $0.range)) }
        return values.min()
    }

    /// Undo PHP-style escaping seen in the export ("Dosa N Chatny\'s").
    static func cleanText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\'", with: "'")
         .replacingOccurrences(of: "\\\"", with: "\"")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes expenses back out in the Samsara column layout.
    public static func csv(for expenses: [Expense], timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [CSV.line(exportHeader)]
        for e in expenses {
            let price = e.amount == e.amount.rounded() ? String(Int(e.amount)) : String(format: "%.2f", e.amount)
            lines.append(CSV.line([
                e.id, e.product, price, e.category, e.vendor, e.savedBy, e.quantity,
                e.date.map { f.string(from: $0) } ?? ""
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct DateParser {
    private let formatters: [DateFormatter]
    private let iso = ISO8601DateFormatter()

    init(timeZone: TimeZone) {
        let formats = [
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
            "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy",
            "dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy", "d MMM yyyy", "d MMM yyyy HH:mm"
        ]
        formatters = formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = fmt
            f.isLenient = false
            return f
        }
    }

    func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("0000") { return nil }
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return iso.date(from: s)
    }
}

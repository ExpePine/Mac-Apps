import Foundation

public struct Bucket: Identifiable, Hashable {
    public var id: String { key }
    public let key: String
    public let total: Double
    public let count: Int
    public init(key: String, total: Double, count: Int) {
        self.key = key
        self.total = total
        self.count = count
    }
}

public struct MonthPoint: Identifiable, Hashable {
    public var id: Date { month }
    public let month: Date
    public let total: Double
    public let count: Int
}

public struct DayPoint: Identifiable, Hashable {
    public var id: Date { day }
    public let day: Date
    public let total: Double
    public let cumulative: Double
}

public struct CategoryChange: Identifiable, Hashable {
    public var id: String { category }
    public let category: String
    public let current: Double
    public let previous: Double
    public var change: Double { current - previous }
    /// nil when there was no spending in the previous period.
    public var percent: Double? { previous > 0 ? (current - previous) / previous * 100 : nil }
}

/// The period the whole app is looking at.
public enum Period: Hashable, Identifiable {
    case all
    case lastDays(Int)
    case month(year: Int, month: Int)

    public var id: String { tag }

    public var tag: String {
        switch self {
        case .all: return "all"
        case .lastDays(let n): return "last\(n)"
        case .month(let y, let m): return String(format: "m:%04d-%02d", y, m)
        }
    }

    public init?(tag: String) {
        if tag == "all" { self = .all; return }
        if tag.hasPrefix("last"), let n = Int(tag.dropFirst(4)) { self = .lastDays(n); return }
        if tag.hasPrefix("m:") {
            let parts = tag.dropFirst(2).split(separator: "-")
            if parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) {
                self = .month(year: y, month: m)
                return
            }
        }
        return nil
    }

    public var label: String {
        switch self {
        case .all: return "All time"
        case .lastDays(let n): return "Last \(n) days"
        case .month(let y, let m):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MMMM yyyy"
            var c = DateComponents()
            c.year = y; c.month = m; c.day = 15
            let d = Calendar(identifier: .gregorian).date(from: c) ?? Date()
            return f.string(from: d)
        }
    }

    public var comparisonLabel: String {
        switch self {
        case .all: return ""
        case .lastDays(let n): return "the \(n) days before"
        case .month: return "the previous month"
        }
    }
}

public struct Analyzer {
    public var calendar: Calendar

    public init(calendar: Calendar = Analyzer.makeCalendar()) {
        self.calendar = calendar
    }

    public static func makeCalendar(timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2   // Monday
        c.locale = Locale(identifier: "en_IN")
        return c
    }

    // MARK: Periods

    public func interval(for period: Period, now: Date = Date()) -> DateInterval? {
        switch period {
        case .all:
            return nil
        case .lastDays(let n):
            let todayStart = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: todayStart),
                  let start = calendar.date(byAdding: .day, value: -(n - 1), to: todayStart) else { return nil }
            return DateInterval(start: start, end: end)
        case .month(let y, let m):
            var c = DateComponents()
            c.year = y; c.month = m; c.day = 1
            guard let start = calendar.date(from: c),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    public func previousInterval(for period: Period, now: Date = Date()) -> DateInterval? {
        guard let current = interval(for: period, now: now) else { return nil }
        switch period {
        case .all:
            return nil
        case .lastDays(let n):
            guard let start = calendar.date(byAdding: .day, value: -n, to: current.start) else { return nil }
            return DateInterval(start: start, end: current.start)
        case .month:
            guard let start = calendar.date(byAdding: .month, value: -1, to: current.start) else { return nil }
            return DateInterval(start: start, end: current.start)
        }
    }

    /// Months that have data, newest first.
    public func months(in expenses: [Expense]) -> [Period] {
        var set = Set<Period>()
        for e in expenses {
            guard let d = e.date else { continue }
            let c = calendar.dateComponents([.year, .month], from: d)
            if let y = c.year, let m = c.month { set.insert(.month(year: y, month: m)) }
        }
        return set.sorted { $0.tag > $1.tag }
    }

    public func period(containing date: Date) -> Period {
        let c = calendar.dateComponents([.year, .month], from: date)
        return .month(year: c.year ?? 2000, month: c.month ?? 1)
    }

    /// nil interval = everything, including undated rows.
    public func filter(_ expenses: [Expense], in interval: DateInterval?) -> [Expense] {
        guard let iv = interval else { return expenses }
        return expenses.filter { e in
            guard let d = e.date else { return false }
            return d >= iv.start && d < iv.end
        }
    }

    /// Days used for "average per day": an in-progress period only counts days so far.
    public func dayCount(for interval: DateInterval?, expenses: [Expense], now: Date = Date()) -> Int {
        if let iv = interval {
            let end = min(iv.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? iv.end)
            let days = calendar.dateComponents([.day], from: iv.start, to: max(end, iv.start)).day ?? 0
            return max(1, days)
        }
        let dates = expenses.compactMap(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return 1 }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lo), to: calendar.startOfDay(for: hi)).day ?? 0
        return days + 1
    }

    // MARK: Aggregates

    public static func total(_ expenses: [Expense]) -> Double {
        expenses.reduce(0) { $0 + $1.amount }
    }

    public func group(_ expenses: [Expense], by key: (Expense) -> String) -> [Bucket] {
        var totals: [String: (Double, Int)] = [:]
        for e in expenses {
            let k = key(e)
            let cur = totals[k] ?? (0, 0)
            totals[k] = (cur.0 + e.amount, cur.1 + 1)
        }
        return totals.map { Bucket(key: $0.key, total: $0.value.0, count: $0.value.1) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.key < $1.key }
    }

    public func byCategory(_ e: [Expense]) -> [Bucket] { group(e) { $0.category } }
    public func byVendor(_ e: [Expense]) -> [Bucket] { group(e) { $0.vendorLabel } }
    public func byPerson(_ e: [Expense]) -> [Bucket] { group(e) { $0.personLabel } }

    /// One point per calendar month from the first to the last dated month (gaps filled with 0).
    public func monthly(_ expenses: [Expense]) -> [MonthPoint] {
        var totals: [Date: (Double, Int)] = [:]
        for e in expenses {
            guard let d = e.date, let m = calendar.dateInterval(of: .month, for: d)?.start else { continue }
            let cur = totals[m] ?? (0, 0)
            totals[m] = (cur.0 + e.amount, cur.1 + 1)
        }
        guard let first = totals.keys.min(), let last = totals.keys.max() else { return [] }
        var out: [MonthPoint] = []
        var m = first
        while m <= last {
            let v = totals[m] ?? (0, 0)
            out.append(MonthPoint(month: m, total: v.0, count: v.1))
            guard let next = calendar.date(byAdding: .month, value: 1, to: m) else { break }
            m = next
        }
        return out
    }

    /// One point per day in the interval (or across the data when nil), with a running total.
    public func daily(_ expenses: [Expense], in interval: DateInterval?, now: Date = Date()) -> [DayPoint] {
        var totals: [Date: Double] = [:]
        for e in expenses {
            guard let d = e.date else { continue }
            totals[calendar.startOfDay(for: d), default: 0] += e.amount
        }
        let start: Date
        var end: Date
        if let iv = interval {
            start = iv.start
            end = iv.end
            // Don't draw empty future days of the current month.
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), tomorrow < end {
                end = max(tomorrow, start)
            }
        } else {
            guard let lo = totals.keys.min(), let hi = totals.keys.max() else { return [] }
            start = lo
            end = calendar.date(byAdding: .day, value: 1, to: hi) ?? hi
        }
        var out: [DayPoint] = []
        var day = calendar.startOfDay(for: start)
        var running = 0.0
        var guardCount = 0
        while day < end && guardCount < 2000 {
            let v = totals[day] ?? 0
            running += v
            out.append(DayPoint(day: day, total: v, cumulative: running))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardCount += 1
        }
        return out
    }

    public static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Spending per weekday, Monday first; every weekday is present.
    public func weekday(_ expenses: [Expense]) -> [Bucket] {
        var totals = Array(repeating: 0.0, count: 7)
        var counts = Array(repeating: 0, count: 7)
        for e in expenses {
            guard let d = e.date else { continue }
            let wd = calendar.component(.weekday, from: d)   // 1 = Sunday
            let i = (wd + 5) % 7                              // Monday = 0
            totals[i] += e.amount
            counts[i] += 1
        }
        return (0..<7).map { Bucket(key: Analyzer.weekdayNames[$0], total: totals[$0], count: counts[$0]) }
    }

    static func productKey(_ name: String) -> String {
        var s = name.lowercased()
        while s.hasSuffix(".") || s.hasSuffix("…") { s.removeLast() }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func displayName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(".") || s.hasSuffix("…") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    public enum ProductRank { case spend, count }

    /// Products grouped by name (truncated "Amul Taaza Toned ..." merges with "Amul Taaza Toned").
    public func topProducts(_ expenses: [Expense], limit: Int = 10, by rank: ProductRank = .spend) -> [Bucket] {
        var totals: [String: (name: String, total: Double, count: Int)] = [:]
        for e in expenses {
            let k = Analyzer.productKey(e.product)
            if k.isEmpty { continue }
            var cur = totals[k] ?? (Analyzer.displayName(e.product), 0, 0)
            cur.total += e.amount
            cur.count += 1
            totals[k] = cur
        }
        let buckets = totals.values.map { Bucket(key: $0.name, total: $0.total, count: $0.count) }
        let sorted: [Bucket]
        switch rank {
        case .spend:
            sorted = buckets.sorted { $0.total != $1.total ? $0.total > $1.total : $0.key < $1.key }
        case .count:
            sorted = buckets.sorted { $0.count != $1.count ? $0.count > $1.count : $0.total > $1.total }
        }
        return Array(sorted.prefix(limit))
    }

    public func categoryChanges(current: [Expense], previous: [Expense]) -> [CategoryChange] {
        var cur: [String: Double] = [:]
        var prev: [String: Double] = [:]
        for e in current { cur[e.category, default: 0] += e.amount }
        for e in previous { prev[e.category, default: 0] += e.amount }
        let keys = Set(cur.keys).union(prev.keys)
        return keys.map { CategoryChange(category: $0, current: cur[$0] ?? 0, previous: prev[$0] ?? 0) }
            .sorted { abs($0.change) > abs($1.change) }
    }

    /// Projected total for a month that is still in progress; nil otherwise.
    public func projection(for period: Period, expenses: [Expense], now: Date = Date()) -> Double? {
        guard case .month = period, let iv = interval(for: period, now: now), iv.contains(now) else { return nil }
        let elapsed = dayCount(for: iv, expenses: expenses, now: now)
        let total = calendar.dateComponents([.day], from: iv.start, to: iv.end).day ?? 30
        guard elapsed >= 3, elapsed < total else { return nil }
        return Analyzer.total(expenses) / Double(elapsed) * Double(total)
    }
}

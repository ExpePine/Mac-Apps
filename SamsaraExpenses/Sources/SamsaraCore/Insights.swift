import Foundation

public struct Insight: Identifiable, Hashable {
    public enum Tone: String { case info, good, warning }
    public var id: String { title + "|" + detail }
    public let symbol: String     // SF Symbol name
    public let title: String
    public let detail: String
    public let tone: Tone
}

extension Analyzer {

    /// Plain-language findings for the selected period, most useful first.
    public func insights(all: [Expense], period: Period, now: Date = Date()) -> [Insight] {
        let iv = interval(for: period, now: now)
        let current = filter(all, in: iv)
        let previous = previousInterval(for: period, now: now).map { filter(all, in: $0) } ?? []
        let total = Analyzer.total(current)
        var out: [Insight] = []
        guard !current.isEmpty else {
            return [Insight(symbol: "tray", title: "No spending in \(period.label)",
                            detail: "Pick another period, or sync to fetch the latest Samsara data.", tone: .info)]
        }

        // 1. Total vs previous period
        let prevTotal = Analyzer.total(previous)
        if prevTotal > 0 {
            let pct = (total - prevTotal) / prevTotal * 100
            let up = pct >= 0
            out.append(Insight(
                symbol: up ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill",
                title: "\(Money.format(total)) spent, \(Money.percent(abs(pct))) \(up ? "more" : "less") than \(period.comparisonLabel)",
                detail: "\(Analyzer.capitalizeFirst(period.comparisonLabel)): \(Money.format(prevTotal)). Difference: \(Money.format(abs(total - prevTotal))).",
                tone: up ? .warning : .good))
        } else {
            out.append(Insight(symbol: "indianrupeesign.circle.fill",
                               title: "\(Money.format(total)) spent across \(current.count) items",
                               detail: "Average \(Money.format(total / Double(dayCount(for: iv, expenses: current, now: now)))) per day.",
                               tone: .info))
        }

        // 2. Month-end projection
        if let proj = projection(for: period, expenses: current, now: now) {
            var detail = "Based on \(Money.format(total / Double(dayCount(for: iv, expenses: current, now: now)))) per day so far."
            if prevTotal > 0 {
                let pct = (proj - prevTotal) / prevTotal * 100
                detail += " That is \(Money.percent(abs(pct))) \(pct >= 0 ? "above" : "below") last month."
            }
            out.append(Insight(symbol: "chart.line.uptrend.xyaxis",
                               title: "On this pace the month ends near \(Money.format(proj))",
                               detail: detail, tone: prevTotal > 0 && proj > prevTotal ? .warning : .info))
        }

        // 3. Biggest category
        let cats = byCategory(current)
        if let top = cats.first, total > 0 {
            var detail = "\(top.count) items."
            if cats.count > 1 {
                let second = cats[1]
                detail += " Next: \(second.key) at \(Money.format(second.total)) (\(Money.percent(second.total / total * 100)))."
            }
            out.append(Insight(symbol: "chart.pie.fill",
                               title: "\(top.key) is the biggest category: \(Money.format(top.total)) (\(Money.percent(top.total / total * 100)))",
                               detail: detail, tone: .info))
        }

        // 4. Category movers vs previous period
        if !previous.isEmpty {
            let changes = categoryChanges(current: current, previous: previous)
            let ups = changes.filter { $0.change >= 200 && ($0.percent ?? 100) >= 20 }
                .sorted { $0.change > $1.change }.prefix(2)
            for c in ups {
                let pctText = c.percent.map { " (+\(Money.percent($0)))" } ?? " (new this period)"
                out.append(Insight(symbol: "arrow.up.circle",
                                   title: "\(c.category) up \(Money.format(c.change))\(pctText)",
                                   detail: "\(Money.format(c.current)) now vs \(Money.format(c.previous)) in \(period.comparisonLabel).",
                                   tone: .warning))
            }
            if let down = changes.filter({ $0.change <= -200 }).sorted(by: { $0.change < $1.change }).first {
                out.append(Insight(symbol: "arrow.down.circle",
                                   title: "\(down.category) down \(Money.format(-down.change))",
                                   detail: "\(Money.format(down.current)) now vs \(Money.format(down.previous)) in \(period.comparisonLabel).",
                                   tone: .good))
            }
        }

        // 5. Eating out / food delivery
        let foodOut = current.filter(Analyzer.isFoodOut)
        let foodTotal = Analyzer.total(foodOut)
        if foodTotal > 0 && total > 0 {
            out.append(Insight(symbol: "fork.knife.circle.fill",
                               title: "Eating out and food delivery: \(Money.format(foodTotal)) (\(Money.percent(foodTotal / total * 100)))",
                               detail: "\(foodOut.count) orders, average \(Money.format(foodTotal / Double(foodOut.count))) each.",
                               tone: foodTotal / total > 0.25 ? .warning : .info))
        }

        // 6. Main vendor
        let vendors = byVendor(current).filter { $0.key != "Not set" }
        if let v = vendors.first, total > 0 {
            out.append(Insight(symbol: "bag.fill",
                               title: "Most spending through \(v.key): \(Money.format(v.total))",
                               detail: "\(v.count) items, \(Money.percent(v.total / total * 100)) of the period. \(vendors.count) vendors used in total.",
                               tone: .info))
        }

        // 7. Biggest single purchase
        if let big = current.max(by: { $0.amount < $1.amount }), big.amount > 0 {
            out.append(Insight(symbol: "exclamationmark.circle",
                               title: "Biggest single entry: \(big.product) \(Money.exactFormat(big.amount))",
                               detail: "\(big.category)\(big.vendor.isEmpty ? "" : " · " + big.vendor)\(big.date.map { " · " + Analyzer.dayFormatter(calendar).string(from: $0) } ?? "").",
                               tone: .info))
        }

        // 8. Busiest day
        let days = daily(current, in: iv, now: now)
        if let busy = days.max(by: { $0.total < $1.total }), busy.total > 0, days.count > 1 {
            let n = current.filter { $0.date.map { calendar.isDate($0, inSameDayAs: busy.day) } ?? false }.count
            out.append(Insight(symbol: "calendar.badge.exclamationmark",
                               title: "Busiest day: \(Analyzer.dayFormatter(calendar).string(from: busy.day)), \(Money.format(busy.total))",
                               detail: "\(n) entries that day. \(days.filter { $0.total == 0 }.count) of \(days.count) days had no spending.",
                               tone: .info))
        }

        // 9. Most repeated item
        if let rep = topProducts(current, limit: 1, by: .count).first, rep.count >= 3 {
            out.append(Insight(symbol: "repeat.circle",
                               title: "Bought most often: \(rep.key) (\(rep.count)×)",
                               detail: "\(Money.format(rep.total)) in total.", tone: .info))
        }

        // 10. Who logged what
        let people = byPerson(current)
        if people.count >= 2, total > 0 {
            let parts = people.prefix(3).map { "\($0.key) \(Money.format($0.total)) (\(Money.percent($0.total / total * 100)))" }
            out.append(Insight(symbol: "person.2.fill", title: "Entries by person",
                               detail: parts.joined(separator: " · "), tone: .info))
        }

        // 11. Data quality
        let uncategorized = current.filter { $0.category.lowercased() == "uncategorized" }
        if !uncategorized.isEmpty {
            out.append(Insight(symbol: "tag.slash",
                               title: "\(uncategorized.count) items (\(Money.format(Analyzer.total(uncategorized)))) are Uncategorized",
                               detail: "Tag them in Samsara to make the category breakdown more accurate.",
                               tone: .warning))
        }
        if case .all = period {
            let undated = all.filter { $0.date == nil }
            if !undated.isEmpty {
                out.append(Insight(symbol: "calendar.badge.minus",
                                   title: "\(undated.count) entries have no date",
                                   detail: "They count in All time totals (\(Money.format(Analyzer.total(undated)))) but not in monthly or daily charts.",
                                   tone: .warning))
            }
        }
        return out
    }

    public static func isFoodOut(_ e: Expense) -> Bool {
        let c = e.category.lowercased()
        let v = e.vendor.lowercased()
        return c.contains("eat") || c.contains("zomato") || c.contains("food-delivery") || c.contains("swiggy")
            || c.contains("restaurant") || v == "zomato" || v == "swiggy"
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + String(s.dropFirst())
    }

    static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEE d MMM"
        return f
    }
}

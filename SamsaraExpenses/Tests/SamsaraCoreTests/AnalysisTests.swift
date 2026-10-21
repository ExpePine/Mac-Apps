import XCTest
@testable import SamsaraCore

final class AnalysisTests: XCTestCase {
    let ist = TimeZone(identifier: "Asia/Kolkata")!
    lazy var analyzer = Analyzer(calendar: Analyzer.makeCalendar(timeZone: ist))

    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ist
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func e(_ id: String, _ amount: Double, _ cat: String, _ when: String?, vendor: String = "", by: String = "Dona", product: String? = nil) -> Expense {
        Expense(id: id, product: product ?? "Item \(id)", amount: amount, category: cat, vendor: vendor,
                savedBy: by, quantity: "1", date: when.map(date), rawPrice: String(amount))
    }

    lazy var data: [Expense] = [
        e("1", 100, "Dairy", "2026-09-01 10:00", vendor: "Zepto"),
        e("2", 300, "Eat-Out", "2026-09-15 21:00"),
        e("3", 50, "Dairy", "2026-10-01 00:30", vendor: "Zepto"),          // just after midnight IST
        e("4", 500, "FUEL", "2026-10-03 09:00", by: "Raja"),
        e("5", 250, "Eat-Out", "2026-10-03 20:00", vendor: "Zomato"),
        e("6", 20, "Beverages", nil),                                       // undated
        e("7", 1000, "Rent", "2026-07-05 10:00"),
    ]

    func testMonthIntervalUsesLocalTimeZone() {
        let iv = analyzer.interval(for: .month(year: 2026, month: 10))!
        XCTAssertEqual(iv.start, date("2026-10-01 00:00"))
        XCTAssertEqual(iv.end, date("2026-11-01 00:00"))
        let oct = analyzer.filter(data, in: iv)
        XCTAssertEqual(Set(oct.map(\.id)), ["3", "4", "5"])
        XCTAssertEqual(Analyzer.total(oct), 800)
    }

    func testPreviousMonth() {
        let prev = analyzer.previousInterval(for: .month(year: 2026, month: 10))!
        XCTAssertEqual(prev.start, date("2026-09-01 00:00"))
        XCTAssertEqual(Analyzer.total(analyzer.filter(data, in: prev)), 400)
    }

    func testLastDays() {
        let now = date("2026-10-03 22:00")
        let iv = analyzer.interval(for: .lastDays(3), now: now)!
        XCTAssertEqual(iv.start, date("2026-10-01 00:00"))
        XCTAssertEqual(iv.end, date("2026-10-04 00:00"))
        let prev = analyzer.previousInterval(for: .lastDays(3), now: now)!
        XCTAssertEqual(prev.start, date("2026-09-28 00:00"))
        XCTAssertEqual(prev.end, iv.start)
    }

    func testAllIncludesUndated() {
        XCTAssertEqual(analyzer.filter(data, in: nil).count, data.count)
        XCTAssertEqual(Analyzer.total(data), 2220)
    }

    func testCategoryVendorPerson() {
        let cats = analyzer.byCategory(data)
        XCTAssertEqual(cats.first?.key, "Rent")
        XCTAssertEqual(cats.first(where: { $0.key == "Eat-Out" })?.total, 550)
        XCTAssertEqual(cats.first(where: { $0.key == "Dairy" })?.count, 2)
        XCTAssertEqual(analyzer.byVendor(data).first(where: { $0.key == "Not set" })?.count, 4)
        XCTAssertEqual(analyzer.byPerson(data).first(where: { $0.key == "Raja" })?.total, 500)
    }

    func testMonthlyFillsGaps() {
        let m = analyzer.monthly(data)
        XCTAssertEqual(m.map(\.total), [1000, 0, 400, 800])   // Jul, Aug (empty), Sep, Oct
        XCTAssertEqual(m.map(\.count), [1, 0, 2, 3])
    }

    func testDailyCumulativeAndNoFutureDays() {
        let iv = analyzer.interval(for: .month(year: 2026, month: 10))!
        let now = date("2026-10-05 12:00")
        let d = analyzer.daily(analyzer.filter(data, in: iv), in: iv, now: now)
        XCTAssertEqual(d.count, 5)                       // Oct 1…5, nothing after "today"
        XCTAssertEqual(d.map(\.total), [50, 0, 750, 0, 0])
        XCTAssertEqual(d.last?.cumulative, 800)
    }

    func testWeekday() {
        let w = analyzer.weekday(data)
        XCTAssertEqual(w.count, 7)
        XCTAssertEqual(w.map(\.key).first, "Mon")
        XCTAssertEqual(w.reduce(0) { $0 + $1.total }, 2200)   // undated row excluded
        // 2026-10-03 is a Saturday.
        XCTAssertEqual(w[5].total, 750)
    }

    func testTopProductsMergesTruncatedNames() {
        let items = [
            e("a", 34, "Dairy", "2026-10-01 10:00", product: "Amul Taaza Toned ..."),
            e("b", 34, "Dairy", "2026-10-02 10:00", product: "Amul Taaza Toned"),
            e("c", 10, "Snack", "2026-10-02 10:00", product: "Chips"),
        ]
        let top = analyzer.topProducts(items, limit: 5, by: .count)
        XCTAssertEqual(top.first?.count, 2)
        XCTAssertEqual(top.first?.total, 68)
        XCTAssertEqual(top.first?.key, "Amul Taaza Toned")
    }

    func testProjection() {
        let now = date("2026-10-10 12:00")
        let oct = analyzer.filter(data, in: analyzer.interval(for: .month(year: 2026, month: 10)))
        let p = analyzer.projection(for: .month(year: 2026, month: 10), expenses: oct, now: now)
        XCTAssertEqual(p!, 800.0 / 10.0 * 31.0, accuracy: 0.01)
        XCTAssertNil(analyzer.projection(for: .month(year: 2026, month: 9), expenses: oct, now: now))
    }

    func testPeriodTags() {
        for p in [Period.all, .lastDays(30), .month(year: 2026, month: 3)] {
            XCTAssertEqual(Period(tag: p.tag), p)
        }
        XCTAssertEqual(analyzer.months(in: data).first, .month(year: 2026, month: 10))
        XCTAssertEqual(Period.month(year: 2026, month: 10).label, "October 2026")
    }

    func testInsights() {
        let now = date("2026-10-10 12:00")
        let ins = analyzer.insights(all: data, period: .month(year: 2026, month: 10), now: now)
        XCTAssertFalse(ins.isEmpty)
        XCTAssertTrue(ins[0].title.contains("more than the previous month"))   // 800 vs 400
        XCTAssertTrue(ins.contains { $0.title.hasPrefix("FUEL is the biggest category") })
        XCTAssertTrue(ins.contains { $0.title.hasPrefix("Eating out and food delivery") })
        let empty = analyzer.insights(all: data, period: .month(year: 2025, month: 1), now: now)
        XCTAssertEqual(empty.count, 1)
        let all = analyzer.insights(all: data, period: .all, now: now)
        XCTAssertTrue(all.contains { $0.title.contains("have no date") })
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Money.compact(130_000), "₹1.3L")
        XCTAssertEqual(Money.compact(4_500), "₹4.5K")
        XCTAssertEqual(Money.compact(980), "₹980")
        XCTAssertTrue(Money.format(123456).hasPrefix("₹"))
    }
}

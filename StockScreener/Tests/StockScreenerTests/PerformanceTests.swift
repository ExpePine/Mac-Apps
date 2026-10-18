import XCTest
@testable import StockScreener

final class PerformanceTests: XCTestCase {
    private func days(_ n: Int) -> [String] {
        let start = HistoryStore.date(fromKey: "2026-01-01")!
        return (0..<n).map { HistoryStore.dayKey(Calendar.current.date(byAdding: .day, value: $0, to: start)!) }
    }

    func testEventTradingDaysAgoAndReturns() {
        // 11 days: 100 → rises to 150 on day 6 → 130 now
        let d = days(11)
        let closes: [Double] = [90, 100, 105, 110, 120, 140, 150, 145, 135, 130, 130]
        var book = PriceBook()
        book.series["ABC"] = PriceSeries(days: d, closes: closes)
        book.series["^NSEI"] = PriceSeries(days: d, closes: Array(repeating: 1000, count: 10) + [1100])
        var study = PerfStudy()
        study.successPercent = 20
        study.horizons = [2, 5, 20]
        // Event 9 trading days before the reference (last) day → index 1 (close 100)
        let r = PerfEngine.analyze([PerfEvent(symbol: "ABC", value: "9", group: nil)], book: book, refDay: d[10], study: study)
        XCTAssertEqual(r.rows.count, 1)
        let row = r.rows[0]
        XCTAssertEqual(row.eventDay, d[1])
        XCTAssertEqual(row.entry, 100)
        XCTAssertEqual(row.returnNow, 30, accuracy: 1e-9)
        XCTAssertEqual(row.peak, 50, accuracy: 1e-9)
        XCTAssertEqual(row.daysToPeak, 5)
        XCTAssertEqual(row.hitDays, 3)                         // 120 ≥ +20% on the 3rd day after
        XCTAssertEqual(row.horizons[0]!, 10, accuracy: 1e-9)   // +2 days: 110
        XCTAssertEqual(row.horizons[1]!, 40, accuracy: 1e-9)   // +5 days: 140
        XCTAssertNil(row.horizons[2])                          // not reached yet
        XCTAssertEqual(row.benchmark!, 10, accuracy: 1e-9)
        XCTAssertEqual(row.excess!, 20, accuracy: 1e-9)
        XCTAssertEqual(row.worst, 0, accuracy: 1e-9)
    }

    func testCalendarDaysAndDates() {
        let d = days(30)
        let s = PriceSeries(days: d, closes: (0..<30).map { Double(100 + $0) })
        XCTAssertEqual(PerfEngine.eventIndex("10", series: s, refDay: d[29], unit: .calendarDays), 19)
        XCTAssertEqual(PerfEngine.eventIndex("2026-01-05", series: s, refDay: d[29], unit: .dates), 4)
        XCTAssertNil(PerfEngine.eventIndex("500", series: s, refDay: d[29], unit: .tradingDays))   // before history
        XCTAssertNil(PerfEngine.eventIndex("", series: s, refDay: d[29], unit: .tradingDays))
    }

    func testGroupLabels() {
        let nums = (1...30).map(String.init)
        let labels = PerfEngine.groupLabels(nums)
        XCTAssertTrue(labels[0].hasPrefix("Low"))
        XCTAssertTrue(labels[29].hasPrefix("High"))
        XCTAssertEqual(PerfEngine.groupLabels(["IT", "Bank", "", "IT"]), ["IT", "Bank", "(blank)", "IT"])
    }

    func testStudyDecodesPartialJSON() throws {
        let s = try JSONDecoder().decode(PerfStudy.self, from: Data(#"{"column":"X","successPercent":30}"#.utf8))
        XCTAssertEqual(s.column, "X")
        XCTAssertEqual(s.successPercent, 30)
        XCTAssertEqual(s.unit, .tradingDays)
    }
}

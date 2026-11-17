import XCTest
@testable import StockScreener

final class GainerPeriodTests: XCTestCase {
    // Thu 30 Oct, Fri 31 Oct, Mon 3 Nov … Fri 7 Nov 2025
    private let s = PriceSeries(days: ["2025-10-30", "2025-10-31", "2025-11-03", "2025-11-04", "2025-11-05", "2025-11-06", "2025-11-07"],
                                closes: [100, 100, 110, 110, 110, 110, 121])

    func testDaily() {
        XCTAssertEqual(GainerPeriod.daily.change(s, on: "2025-11-07", calendar: false)!, 10, accuracy: 1e-9)
    }

    func testWeeklyRolling() {    // 5 trading days back = 31 Oct (100) → 121
        XCTAssertEqual(GainerPeriod.weekly.change(s, on: "2025-11-07", calendar: false)!, 21, accuracy: 1e-9)
    }

    func testWeekToDate() {       // week began Mon 3 Nov → base = Fri 31 Oct close
        XCTAssertEqual(GainerPeriod.weekly.change(s, on: "2025-11-04", calendar: true)!, 10, accuracy: 1e-9)
    }

    func testMonthToDate() {      // November → base = 31 Oct close
        XCTAssertEqual(GainerPeriod.monthly.change(s, on: "2025-11-07", calendar: true)!, 21, accuracy: 1e-9)
        XCTAssertNil(GainerPeriod.monthly.change(s, on: "2025-11-07", calendar: false))   // needs 21 trading days
    }
}

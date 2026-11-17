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

final class GainerUniverseTests: XCTestCase {
    func testIndexCSV() {
        let csv = "Company Name,Industry,Symbol,Series,ISIN Code\nReliance Industries Ltd.,Oil,RELIANCE,EQ,INE002A01018\nTCS,IT,TCS,EQ,INE467B01029\n"
        XCTAssertEqual(UniverseStore.symbols(fromCSV: csv), ["RELIANCE", "TCS"])
    }
    func testMcapCSV() {
        let csv = "Trade Date,Symbol,Series,Security Name,Category,Last Trade Date,Face Value(Rs.),Issue Size,Close Price,Market Cap(Rs.)\n17-Nov-2026,ABC,EQ,ABC Ltd,Listed,17-Nov-2026,10,1000000,250,250000000\n17-Nov-2026,XYZ,N1,XYZ bond,Listed,17-Nov-2026,100,5,100,500\n17-Nov-2026,DEF,EQ,DEF Ltd,Listed,17-Nov-2026,10,,50,500000000\n"
        let t = UniverseStore.parseMcap(csv)
        XCTAssertEqual(t["ABC"], 1_000_000)
        XCTAssertNil(t["XYZ"])
        XCTAssertEqual(t["DEF"], 10_000_000)
    }
}

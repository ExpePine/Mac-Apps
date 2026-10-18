import XCTest
@testable import StockScreener

final class ToolsTests: XCTestCase {

    func testWatchReturns() {
        let s = PriceSeries(days: ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04"], closes: [100, 120, 110, 132])
        let nifty = PriceSeries(days: ["2026-09-01", "2026-09-04"], closes: [1000, 1100])
        let item = WatchItem(symbol: "ABC", addedDay: "2026-09-01", addedPrice: 100)
        let r = WatchReturns.compute(item, series: s, benchmark: nifty)
        XCTAssertEqual(r.now, 132)
        XCTAssertEqual(r.sinceAdded!, 32, accuracy: 1e-9)
        XCTAssertEqual(r.day1!, 20, accuracy: 1e-9)          // 110 → 132
        XCTAssertEqual(r.maxSinceAdded!, 32, accuracy: 1e-9)
        XCTAssertEqual(r.fromPeak!, 0, accuracy: 1e-9)
        XCTAssertEqual(r.benchmark!, 10, accuracy: 1e-9)
        XCTAssertEqual(r.tradingDays, 3)
        XCTAssertNil(r.month1)

        // No added price: uses the close on the added day
        let noPrice = WatchItem(symbol: "ABC", addedDay: "2026-09-02", addedPrice: nil)
        XCTAssertEqual(WatchReturns.compute(noPrice, series: s, benchmark: nil).sinceAdded!, 10, accuracy: 1e-9)
    }

    func testScreenshotFolderNames() {
        XCTAssertEqual(ScreenshotStore.safe(" m&m "), "M&M")
        XCTAssertEqual(ScreenshotStore.safe("BAJAJ-AUTO"), "BAJAJ-AUTO")
        XCTAssertEqual(ScreenshotStore.safe("A/B"), "A_B")
    }

    func testAnnotationRoundTrip() throws {
        let meta = ScreenshotMeta(note: "breakout", annotations: [
            Annotation(tool: .arrow, color: "#FF3B30", width: 4, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.6)]),
            Annotation(tool: .text, color: "#007AFF", width: 4, points: [CGPoint(x: 0.3, y: 0.3)], text: "Entry"),
        ])
        let back = try JSONDecoder().decode(ScreenshotMeta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(back.note, "breakout")
        XCTAssertEqual(back.annotations, meta.annotations)
    }

    func testYahooIndexSymbol() {
        XCTAssertEqual(YahooClient.yahooSymbol("^NSEI"), "%5ENSEI")
        XCTAssertEqual(YahooClient.yahooSymbol("tcs"), "TCS.NS")
    }

    @MainActor func testTableFinder() throws {
        let csv = "SYMBOL,SECTOR\nTCS,IT\nINFY,IT Services\nHDFC,Bank\n"
        let table = try SheetService.parse(Data(csv.utf8)).table
        let f = TableFinder()
        f.update(rows: table.rows, columns: [0, 1])
        f.show()
        f.query = "it"
        XCTAssertEqual(f.matches.count, 2)
        XCTAssertEqual(f.currentMatch, FindMatch(row: 0, column: 1))
        f.next()
        XCTAssertEqual(f.currentMatch, FindMatch(row: 1, column: 1))
        f.next()
        XCTAssertEqual(f.currentMatch, FindMatch(row: 0, column: 1))   // wraps
        f.query = "hdfc"
        XCTAssertEqual(f.currentMatch, FindMatch(row: 2, column: 0))
    }
}

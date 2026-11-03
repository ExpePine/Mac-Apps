import XCTest
@testable import StockScreener

final class WatchlistTests: XCTestCase {
    func testOldWatchlistJSONStillLoads() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","items":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","symbol":"TCS","addedAt":700000000,"addedDay":"2026-01-02","addedPrice":100,"priceSource":"Yahoo","note":"hi"}]}]
        """
        let lists = try JSONDecoder().decode([Watchlist].self, from: Data(json.utf8))
        XCTAssertEqual(lists.first?.items.first?.symbol, "TCS")
        XCTAssertEqual(lists.first?.items.first?.note, "hi")
        XCTAssertEqual(lists.first?.items.first?.tags, [])
        XCTAssertNil(lists.first?.items.first?.exitDay)
    }

    private func series(_ closes: [Double]) -> PriceSeries {
        let days = closes.indices.map { String(format: "2026-01-%02d", $0 + 1) }
        return PriceSeries(days: days, closes: closes)
    }

    func testReturnsForwardAndExit() {
        let s = series([100, 101, 102, 103, 104, 112, 90, 95])
        var it = WatchItem(symbol: "X", addedDay: "2026-01-01", addedPrice: 100)
        var r = WatchReturns.compute(it, series: s, benchmark: nil)
        XCTAssertEqual(r.sinceAdded!, -5, accuracy: 1e-9)
        XCTAssertEqual(r.fwd5!, 12, accuracy: 1e-9)
        XCTAssertEqual(r.daysTo10, 5)
        XCTAssertEqual(r.daysToMinus10, 6)
        XCTAssertEqual(r.maxSinceAdded!, 12, accuracy: 1e-9)
        XCTAssertEqual(r.worstSinceAdded!, -10, accuracy: 1e-9)
        it.exitDay = "2026-01-06"; it.exitPrice = 112
        r = WatchReturns.compute(it, series: s, benchmark: nil)
        XCTAssertEqual(r.sinceAdded!, 12, accuracy: 1e-9)
        XCTAssertNil(r.daysToMinus10)
    }

    func testCurveAveragesStocksFromTheirOwnStart() {
        var book = PriceBook()
        book.series["A"] = series([100, 110, 120])
        book.series["B"] = series([50, 50, 40])
        let a = WatchItem(symbol: "A", addedDay: "2026-01-01", addedPrice: 100)
        let b = WatchItem(symbol: "B", addedDay: "2026-01-02", addedPrice: 50)
        let c = WatchCurve.build([a, b], book: book, benchmark: "^NSEI")
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[0].value, 0, accuracy: 1e-9)                // only A
        XCTAssertEqual(c[1].value, 5, accuracy: 1e-9)                // A +10, B 0
        XCTAssertEqual(c[2].value, 0, accuracy: 1e-9)                // A +20, B −20
        XCTAssertEqual(c[2].drawdown, (1.0 / 1.05 - 1) * 100, accuracy: 1e-9)
    }
}

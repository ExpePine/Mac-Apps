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

final class ImpressionTests: XCTestCase {
    func testSpearmanPerfectAndReverse() {
        XCTAssertEqual(ImpressionReport.spearman([1, 2, 3, 4], [10, 20, 30, 40])!, 1, accuracy: 1e-9)
        XCTAssertEqual(ImpressionReport.spearman([1, 2, 3, 4], [4, 3, 2, 1])!, -1, accuracy: 1e-9)
    }

    func testReportCountsViewsTimeAndGainers() {
        var book = PriceBook()
        let days = (1...10).map { String(format: "2026-01-%02d", $0) }
        book.series["A"] = PriceSeries(days: days, closes: [100, 110, 110, 110, 110, 110, 110, 110, 110, 110])   // +10% on 01-02
        book.series["B"] = PriceSeries(days: days, closes: [100, 100, 100, 100, 100, 100, 100, 100, 100, 100])
        let d = Date()
        let v = [ChartImpression(symbol: "A", start: d, seconds: 30, place: "Chart viewer", day: "2026-01-02"),
                 ChartImpression(symbol: "A", start: d, seconds: 90, place: "Chart Reel", day: "2026-01-02"),
                 ChartImpression(symbol: "B", start: d, seconds: 5, place: "Peek", day: "2026-01-02")]
        let r = ImpressionReport.build(v, book: book, threshold: 5, monthly: false)
        XCTAssertEqual(r.views, 3)
        XCTAssertEqual(r.seconds, 125, accuracy: 1e-9)
        XCTAssertEqual(r.stocks.first?.symbol, "A")
        XCTAssertEqual(r.stocks.first?.views, 2)
        XCTAssertEqual(r.lookedPairs, 2)
        XCTAssertEqual(r.lookedGainers, 1)
        XCTAssertEqual(r.periods.first?.marketGainers, 1)
        XCTAssertEqual(r.periods.first?.gainersSeen, 1)
    }
}

final class EarningsTests: XCTestCase {
    func testParseKeepsOnlyResults() {
        let a = EarningsMath.parse(["symbol": "TCS", "date": "12-Nov-2026", "purpose": "Financial Results/Dividend"])
        XCTAssertEqual(a?.day, "2026-11-12")
        XCTAssertNil(EarningsMath.parse(["symbol": "TCS", "date": "12-Nov-2026", "purpose": "Fund Raising"]))
        let b = EarningsMath.parse(["bm_symbol": "infy", "bm_date": "05-11-2026", "bm_purpose": "To consider quarterly results"])
        XCTAssertEqual(b?.symbol, "INFY"); XCTAssertEqual(b?.day, "2026-11-05")
    }

    func testPickSignedDays() {
        let ev = [EarningsEvent(symbol: "X", day: "2026-08-10", purpose: "Results"), EarningsEvent(symbol: "X", day: "2026-11-14", purpose: "Results")]
        XCTAssertEqual(EarningsMath.pick(ev, on: "2026-11-04")?.days, -10)     // 10 days to go
        XCTAssertEqual(EarningsMath.pick(ev, on: "2026-11-24")?.days, 10)      // 10 days past
        XCTAssertEqual(EarningsMath.pick(ev, on: "2026-11-14")?.days, 0)
    }
}

@MainActor final class EarningsSummaryTests: XCTestCase {
    func testPicksTheResultsFilingNotTheNotice() {
        let f = URL(string: "https://nsearchives.nseindia.com/corporate/x.pdf")
        let d = { (s: String) in EarningsSummaryCenter.parseDate(s)! }
        let ann = [
            NSEAnnouncement(date: d("2026-10-20 10:00:00"), desc: "Board Meeting Intimation", text: "Board meeting will be held to consider financial results", file: f),
            NSEAnnouncement(date: d("2026-11-03 18:00:00"), desc: "Outcome of Board Meeting", text: "Approved the unaudited financial results for the quarter ended Sep 30", file: f),
            NSEAnnouncement(date: d("2026-11-05 09:00:00"), desc: "Analysts/Institutional Investor Meet/Con. Call Updates", text: "Transcript of the earnings call", file: f),
        ]
        XCTAssertEqual(EarningsSummaryCenter.pickResults(ann)?.desc, "Outcome of Board Meeting")
        XCTAssertTrue(EarningsSummaryCenter.has(ann[2], ["transcript"]))
    }

    func testParseAnnouncementRow() {
        let a = EarningsSummaryCenter.parse(["sort_date": "2026-11-03 18:00:00", "desc": "Financial Results", "attchmntText": "Results", "attchmntFile": "https://nsearchives.nseindia.com/corporate/a.pdf"])
        XCTAssertEqual(a?.desc, "Financial Results")
        XCTAssertNotNil(a?.file)
    }
}

@MainActor final class EarningsFocusTests: XCTestCase {
    func testFocusKeepsNumberLinesWithinLimit() {
        let filler = String(repeating: "Lorem ipsum notes about the company and its auditors.\n", count: 200)
        let text = filler + "Revenue from operations 1,234.5 1,100.2\nNet profit for the period 210.4 190.1\n" + filler
        let f = EarningsSummaryCenter.focus(text, limit: 400)
        XCTAssertLessThanOrEqual(f.count, 400)
        XCTAssertTrue(f.contains("Revenue from operations"))
        XCTAssertTrue(f.contains("Net profit"))
    }
}

final class ResultsGrowthTests: XCTestCase {
    func testGrowthMath() {
        let g = ResultsGrowth(symbol: "X", resultsDay: "2026-11-03", period: "", basis: "consolidated", unit: "₹ crore",
                              rev: [120, 100, 110], pat: [12, -5, 10], made: Date())
        XCTAssertEqual(g.revYoY!, 20, accuracy: 1e-9)
        XCTAssertEqual(g.revQoQ!, 120.0 / 110 * 100 - 100, accuracy: 1e-9)
        XCTAssertNil(g.patYoY)                    // from a loss: no %
        XCTAssertEqual(g.patQoQ!, 20, accuracy: 1e-9)
    }
}

final class NSEResultsTests: XCTestCase {
    func testParseAndCompute() throws {
        let json = """
        {"resCmpData":[
          {"re_from_date":"01-JUL-2026","re_to_date":"30-SEP-2026","re_net_sale":"1,200.5","re_pro_loss_aft_tax":"150","re_con_type":"Consolidated"},
          {"re_from_date":"01-APR-2026","re_to_date":"30-JUN-2026","re_net_sale":"1,100","re_pro_loss_aft_tax":"120","re_con_type":"Consolidated"},
          {"re_from_date":"01-JUL-2025","re_to_date":"30-SEP-2025","re_net_sale":"1,000.5","re_pro_loss_aft_tax":"(50)","re_con_type":"Consolidated"},
          {"re_from_date":"01-JUL-2026","re_to_date":"30-SEP-2026","re_net_sale":"900","re_pro_loss_aft_tax":"90","re_con_type":"Standalone"}
        ]}
        """
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let q = NSEResults.parse(obj)
        XCTAssertEqual(q.count, 4)
        let g = try XCTUnwrap(NSEResults.compute("X", q))
        XCTAssertEqual(g.resultsDay, "2026-09-30")
        XCTAssertEqual(g.revYoY!, (1200.5 / 1000.5 - 1) * 100, accuracy: 1e-9)
        XCTAssertEqual(g.revQoQ!, (1200.5 / 1100 - 1) * 100, accuracy: 1e-9)
        XCTAssertNil(g.patYoY)                                 // year-ago was a loss
        XCTAssertEqual(g.patQoQ!, 25, accuracy: 1e-9)
    }
}

final class DelSmaCTests: XCTestCase {
    func testChangeNormalisedByItsHighest() throws {
        // raw series (DELIV_QTY×CLOSE with close = 1): steady +1% a day, one +5% day, then today +2.5%
        var q: [Double] = [100]
        for k in 1..<400 { q.append(q[k - 1] * (k == 200 ? 1.05 : 1.01)) }
        q.append(q.last! * 1.025)
        let days = q.indices.map { String(format: "D%04d", $0) }
        let s = DeliverySeries(days: days, qty: q, per: q.map { _ in 50 }, close: q.map { _ in 1 })
        let v = try XCTUnwrap(DeliveryColumns.delSmaC(s, at: q.count - 1, metric: .value, length: 300))
        XCTAssertEqual(v, 2.5 / 5.0, accuracy: 1e-9)
        // selected average: EMA 22 of it — must still be ≤ 1 and positive
        let e = try XCTUnwrap(DeliveryColumns.delSmaC(s, at: q.count - 1, metric: .ema22, length: 300))
        XCTAssertGreaterThan(e, 0); XCTAssertLessThanOrEqual(e, 1)
    }
}

final class Del2Tests: XCTestCase {
    func testDel2AndValueWhen() {
        // DELI rises to a high on day 5 (close 50), drifts lower, new high on day 9 (close 90)
        let qty: [Double] = [10, 12, 11, 13, 15, 30, 20, 18, 16, 40, 30]
        let close: [Double] = [10, 20, 30, 40, 45, 50, 60, 70, 80, 90, 100]
        let s = DeliverySeries(days: qty.indices.map { "D\($0)" }, qty: qty, per: qty.map { _ in 50 }, close: close)
        let r = Del2.series(s, length: 3, full: true)
        XCTAssertNil(r.del2[1])                                  // fewer than 3 bars
        XCTAssertEqual(r.del2[5]!, 100)                          // new 3-day high
        XCTAssertEqual(r.del2c[5]!, 50)
        XCTAssertEqual(r.del2c[7]!, 50)                          // still the last high's close
        XCTAssertEqual(r.del2[7]!, 1260.0 * 100 / 1500, accuracy: 1e-9)
        XCTAssertEqual(r.del2c[8]!, 80)                          // 1280 is the 3-day high again
        XCTAssertEqual(r.del2c[9]!, 90)
        XCTAssertEqual(r.del2c[10]!, 90)
    }

    func testRollingHighestMatchesNaive() {
        let x: [Double] = (0..<200).map { Double(($0 * 37) % 101) }
        let h = Del2.highest(x, 30, full: true)
        for i in 29..<x.count { XCTAssertEqual(h[i]!, x[(i - 29)...i].max()!) }
        XCTAssertNil(h[28])
    }
}

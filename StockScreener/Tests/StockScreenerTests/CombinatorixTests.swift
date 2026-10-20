import XCTest
@testable import StockScreener

final class CombinatorixTests: XCTestCase {

    /// 40 days × 200 stocks. Stocks with A = 1 AND B high rise 8% the next day; everyone else drifts.
    private func synthetic() -> CombiInput {
        var input = CombiInput()
        input.columns = ["A", "B", "C"]
        var rng = SeededRandom(seed: 3)
        let dayKeys = (0..<70).map { String(format: "2026-%03d", $0) }
        var closes: [String: [Double]] = [:]
        var days: [CombiDay] = []
        let symbols = (0..<200).map { "S\($0)" }
        for s in symbols { closes[s] = [100] }
        for t in 0..<60 {
            var vals: [Float] = []
            var winners = Set<String>()
            for s in symbols {
                let a: Float = Double.random(in: 0..<1, using: &rng) < 0.3 ? 1 : 0
                let b = Float(Double.random(in: 0..<100, using: &rng))
                let c = Float(Double.random(in: 0..<100, using: &rng))
                vals += [a, b, c]
                if a == 1 && b > 66 { winners.insert(s) }
            }
            days.append(CombiDay(day: dayKeys[t], symbols: symbols, values: vals, flags: Array(repeating: 0, count: symbols.count)))
            for s in symbols {
                let last = closes[s]!.last!
                let move = winners.contains(s) ? 1.08 : 1 + Double.random(in: -0.01...0.01, using: &rng)
                closes[s]!.append(last * move)
            }
        }
        // price series: close on dayKeys[t] is closes[t]; the next close is the result of day t's signals
        for s in symbols {
            var cl = closes[s]!
            while cl.count < 70 { cl.append(cl.last!) }
            input.book.series[s] = PriceSeries(days: dayKeys, closes: Array(cl.prefix(70)))
        }
        input.days = days
        input.thresholds = [.daily: 5, .weekly: 50, .monthly: 90]
        input.useContext = false
        input.useChanges = false
        return input
    }

    func testFindsThePlantedCombination() {
        let r = CombiEngine.mine(synthetic(), horizon: .daily)
        XCTAssertFalse(r.combos.isEmpty, r.note)
        let top = r.combos[0]
        XCTAssertTrue(top.text.contains("A = 1") && top.text.contains("B High"), top.text)
        XCTAssertGreaterThan(top.lift, 3)
        XCTAssertEqual(top.heldUp, true)
        XCTAssertFalse(r.combos.contains { $0.text.contains("C ") && $0.signals.count == 1 }, "C is noise")
        XCTAssertFalse(r.families.isEmpty)
    }

    func testFamilyNames() {
        let s = CombiSignal(name: "TG rising (5 days)", kind: .change, group: "C:TG", column: "TG", flavour: "rising")
        XCTAssertEqual(CombiEngine.familyName(s, .weekly), "Momentum Surge")
        let l = CombiSignal(name: "MS Low", kind: .level, group: "L:MS", column: "MS", flavour: "low")
        XCTAssertEqual(CombiEngine.familyName(l, .monthly), "Coiled Runner")
    }

    func testWilson() {
        XCTAssertEqual(CombiEngine.wilsonLower(0, 10), 0, accuracy: 1e-9)
        XCTAssertLessThan(CombiEngine.wilsonLower(5, 10), 0.5)
        XCTAssertGreaterThan(CombiEngine.wilsonLower(500, 1000), 0.46)
    }
}

final class DeliveryTests: XCTestCase {
    func testParseNSE() {
        let csv = """
        SYMBOL, SERIES, DATE1, PREV_CLOSE, OPEN_PRICE, HIGH_PRICE, LOW_PRICE, LAST_PRICE, CLOSE_PRICE, AVG_PRICE, TTL_TRD_QNTY, TURNOVER_LACS, NO_OF_TRADES, DELIV_QTY, DELIV_PER
        20MICRONS, EQ, 19-Oct-2026, 200.10, 201.00, 205.00, 199.00, 204.00, 204.50, 202.30, 150000, 303.45, 4000, 90000, 60.00
        ABC, BE, 19-Oct-2026, 10.00, 10.00, 10.50, 9.90, 10.20, 10.25, 10.10, 5000, 0.50, 40, -, -
        """
        let rows = NSEDeliveryClient.parse(Data(csv.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].symbol, "20MICRONS")
        XCTAssertEqual(rows[0].delivQty, 90000)
        XCTAssertEqual(rows[0].close, 204.5)
        XCTAssertEqual(rows[0].delivPer, 60)
        XCTAssertEqual(NSEDeliveryClient.fileName("2026-10-19"), "19102026")
    }

    func testHighestAndSignals() {
        let x: [Double] = [5, 3, 4, 6, 2, 1, 7, 1, 1, 1]
        let h = DeliverySignal.highest(x, length: 3, full: true)
        XCTAssertNil(h[1])
        XCTAssertEqual(h[2], 5); XCTAssertEqual(h[3], 6); XCTAssertEqual(h[5], 6); XCTAssertEqual(h[6], 7); XCTAssertEqual(h[9], 1)
        XCTAssertEqual(DeliverySignal.signals(x, length: 3, full: true, onlyRises: true), [3, 6])
        // any change also fires when an old high leaves the window
        XCTAssertEqual(DeliverySignal.signals(x, length: 3, full: true, onlyRises: false), [3, 6, 9])
        // same answer as a brute-force rolling max
        let y = (0..<500).map { _ in Double(Int.random(in: 0..<1000)) }
        let hy = DeliverySignal.highest(y, length: 50, full: false)
        for i in y.indices { XCTAssertEqual(hy[i], y[max(0, i - 49)...i].max()) }
    }
}

final class MultibaggerTests: XCTestCase {
    func testMonthlyEvents() {
        var b = PriceBook()
        // Dec 2022 ends at 100; Jan 2023 rises to 140 (cross on Jan 4 at 131); Feb 2023 flat
        b.series["ABC"] = PriceSeries(days: ["2022-12-29", "2022-12-30", "2023-01-02", "2023-01-03", "2023-01-04", "2023-01-31", "2023-02-01", "2023-02-28"],
                                      closes: [99, 100, 110, 120, 131, 140, 141, 142])
        b.series["XYZ"] = PriceSeries(days: ["2022-12-30", "2023-01-31"], closes: [100, 120])
        let e = MBEngine.events(b, threshold: 30, fromMonth: "2023-01", usePeak: false)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].symbol, "ABC")
        XCTAssertEqual(e[0].month, "2023-01")
        XCTAssertEqual(e[0].gain, 40, accuracy: 1e-9)
        XCTAssertEqual(e[0].baseDay, "2022-12-30")
        XCTAssertEqual(e[0].startDay, "2023-01-02")
        XCTAssertEqual(e[0].crossDay, "2023-01-04")
        XCTAssertEqual(e[0].peakDay, "2023-01-31")
        XCTAssertEqual(e[0].day(for: .cross), "2023-01-04")
        XCTAssertEqual(MBEngine.monthTitle("2024-03"), "Mar 2024")
        XCTAssertEqual(MultibaggerCenter.monthBefore("2023-01", 2), "2022-11")
    }
}

final class DeliveryColumnTests: XCTestCase {
    func testSafetyAndDLVR() {
        let days = (0..<320).map { String(format: "2025-%03d", $0) }
        var qty = [Double](repeating: 1000, count: 320)
        qty[319] = 5000                                    // a new 300-day high of qty×close on the last day
        let s = DeliverySeries(days: days, qty: qty, per: Array(repeating: 50, count: 320), close: Array(repeating: 100, count: 320))
        UserDefaults.standard.removeObject(forKey: "deliv.length")
        let c = DeliveryColumns.of(s, latestDay: days.last!)
        XCTAssertEqual(c.dlvr ?? 0, 5000 * 100 / 1e7, accuracy: 1e-9)
        XCTAssertEqual(c.safety ?? 0, (99 * 1000 + 5000) / 100 * 0.05, accuracy: 1e-9)
        // not the latest NSE day → no DLVR
        XCTAssertNil(DeliveryColumns.of(s, latestDay: "2099-01-01").dlvr)
        XCTAssertEqual(TVRange.day(TVRange.unix("2026-07-29")!), "2026-07-29")
    }
}

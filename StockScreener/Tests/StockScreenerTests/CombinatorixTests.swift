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

final class PercentRankTests: XCTestCase {
    func testPineStylePercentRank() {
        let x: [Double] = [1, 2, 3, 4, 5]
        XCTAssertNil(DeliveryColumns.percentRank(x, length: 5))                 // needs length + 1 bars
        XCTAssertEqual(DeliveryColumns.percentRank(x, length: 4), 100)          // all 4 previous ≤ 5
        XCTAssertEqual(DeliveryColumns.percentRank([5, 1, 9, 3, 4], length: 4), 50)   // 1 and 3 ≤ 4
        XCTAssertEqual(DeliveryColumns.percentRank([2, 2, 2], length: 2), 100)  // ties count
    }
}


final class DeliveryAsOfTests: XCTestCase {
    func testColumnsUseTheDataDayNotTheStocksLastRow() {
        // stock A traded on all 3 days; stock B stopped after day 1
        let a = DeliverySeries(days: ["2026-10-15", "2026-10-16", "2026-10-19"], qty: [1, 2, 3], per: [1, 1, 1], close: [1, 1, 1])
        let b = DeliverySeries(days: ["2026-10-15"], qty: [5], per: [1], close: [1])
        let book = DeliveryBook(days: ["2026-10-15", "2026-10-16", "2026-10-19"], series: ["A": a, "B": b])
        let cols = DeliveryColumns.all(book, asOf: "2026-10-19")
        XCTAssertEqual(cols["A"]?.day, "2026-10-19")
        XCTAssertNil(cols["B"]?.pctRank)            // no row on the data day → unknown, not an old value
        XCTAssertNil(cols["B"]?.safety)
        // a data day between NSE days uses the last NSE day before it
        XCTAssertEqual(DeliveryColumns.all(book, asOf: "2026-10-18")["A"]?.day, "2026-10-16")
        XCTAssertEqual(DeliveryColumns.index(of: "2026-10-16", in: a.days), 1)
        XCTAssertNil(DeliveryColumns.index(of: "2026-10-17", in: a.days))
    }
}

final class StockChangeTests: XCTestCase {
    func testByStock() {
        let prev = SheetTable(headers: ["Symbol", "Count", "Name"], rows: [
            SheetRow(id: 0, cells: ["TATAMOTORS", "4", "Tata"], numbers: [nil, 4, nil]),
            SheetRow(id: 1, cells: ["INFY", "7", "Infosys"], numbers: [nil, 7, nil]),
        ])
        let now = SheetTable(headers: ["Symbol", "Count", "Name"], rows: [
            SheetRow(id: 0, cells: ["TATAMOTORS", "5", "Tata"], numbers: [nil, 5, nil]),
            SheetRow(id: 1, cells: ["INFY", "7", "Infosys"], numbers: [nil, 7, nil]),
        ])
        let r = ChangeEngine.byStock(current: now, previous: prev, label: 0, columns: [1, 2], scope: nil, filterNow: [], filterBefore: [])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].symbol, "TATAMOTORS")
        XCTAssertEqual(r[0].fields.first?.column, "Count")
        XCTAssertEqual(r[0].fields.first?.before, "4")
        XCTAssertEqual(r[0].fields.first?.after, "5")
        XCTAssertEqual(r[0].fields.first?.delta, 1)
    }
}

final class ExperimentTests: XCTestCase {
    private func sheet() -> SheetTable {
        SheetTable(headers: ["Symbol", "TrigB", "TrigC", "Sector"], rows: [
            SheetRow(id: 0, cells: ["AAA", "2026-01-05", "2026-01-07", "IT"], numbers: [nil, nil, nil, nil]),
            SheetRow(id: 1, cells: ["BBB", "05-01-2026", "", "Auto"], numbers: [nil, nil, nil, nil]),
        ])
    }
    private func book() -> PriceBook {
        var b = PriceBook()
        let days = (5...30).map { String(format: "2026-01-%02d", $0) }
        b.series["AAA"] = PriceSeries(days: days, closes: days.indices.map { 100 + Double($0) })
        b.series["BBB"] = PriceSeries(days: days, closes: days.indices.map { 100 - Double($0) })
        return b
    }

    func testCompareCommand() {
        let t = sheet()
        var p = ExperimentEngine.guessPlan("COL A is the shortlist trigger -- here the NSE symbol is shortlisted. COL B and COL C are timing triggers -- compare which among COL B or COL C are doing better", notes: "", table: t, previous: nil)
        XCTAssertEqual(p.task, "compare")
        XCTAssertEqual(p.symbolColumn, "Symbol")
        XCTAssertEqual(p.triggers.map(\.column), ["TrigB", "TrigC"])
        XCTAssertEqual(p.triggers.first?.kind, "date")
        p.horizons = [5]
        let r = ExperimentEngine.run(p, table: t, prices: book(), calendar: [])
        XCTAssertEqual(r.entries.filter { $0.arm == "TrigB" }.count, 2)
        XCTAssertEqual(r.entries.filter { $0.arm == "TrigC" }.count, 1)
        let ret: Double = (r.entries.first { $0.symbol == "AAA" && $0.arm == "TrigB" }?.returns.first ?? nil) ?? 0
        XCTAssertEqual(ret, 5, accuracy: 1e-9)
        XCTAssertEqual(r.tables.count, 2)         // returns + head to head
    }

    func testOtherCommands() {
        let t = sheet()
        let g = ExperimentEngine.guessPlan("how many days from COL B to COL C", notes: "", table: t, previous: nil)
        XCTAssertEqual(g.task, "gap")
        let r = ExperimentEngine.run(g, table: t, prices: PriceBook(), calendar: [])
        XCTAssertTrue(r.headline.contains("2"), r.headline)          // Jan 5 → Jan 7 = 2 weekdays
        var f = ExpPlan(); f.task = "compare"; f.symbolColumn = "Symbol"; f.triggers = [ExpTrigger(column: "TrigB")]
        f.filters = [ExpFilter(column: "Sector", op: "=", value: "IT")]; f.horizons = [5]
        XCTAssertEqual(ExperimentEngine.run(f, table: t, prices: book(), calendar: []).entries.count, 1)
        XCTAssertEqual(ExperimentEngine.day("5-Jan-2026"), "2026-01-05")
        XCTAssertEqual(ExperimentEngine.columnLetter(27), "AB")
    }
}

final class ChangeConditionTests: XCTestCase {
    func testMissingColumnsInOldSnapshotAreNotChanges() {
        let prev = SheetTable(headers: ["Symbol", "MS", "DLVR"], rows: [SheetRow(id: 0, cells: ["AAA", "50", ""], numbers: [nil, 50, nil])])
        let now = SheetTable(headers: ["Symbol", "MS", "DLVR"], rows: [SheetRow(id: 0, cells: ["AAA", "50", "0"], numbers: [nil, 50, 0])])
        XCTAssertTrue(ChangeEngine.byStock(current: now, previous: prev, label: 0, columns: [1, 2], scope: nil, filterNow: [], filterBefore: []).isEmpty)
        // a stock that met a condition is kept even with no column change
        XCTAssertEqual(ChangeEngine.byStock(current: now, previous: prev, label: 0, columns: [1, 2], scope: nil, filterNow: [], filterBefore: [], include: ["AAA"]).count, 1)
    }
}

final class ExperimentDateTests: XCTestCase {
    func testMonthFirstSheetsAndBarsAgo() {
        let t = SheetTable(headers: ["Symbol", "date", "var2"], rows: [
            SheetRow(id: 0, cells: ["AAA", "10/19/2026", "3"], numbers: [nil, nil, 3]),
            SheetRow(id: 1, cells: ["BBB", "10/05/2026", "1"], numbers: [nil, nil, 1]),
        ])
        XCTAssertTrue(ExperimentEngine.detectMonthFirst(t))
        ExperimentEngine.monthFirst = true
        XCTAssertEqual(ExperimentEngine.day("10/05/2026"), "2026-10-05")
        ExperimentEngine.monthFirst = false
        XCTAssertEqual(ExperimentEngine.day("10/05/2026"), "2026-05-10")
        XCTAssertEqual(ExperimentEngine.day("10/19/2026"), "2026-10-19")      // only valid one way
        // bars ago: entry 3 trading days before the row date
        var b = PriceBook()
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-19"]
        b.series["AAA"] = PriceSeries(days: days, closes: [100, 101, 102, 103, 104, 110])
        var p = ExpPlan(); p.symbolColumn = "Symbol"; p.triggers = [ExpTrigger(column: "var2", kind: "barsAgo")]; p.horizons = [2]
        let r = ExperimentEngine.run(p, table: t, prices: b, calendar: [])
        let e = r.entries.first { $0.symbol == "AAA" }
        XCTAssertEqual(e?.day, "2026-10-14")
        XCTAssertEqual((e?.returns.first ?? nil) ?? 0, (104.0 / 102 - 1) * 100, accuracy: 1e-9)
        XCTAssertTrue(r.notes.contains { $0.contains("Row date: using") })
    }
}

final class ExperimentAutoBarsTests: XCTestCase {
    func testTodayRowsWithCountsAreReadAsBarsAgo() {
        let t = SheetTable(headers: ["Symbol", "date", "var2", "var4"], rows: [
            SheetRow(id: 0, cells: ["AAA", "10/19/2026", "4", "2"], numbers: [nil, nil, 4, 2]),
        ])
        XCTAssertEqual(ExperimentEngine.resolve("var 2", in: t), "var2")
        XCTAssertEqual(ExperimentEngine.resolve("COL C", in: t), "var2")
        var b = PriceBook()
        b.series["AAA"] = PriceSeries(days: ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-19"],
                                      closes: [100, 101, 102, 103, 104, 110])
        var p = ExpPlan(); p.symbolColumn = "Symbol"; p.horizons = [1]
        p.triggers = [ExpTrigger(column: "var2", kind: "flag"), ExpTrigger(column: "var4", kind: "flag")]
        let r = ExperimentEngine.run(p, table: t, prices: b, calendar: [])
        XCTAssertTrue(r.notes.first?.contains("BARS AGO") ?? false, r.notes.joined(separator: " | "))
        XCTAssertEqual(r.entries.first { $0.arm == "var2" }?.day, "2026-10-13")
        XCTAssertEqual(r.entries.first { $0.arm == "var4" }?.day, "2026-10-15")
        let plan = ExperimentEngine.guessPlan("var 2 is a timing trigger , var 4 is also a timing trigger -- compare which one gives better results", notes: "", table: t, previous: nil)
        XCTAssertEqual(plan.triggers.map(\.column), ["var2", "var4"])
    }
}

final class ExperimentChatTests: XCTestCase {
    func testQueries() {
        let t = SheetTable(headers: ["Symbol", "Sector"], rows: [
            SheetRow(id: 0, cells: ["AAA", "IT"], numbers: [nil, nil]), SheetRow(id: 1, cells: ["BBB", "Auto"], numbers: [nil, nil]),
            SheetRow(id: 2, cells: ["CCC", "IT"], numbers: [nil, nil]),
        ])
        var r = ExpResult()
        func e(_ s: String, _ id: Int, _ ret: Double) -> ExpEntry {
            ExpEntry(symbol: s, arm: "Trigger", day: "2026-01-05", entry: 100, returns: [ret], best: [ret], worst: [min(0, ret)], trade: nil, daysAfterShortlist: nil, rowID: id)
        }
        r.entries = [e("AAA", 0, 12), e("BBB", 1, -4), e("CCC", 2, 3)]
        var p = ExpPlan(); p.horizons = [10]
        let top = ExperimentChatEngine.run(ExperimentChatEngine.parseQuery(["kind": "top", "limit": 1], table: t), result: r, plan: p, table: t)
        XCTAssertTrue(top.contains("AAA"), top)
        XCTAssertFalse(top.contains("BBB ·"), top)
        let it = ExperimentChatEngine.run(ExperimentChatEngine.parseQuery(["kind": "stats", "filters": [["column": "sector", "op": "=", "value": "IT"]]], table: t), result: r, plan: p, table: t)
        XCTAssertTrue(it.contains("n 2") && it.contains("+7.5%"), it)
        let byGroup = ExperimentChatEngine.run(ExperimentChatEngine.parseQuery(["kind": "stats", "groupBy": "Sector"], table: t), result: r, plan: p, table: t)
        XCTAssertTrue(byGroup.contains("Auto: n 1"), byGroup)
    }
}

final class ExperimentInvestTests: XCTestCase {
    func testInvestYearBackWithBarsAgo() {
        let t = SheetTable(headers: ["Symbol", "10/20/2026", "var4"], rows: [
            SheetRow(id: 0, cells: ["AAA", "10/20/2026", "3.00"], numbers: [nil, nil, 3]),
            SheetRow(id: 1, cells: ["BBB", "10/20/2026", "2.00"], numbers: [nil, nil, 2]),
        ])
        XCTAssertEqual(ExperimentEngine.resolve("F", in: SheetTable(headers: ["a", "b", "c", "d", "e", "var4"], rows: [])), "var4")
        XCTAssertEqual(ExperimentEngine.resolve("var4 (barsAgo)", in: t), "var4")
        let plan = ExperimentEngine.guessPlan("Col A = NSE symbol -- COL C = var4 this is trigger in form of trading days before , compute if I invest 100000 a year back what would i a make in the best and worst case", notes: "", table: t, previous: nil)
        XCTAssertEqual(plan.task, "invest")
        XCTAssertEqual(plan.investAmount, 100000)
        XCTAssertEqual(plan.lookbackDays, 252)
        XCTAssertEqual(plan.triggers.first?.kind, "barsAgo")
        var b = PriceBook()
        let days = ["2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-19"]
        b.series["AAA"] = PriceSeries(days: days, closes: [100, 100, 100, 100, 150])
        b.series["BBB"] = PriceSeries(days: days, closes: [100, 100, 100, 100, 80])
        let r = ExperimentEngine.run(plan, table: t, prices: b, calendar: [])
        XCTAssertTrue(r.headline.contains("best ₹1,50,000 (AAA)"), r.headline)
        XCTAssertTrue(r.headline.contains("worst ₹80,000 (BBB)"), r.headline)
    }
}

final class JumpTests: XCTestCase {
    func testSMAAndJump() {
        XCTAssertEqual(DeliverySignal.sma([1, 2, 3, 4], 2), [0, 1.5, 2.5, 3.5])
        // mode 1: value now ÷ previous different 3-bar highest
        let m: [Double] = [5, 4, 3, 2, 10]
        XCTAssertEqual(DeliverySignal.jump(m, at: 4, mode: 1, length: 3) ?? 0, 10.0 / 4.0, accuracy: 1e-9)   // highest before: max(4,3,2)=4
        // mode 0: percentrank now ÷ the percent rank's previous local peak
        let x: [Double] = [1, 2, 3, 1, 1, 1, 5, 1, 1, 1, 9]
        let j = DeliverySignal.jump(x, at: 10, mode: 0, length: 3)
        XCTAssertNotNil(j)
        XCTAssertEqual(j ?? 0, 100.0 / 100.0, accuracy: 1e-9)   // PR at bar 6 (5 vs 1,1,1) = 100, now 100
    }
}

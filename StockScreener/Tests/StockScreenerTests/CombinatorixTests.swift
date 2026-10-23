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

final class DelSmaTests: XCTestCase {
    func testNilUntilEnoughBars() {
        let x = (0..<321).map { Double($0) }
        XCTAssertNil(DeliveryColumns.delSma(x, at: 320))
        let y = (0..<322).map { Double($0) }
        XCTAssertEqual(DeliveryColumns.delSma(y, at: 321), 100)   // rising series: SMA beats all 300 previous
    }
    func testMatchesManual() {
        let x = (0..<400).map { Double(($0 * 37) % 101) }
        let sm = DeliverySignal.sma(x, 22)
        let valid = Array(sm[21...])
        let i = 399
        var c = 0
        for k in (i - 21 - 300)..<(i - 21) where valid[k] <= valid[i - 21] { c += 1 }
        XCTAssertEqual(DeliveryColumns.delSma(x, at: i)!, Double(c) / 300 * 100, accuracy: 1e-9)
    }
}

final class GainerChartsTests: XCTestCase {
    func testMonthChange() {
        var days: [String] = [], closes: [Double] = []
        for d in 1...30 { days.append(String(format: "2026-09-%02d", d)); closes.append(100) }
        for d in 1...20 { days.append(String(format: "2026-10-%02d", d)); closes.append(100 + Double(d) * 2) }
        let s = PriceSeries(days: days, closes: closes)
        XCTAssertEqual(GainerChartsView.monthChange(s, day: "2026-10-20", window: .calendar)!, 40, accuracy: 1e-9)
        XCTAssertEqual(GainerChartsView.monthChange(s, day: "2026-10-20", window: .rolling)!, 40, accuracy: 1e-9)  // 21 bars back = Sep 30
        XCTAssertNil(GainerChartsView.monthChange(s, day: "2026-10-21", window: .calendar))   // no bar that day
    }
}

final class AutoPredictTests: XCTestCase {
    private func result(labeled: Int = 20, gainers: Int = 30) -> CombiHorizonResult {
        var r = CombiHorizonResult()
        r.horizon = .monthly
        r.labeledDays = labeled
        r.gainers = gainers
        r.baseRate = 0.05
        r.signals = [CombiSignal(name: "MS High (> 90)", kind: .level, group: "L:MS", column: "MS", flavour: "high"),
                     CombiSignal(name: "DS High (> 80)", kind: .level, group: "L:DS", column: "DS", flavour: "high")]
        var good = CombiCombo(signals: [0, 1], text: "MS High (> 90) + DS High (> 80)", total: 100, gainers: 20, hitRate: 0.2, lift: 4, safeLift: 2.5, pValue: 0.001)
        good.testTotal = 40; good.testGainers = 10; good.testLift = 5; good.heldUp = true; good.todayMatches = ["AAA"]
        var faded = CombiCombo(signals: [0], text: "MS High (> 90)", total: 300, gainers: 30, hitRate: 0.1, lift: 2, safeLift: 1.5, pValue: 0.01)
        faded.testTotal = 50; faded.testGainers = 2; faded.testLift = 0.8; faded.heldUp = false; faded.todayMatches = ["AAA", "BBB"]
        r.combos = [good, faded]
        return r
    }

    func testActiveUsesOnlyProvenCombos() {
        let s = APEngine.update(APState(), result: result(), liveDay: "2026-10-20", book: PriceBook(), threshold: 30)
        XCTAssertEqual(s.phase, .active)
        XCTAssertEqual(s.predictions.map(\.symbol), ["AAA"])
        XCTAssertEqual(s.predictions[0].ruleKeys.count, 1)
        XCTAssertEqual(s.runs.count, 1)
    }

    func testWaitsForEnoughData() {
        let s = APEngine.update(APState(), result: result(labeled: 5), liveDay: "2026-10-20", book: PriceBook(), threshold: 30)
        XCTAssertEqual(s.phase, .collecting)
        XCTAssertTrue(s.predictions.isEmpty)
    }

    func testRetiresComboThatFailsLive() {
        let first = APEngine.update(APState(), result: result(), liveDay: "2026-09-01", book: PriceBook(), threshold: 30)
        let key = first.predictions[0].ruleKeys[0]
        var old = first
        old.predictions = (0..<8).map { i in
            var p = APPrediction(day: "2026-08-\(10 + i)", symbol: "X\(i)", close: 1, chance: 0.1, rules: ["r"], ruleKeys: [key])
            p.outcome = 2; p.hit = false
            return p
        }
        let s = APEngine.update(old, result: result(), liveDay: "2026-10-20", book: PriceBook(), threshold: 30)
        XCTAssertTrue(s.rules.first { $0.key == key }!.retired)
        XCTAssertEqual(s.phase, .learning)
        XCTAssertTrue(s.predictions.filter { $0.day == "2026-10-20" }.isEmpty)
        XCTAssertEqual(s.liveHitRate, 0)
    }

    func testSameDayRerunReplacesPredictions() {
        let a = APEngine.update(APState(), result: result(), liveDay: "2026-10-20", book: PriceBook(), threshold: 30)
        let b = APEngine.update(a, result: result(), liveDay: "2026-10-20", book: PriceBook(), threshold: 30)
        XCTAssertEqual(b.predictions.count, 1)
        XCTAssertEqual(b.runs.count, 1)
    }
}

final class LiveQuotesTests: XCTestCase {
    private func ist(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    @MainActor func testMarketHours() {
        XCTAssertTrue(LiveQuotes.marketOpen(ist("2026-10-21 10:00")))     // Wednesday
        XCTAssertFalse(LiveQuotes.marketOpen(ist("2026-10-21 08:59")))
        XCTAssertFalse(LiveQuotes.marketOpen(ist("2026-10-21 16:00")))
        XCTAssertFalse(LiveQuotes.marketOpen(ist("2026-10-24 11:00")))    // Saturday
    }
    func testLiveBarMerges() {
        let old = PriceSeries(days: ["2026-10-19", "2026-10-20"], closes: [100, 100])
        let live = PriceSeries(days: ["2026-10-20", "2026-10-21"], closes: [100, 106])
        let m = old.merged(with: live)
        XCTAssertEqual(m.dailyChange(on: "2026-10-21")!, 6, accuracy: 1e-9)
    }
}

final class StreakTests: XCTestCase {
    func testStreakCountsConsecutiveDays() {
        var x = (0..<400).map { 100 + Double($0 % 7) }          // ordinary days
        x += [Double](repeating: 10, count: 25)                  // delivery dries up → SMA rank falls to 0
        x += [Double](repeating: 10_000, count: 5)               // 5 huge days → SMA at a 300-bar high each day
        var d = StreakDef(); d.sma = 22; d.length = 300; d.op = ">"; d.value = 99
        XCTAssertEqual(d.streak(x, at: x.count - 1), 5)
        XCTAssertEqual(d.streak(x, at: 424), 0)
        d.op = "≤"; d.value = 1                                  // flat SMA ties count (≤), like Pine: rank 1.0 on the last low day
        XCTAssertGreaterThan(d.streak(x, at: 424) ?? 0, 0)
    }
    func testNilWithoutHistory() {
        let d = StreakDef(sma: 22, length: 300, op: ">", value: 99)
        XCTAssertNil(d.streak([Double](repeating: 1, count: 100), at: 99))
    }
}

final class T3Tests: XCTestCase {
    func testPineEMASeededWithSMA() {
        let e = T3Def.ema([1, 2, 3, 4, 5].map { Optional($0) }, 3)
        XCTAssertNil(e[1])
        XCTAssertEqual(e[2]!, 2, accuracy: 1e-12)                    // SMA of 1,2,3
        XCTAssertEqual(e[3]!, 0.5 * 4 + 0.5 * 2, accuracy: 1e-12)    // alpha = 2/(3+1)
    }
    func testT3OfConstantIsConstantAndColour() {
        let d = T3Def(length: 5, factor: 1, useQty: false)
        let flat = [Double](repeating: 10, count: 60)
        let t = d.t3(flat)
        XCTAssertNil(t[20])                                           // needs 6×5−5 = 25 bars
        XCTAssertEqual(t[24]!, 10, accuracy: 1e-9)
        XCTAssertEqual(d.color(flat), 0)                              // not rising → red (0)
        XCTAssertEqual(d.color(flat + [20, 30, 40]), 1)               // rising → green (1)
        XCTAssertNil(d.color(Array(flat.prefix(25))))                 // t3[1] still na
    }
}

final class DealsParseTests: XCTestCase {
    func testAPIRow() {
        let row: [String: Any] = ["BD_DT_DATE": "22-Aug-2023", "BD_SYMBOL": "ABC", "BD_SCRIP_NAME": "ABC Ltd", "BD_CLIENT_NAME": "XYZ FUND",
                                  "BD_BUY_SELL": "SELL", "BD_QTY_TRD": 150000, "BD_TP_WATP": 123.45]
        let d = NSEDealsClient.parse(row, kind: "Bulk")!
        XCTAssertEqual(d.day, "2023-08-22"); XCTAssertEqual(d.symbol, "ABC"); XCTAssertFalse(d.isBuy)
        XCTAssertEqual(d.qty, 150000); XCTAssertEqual(d.price, 123.45, accuracy: 1e-9); XCTAssertEqual(d.client, "XYZ FUND")
    }
    func testArchiveCSVRow() {
        let h = CSVLine.split("Date,Symbol,Security Name,Client Name,Buy/Sell,Quantity Traded,Trade Price / Wght. Avg. Price,Remarks").map { $0.uppercased() }
        let c = CSVLine.split("21-OCT-2026,TATAMOTORS,\"Tata Motors, Ltd\",SOME CLIENT,BUY,\"1,20,000\",745.50,-")
        var d: [String: Any] = [:]; for (i, k) in h.enumerated() { d[k] = c[i] }
        let x = NSEDealsClient.parse(d, kind: "Block")!
        XCTAssertEqual(x.day, "2026-10-21"); XCTAssertTrue(x.isBuy); XCTAssertEqual(x.qty, 120000); XCTAssertEqual(x.price, 745.5, accuracy: 1e-9)
    }
}

final class EventCodeTests: XCTestCase {
    func testCodesAndGuess() {
        let list = EventCodes.defaults
        XCTAssertEqual(EventCodes.code(for: "Dividend", in: list), "D")
        XCTAssertEqual(EventCodes.code(for: "factory fire", in: list), "FF")
        XCTAssertEqual(EventCodes.code(for: nil, in: list), "N")
        XCTAssertEqual(EventCodes.code(for: "Weather", in: list), "W")
        let h = [Headline(title: "Fire breaks out at XYZ plant in Gujarat", source: "ET", date: nil, link: "")]
        XCTAssertEqual(EventCodes.guess(h, in: list), "Factory fire")
        let d = [Headline(title: "ABC declares interim dividend of Rs 5", source: "BS", date: nil, link: "")]
        XCTAssertEqual(EventCodes.guess(d, in: list), "Dividend")
    }
}

final class NewsImpactTests: XCTestCase {
    func testGuessAndDots() {
        XCTAssertEqual(NewsImpact.guess(category: "Results"), 2)
        XCTAssertEqual(NewsImpact.guess(category: "Other"), 0)
        XCTAssertEqual(NewsImpact.guess(category: "Rating change"), 1)
        XCTAssertEqual(NewsImpact.dots(2), "●●○")
        XCTAssertEqual(NewsImpact.dots(nil), "?")
    }
}

final class HiT3Tests: XCTestCase {
    func testConstantSeriesRatioIsOne() {
        let x = [Double](repeating: 50, count: 400)
        XCTAssertEqual(DeliveryColumns.hiOverT3(x, t3Source: x, sma: 22)!, 1, accuracy: 1e-9)
        XCTAssertNil(DeliveryColumns.hiOverT3(Array(x.prefix(300)), t3Source: x, sma: 22))   // needs 21 + 300 bars
    }
    func testSpikeRaisesRatio() {
        var x = [Double](repeating: 50, count: 380); for i in 300..<320 { x[i] = 500 }    // spike earlier, back to normal
        XCTAssertGreaterThan(DeliveryColumns.hiOverT3(x, t3Source: x, sma: 22)!, 1)
    }
}

final class TimingLabTests: XCTestCase {
    private func series() -> PriceSeries {
        var days: [String] = [], closes: [Double] = []
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var d = f.date(from: "2026-01-01")!
        for i in 0..<200 { days.append(f.string(from: d)); closes.append(100 + Double(i)); d = d.addingTimeInterval(86_400) }
        return PriceSeries(days: days, closes: closes)
    }
    func testBarsAgoAndAfterShortlistRule() {
        let s = series()
        let asOf = s.days[199]
        let rows = [TLInputRow(symbol: "AAA", asOf: asOf, shortlist: 100, triggers: [90, 150])]     // var2 after, var3 before shortlist
        let r = TLEngine.run(rows, names: ["var2", "var3"], series: ["AAA": s])
        let v2 = r.trades.first { $0.entryName == "var2" }!
        XCTAssertEqual(v2.day, s.days[109]); XCTAssertEqual(v2.wait, 10)
        XCTAssertEqual(v2.ret[5]!, (s.closes[114] / s.closes[109] - 1) * 100, accuracy: 1e-9)
        XCTAssertEqual(v2.toToday, (s.closes[199] / s.closes[109] - 1) * 100, accuracy: 1e-9)
        XCTAssertEqual(r.stats.first { $0.name == "var3" }!.beforeShortlist, 1)
        XCTAssertEqual(r.stats.first { $0.isReference }!.trades, 1)
    }
    func testSheetDates() {
        XCTAssertTrue(TLSheet.monthFirst(["10/22/2026", "10/21/2026"]))
        XCTAssertEqual(TLSheet.day("10/22/2026", monthFirst: true), "2026-10-22")
        XCTAssertEqual(TLSheet.day("22/10/2026", monthFirst: false), "2026-10-22")
        XCTAssertNil(TLSheet.bars("∅")); XCTAssertEqual(TLSheet.bars("101.00"), 101); XCTAssertNil(TLSheet.bars(""))
    }
}

final class EventScanTests: XCTestCase {
    func testBarsSinceCrossBelow() {
        let x: [Double?] = [nil, 1.3, 1.2, 1.05, 1.0, 1.2, 1.08, 1.09]   // crosses below 1.10 at 3 and again at 6
        let c = ScanCond(metric: .hiT3, event: .crossBelow, value: 1.10)
        let h = ScanEngine.barsSince(x, c, last: 7)!
        XCTAssertEqual(h.0, 1); XCTAssertEqual(h.1, 6)
        XCTAssertEqual(ScanEngine.barsSince(x, c, last: 5)!.1, 3)
        XCTAssertNil(ScanEngine.barsSince(x, ScanCond(metric: .hiT3, event: .crossBelow, value: 0.9), last: 7))
        XCTAssertEqual(ScanEngine.barsSince(x, ScanCond(metric: .hiT3, event: .lastBelow, value: 1.10), last: 7)!.0, 0)
    }
    func testQuickParse() {
        let c = ScanCond.parse("HI/T3 < 1.10")!
        XCTAssertEqual(c.metric, .hiT3); XCTAssertEqual(c.event, .crossBelow); XCTAssertEqual(c.value, 1.10, accuracy: 1e-9)
        let d = ScanCond.parse("DELSMA > 99")!
        XCTAssertEqual(d.metric, .delSma); XCTAssertEqual(d.event, .crossAbove)
        XCTAssertEqual(ScanCond.parse("close crosses above 500")?.metric, .close)
        XCTAssertNil(ScanCond.parse("nonsense 5"))
    }
}

final class ShortlistTests: XCTestCase {
    func testShortlistRules() {
        var a = ShortlistAlert()
        let has = SheetRow(id: 0, cells: ["12"], numbers: [12]), blank = SheetRow(id: 1, cells: [""], numbers: [nil])
        XCTAssertTrue(a.onShortlist(has, column: 0)); XCTAssertFalse(a.onShortlist(blank, column: 0))
        a.shortlistOp = "≤"; a.shortlistValue = 10
        XCTAssertFalse(a.onShortlist(has, column: 0))
        a.shortlistValue = 20
        XCTAssertTrue(a.onShortlist(has, column: 0))
        XCTAssertTrue(ShortlistCond(column: "MS", op: ">", value: 99).passes(99.5))
        XCTAssertFalse(ShortlistCond(column: "MS", op: ">", value: 99).passes(99))
        XCTAssertEqual(a.name, "Shortlist D_Trigger ≤ 20 → MS > 99 or DS > 99")
    }
}

final class YahooTickerTests: XCTestCase {
    func testTickers() {
        XCTAssertEqual(YahooClient.yahooSymbol("TCS"), "TCS.NS")
        XCTAssertEqual(YahooClient.yahooSymbol("BAJAJ-AUTO"), "BAJAJ-AUTO.NS")
        XCTAssertEqual(YahooClient.yahooSymbol("^GSPC"), "%5EGSPC")
        XCTAssertEqual(YahooClient.yahooSymbol("BZ=F"), "BZ%3DF")
        XCTAssertEqual(YahooClient.yahooSymbol("BTC-USD"), "BTC-USD")
    }
}

final class AlertOncePerDayTests: XCTestCase {
    @MainActor func testSameStockOnlyOnceADay() {
        UserDefaults.standard.removeObject(forKey: "alerts.shownDay")
        let id = UUID()
        let a = [InAppAlert(triggerID: id, name: "D_Trigger → MS > 99", stocks: ["GODREJAGRO", "TCS"])]
        XCTAssertEqual(ScreenerViewModel.onlyNewToday(a, day: "2026-10-23").first?.stocks, ["GODREJAGRO", "TCS"])
        XCTAssertTrue(ScreenerViewModel.onlyNewToday(a, day: "2026-10-23").isEmpty)              // second refresh: nothing
        let more = [InAppAlert(triggerID: id, name: "x", stocks: ["TCS", "INFY"])]
        XCTAssertEqual(ScreenerViewModel.onlyNewToday(more, day: "2026-10-23").first?.stocks, ["INFY"])   // only the new one
        XCTAssertEqual(ScreenerViewModel.onlyNewToday(a, day: "2026-10-26").first?.stocks.count, 2)       // next day again
        UserDefaults.standard.removeObject(forKey: "alerts.shownDay")
    }
}

final class AlertScheduleTests: XCTestCase {
    private func ist(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    func testOnceAfterClose() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "alerts.doneDay"); d.removeObject(forKey: "alerts.at")
        XCTAssertFalse(AlertSchedule.isDue(ist("2026-10-23 11:00")))     // market hours
        XCTAssertTrue(AlertSchedule.isDue(ist("2026-10-23 15:50")))
        AlertSchedule.markDone(ist("2026-10-23 15:50"))
        XCTAssertFalse(AlertSchedule.isDue(ist("2026-10-23 17:00")))     // already done today
        XCTAssertFalse(AlertSchedule.isDue(ist("2026-10-24 16:00")))     // Saturday
        XCTAssertTrue(AlertSchedule.isDue(ist("2026-10-26 15:46")))      // next Monday
        d.removeObject(forKey: "alerts.doneDay")
    }
}

final class ShortlistNameTests: XCTestCase {
    func testNameAndMode() {
        var a = ShortlistAlert()
        a.matchAll = true
        XCTAssertEqual(a.name, "Shortlist D_Trigger → MS > 99 and DS > 99")
        a.customName = "Green shortlist"
        XCTAssertEqual(a.name, "Green shortlist")
        a.customName = "  "
        XCTAssertTrue(a.name.hasPrefix("Shortlist"))
    }
}

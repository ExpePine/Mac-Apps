import XCTest
@testable import StockScreener

final class FilterTests: XCTestCase {

    /// Small sample shaped like the real sheet.
    private func sampleTable() throws -> SheetTable {
        let csv = """
        SYMBOL,D_MONTH,D_DAY,D_TRIGGER,CLOSE,EMA_20,RSI_14,Vol Ratio,SECTOR
        RELIANCE,10,16,5,2950,2800,64,2.5,Energy
        HDFCBANK,10,16,0,1650,1700,48,0.9,Bank
        TCS,10,16,3,4100,4000,71,1.4,"IT, Services"
        INFY,10,16,,1890,1885,55,3.1,IT
        """
        return try SheetService.parse(Data(csv.utf8)).table
    }

    private func symbols(_ rows: [SheetRow]) -> [String] { rows.map { $0.text(0) } }

    private func run(_ group: FilterGroup, _ table: SheetTable) -> [String] {
        var issues: [String] = []
        let p = FilterCompiler.compile(group, table: table, issues: &issues)
        XCTAssertTrue(issues.isEmpty, "issues: \(issues)")
        return symbols(p.map { table.rows.filter($0) } ?? table.rows)
    }

    private func formula(_ text: String, _ table: SheetTable) throws -> [String] {
        let f = try Formula.compile(text, table: table)
        return symbols(table.rows.filter(f.predicate))
    }

    // MARK: Parsing

    func testCSVAndNumbers() throws {
        let t = try sampleTable()
        XCTAssertEqual(t.headers.count, 9)
        XCTAssertEqual(t.rows.count, 4)
        XCTAssertEqual(t.rows[2].text(8), "IT, Services")     // quoted comma
        XCTAssertEqual(t.rows[0].number(4), 2950)
        XCTAssertNil(t.rows[0].number(0))                      // symbol isn't a number
        XCTAssertEqual(t.index(of: "d_trigger"), 3)            // case-insensitive lookup
        XCTAssertEqual(t.index(of: " vol ratio "), 7)
    }

    func testNumberParser() {
        XCTAssertEqual(NumberParser.parse("1,234.5"), 1234.5)
        XCTAssertEqual(NumberParser.parse("₹2,450"), 2450)
        XCTAssertEqual(NumberParser.parse("-3.2%"), -3.2)
        XCTAssertEqual(NumberParser.parse("12.4 B"), 12.4e9)
        XCTAssertEqual(NumberParser.parse("850 Cr"), 850e7)
        XCTAssertNil(NumberParser.parse("RELIANCE"))
        XCTAssertNil(NumberParser.parse(""))
        XCTAssertNil(NumberParser.parse("L&T"))
    }

    // MARK: Builder filters

    func testHasValueAndValueCompare() throws {
        let t = try sampleTable()
        XCTAssertEqual(run(FilterGroup(conditions: [FilterCondition(column: "D_Trigger", op: .hasValue)]), t),
                       ["RELIANCE", "TCS"])
        XCTAssertEqual(run(FilterGroup(conditions: [FilterCondition(column: "RSI_14", op: .greaterOrEqual, value: "60")]), t),
                       ["RELIANCE", "TCS"])
        XCTAssertEqual(run(FilterGroup(conditions: [FilterCondition(column: "SECTOR", op: .equals, value: "bank")]), t),
                       ["HDFCBANK"])
        XCTAssertEqual(run(FilterGroup(conditions: [FilterCondition(column: "CLOSE", op: .between, value: "1800", value2: "3000")]), t),
                       ["RELIANCE", "INFY"])
    }

    func testColumnVsColumnWithFactor() throws {
        let t = try sampleTable()
        // CLOSE > EMA_20 × 1.02  → RELIANCE (2950 > 2856), TCS (4100 > 4080)
        let c = FilterCondition(column: "CLOSE", op: .greaterThan, target: .column, otherColumn: "EMA_20", factor: "1.02")
        XCTAssertEqual(run(FilterGroup(conditions: [c]), t), ["RELIANCE", "TCS"])
    }

    func testNestedGroupsAndNot() throws {
        let t = try sampleTable()
        // CLOSE > EMA_20 AND (RSI_14 > 70 OR Vol Ratio > 3)
        let inner = FilterGroup(mode: .any, conditions: [
            FilterCondition(column: "RSI_14", op: .greaterThan, value: "70"),
            FilterCondition(column: "Vol Ratio", op: .greaterThan, value: "3"),
        ])
        let root = FilterGroup(mode: .all,
                               conditions: [FilterCondition(column: "CLOSE", op: .greaterThan, target: .column, otherColumn: "EMA_20")],
                               groups: [inner])
        XCTAssertEqual(run(root, t), ["TCS", "INFY"])

        let none = FilterGroup(mode: .notAny, conditions: [FilterCondition(column: "SECTOR", op: .contains, value: "IT")])
        XCTAssertEqual(run(none, t), ["RELIANCE", "HDFCBANK"])
    }

    func testEmptyGroupPassesEverything() throws {
        let t = try sampleTable()
        XCTAssertEqual(run(FilterGroup(), t).count, 4)
    }

    func testMissingColumnIsReported() throws {
        let t = try sampleTable()
        var issues: [String] = []
        _ = FilterCompiler.compile(FilterGroup(conditions: [FilterCondition(column: "NOPE", op: .greaterThan, value: "1")]),
                                   table: t, issues: &issues)
        XCTAssertEqual(issues.count, 1)
    }

    // MARK: Formulas

    func testFormulas() throws {
        let t = try sampleTable()
        XCTAssertEqual(try formula("CLOSE > EMA_20 * 1.02", t), ["RELIANCE", "TCS"])
        XCTAssertEqual(try formula("rsi_14 >= 60 and [Vol Ratio] > 2", t), ["RELIANCE"])
        XCTAssertEqual(try formula("(D_TRIGGER > 0 OR [Vol Ratio] > 3) AND NOT SECTOR = 'Bank'", t), ["RELIANCE", "TCS", "INFY"])
        XCTAssertEqual(try formula("pct(CLOSE, EMA_20) > 5", t), ["RELIANCE"])
        XCTAssertEqual(try formula("abs(CLOSE - EMA_20) / EMA_20 < 0.01", t), ["INFY"])
        XCTAssertEqual(try formula("empty(D_TRIGGER)", t), ["HDFCBANK", "INFY"])
        XCTAssertEqual(try formula("contains(SECTOR, 'it')", t), ["TCS", "INFY"])
        XCTAssertEqual(try formula("max(RSI_14, 60) = 60", t), ["HDFCBANK", "INFY"])
        XCTAssertEqual(try formula("CLOSE ≥ 4100", t), ["TCS"])
    }

    func testFormulaErrors() throws {
        let t = try sampleTable()
        XCTAssertThrowsError(try Formula.compile("CLOSE >", table: t))
        XCTAssertThrowsError(try Formula.compile("UNKNOWN_COL > 5", table: t))
        XCTAssertThrowsError(try Formula.compile("(CLOSE > 5", table: t))
        XCTAssertThrowsError(try Formula.compile("CLOSE > 'abc", table: t))
    }

    func testFormulaReferencedColumns() throws {
        let t = try sampleTable()
        let f = try Formula.compile("CLOSE > EMA_20 AND [Vol Ratio] > 1", table: t)
        XCTAssertEqual(Set(f.columns), [4, 5, 7])
    }

    // MARK: Sorting, colors, dates

    func testSortDescendingBlanksLast() throws {
        let t = try sampleTable()
        let sorted = Sorter.sort(t.rows, column: 3, descending: true)
        XCTAssertEqual(symbols(sorted), ["RELIANCE", "TCS", "HDFCBANK", "INFY"])
    }

    func testCellPainter() throws {
        let t = try sampleTable()
        let painter = CellPainter([
            CellRule(condition: Rule(column: "RSI_14", op: .greaterThan, value: "60"), shade: .green),
            CellRule(condition: Rule(column: "RSI_14", op: .lessThan, value: "50"), shade: .red),
        ], table: t)
        XCTAssertNotNil(painter.color(for: t.rows[0], column: 6))   // 64 → green
        XCTAssertNotNil(painter.color(for: t.rows[1], column: 6))   // 48 → red
        XCTAssertNil(painter.color(for: t.rows[3], column: 6))      // 55 → neutral
        XCTAssertNil(painter.color(for: t.rows[0], column: 4))      // other column untouched
    }

    func testDayMatcher() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 16
        let friday = Calendar.current.date(from: comps)!
        XCTAssertEqual(DayMatcher.matchesToday(monthCell: "10", dayCell: "16", today: friday), true)
        XCTAssertEqual(DayMatcher.matchesToday(monthCell: "10", dayCell: "15", today: friday), false)
        XCTAssertEqual(DayMatcher.matchesToday(monthCell: "Oct", dayCell: "Fri", today: friday), true)
        XCTAssertNil(DayMatcher.matchesToday(monthCell: "", dayCell: "", today: friday))
    }

    // MARK: Column names

    func testRenamedTableKeepsBothNames() throws {
        let csv = "SYMBOL,var 1,var 2\nAAA,5,10\nBBB,15,3"
        let raw = try SheetService.parse(Data(csv.utf8)).table
        let t = raw.renamed(with: ["var 1": "RSI", "var 2": "Vol Ratio"])
        XCTAssertEqual(t.headers, ["SYMBOL", "RSI", "Vol Ratio"])
        XCTAssertEqual(t.index(of: "rsi"), 1)
        XCTAssertEqual(t.index(of: "var 1"), 1)          // old name still resolves
        XCTAssertEqual(try formula("RSI > 10", t), ["BBB"])
        XCTAssertEqual(try formula("[Vol Ratio] > 5", t), ["AAA"])
    }

    func testRenameClashFallsBack() throws {
        let csv = "SYMBOL,var 1,var 2\nAAA,5,10"
        let raw = try SheetService.parse(Data(csv.utf8)).table
        let t = raw.renamed(with: ["var 1": "X", "var 2": "x"])
        XCTAssertEqual(Set(t.headers).count, 3)            // names stay unique
    }

    func testRenameRewritesSettingsAndFormulas() {
        var s = AppSettings()
        s.filterGroup = FilterGroup(conditions: [
            FilterCondition(column: "var 1", op: .greaterThan, value: "60"),
            FilterCondition(column: "CLOSE", op: .greaterThan, target: .column, otherColumn: "var 2"),
            FilterCondition(kind: .formula, formula: "[var 1] > 60 AND var_3 < 2 AND SECTOR = 'var 1' AND abs(var_3) > 0"),
        ])
        s.cellRules = [CellRule(condition: Rule(column: "var 2", op: .lessThan, value: "0"), shade: .red)]
        let out = ColumnRenamer.rename(s, pairs: [("var 1", "RSI_14"), ("var 2", "EMA 20"), ("var_3", "ATR")])
        XCTAssertEqual(out.filterGroup.conditions[0].column, "RSI_14")
        XCTAssertEqual(out.filterGroup.conditions[1].otherColumn, "EMA 20")
        XCTAssertEqual(out.filterGroup.conditions[2].formula,
                       "RSI_14 > 60 AND ATR < 2 AND SECTOR = 'var 1' AND abs(ATR) > 0")
        XCTAssertEqual(out.cellRules[0].condition.column, "EMA 20")
    }

    // MARK: Sheet links

    func testLiveCSVURL() throws {
        let link = "https://docs.google.com/spreadsheets/d/ABCDEFGHIJKLMNOPQRSTUVWXYZ/edit?pli=1&gid=2066787251#gid=2066787251"
        let url = try XCTUnwrap(SheetService.csvURL(from: link))
        XCTAssertTrue(url.absoluteString.contains("/gviz/tq"))
        XCTAssertTrue(url.absoluteString.contains("tqx=out:csv"))
        XCTAssertTrue(url.absoluteString.contains("gid=2066787251"))
        let fallback = try XCTUnwrap(SheetService.fallbackExportURL(for: url))
        XCTAssertTrue(fallback.absoluteString.contains("/export?format=csv&gid=2066787251"))
    }

    func testUnicodeMinusAndThousands() {
        XCTAssertEqual(NumberParser.parse("−0.04"), -0.04)
        XCTAssertEqual(NumberParser.parse("208,441"), 208441)
    }

    func testPastedExportLinkUsesLiveEndpoint() throws {
        let link = "https://docs.google.com/spreadsheets/d/ABCDEFGHIJKLMNOPQRSTUVWXYZ/export?format=csv&gid=2066787251"
        let url = try XCTUnwrap(SheetService.csvURL(from: link))
        XCTAssertTrue(url.absoluteString.contains("/gviz/tq"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("gid=2066787251"))
    }

    // MARK: History store

    func testHistoryRoundTripCompressed() throws {
        let day1 = "1999-01-04", day2 = "1999-01-05"
        let csv1 = "Symbol,var 1,CLOSE\nAAA,5,100\nBBB,1,50\n"
        let csv2 = "Symbol,CLOSE,var 1\nBBB,55,2\nAAA,110,7\n"      // columns and rows moved
        try HistoryStore.save(csv: Data(csv1.utf8), day: day1, keepDays: 10_000)
        try HistoryStore.save(csv: Data(csv2.utf8), day: day2, keepDays: 10_000)
        defer {
            for d in [day1, day2] {
                try? FileManager.default.removeItem(at: HistoryStore.folder.appendingPathComponent("\(d).csv.lzfse"))
            }
        }
        XCTAssertEqual(String(data: try XCTUnwrap(HistoryStore.load(day1)), encoding: .utf8), csv1)

        let points = HistoryStore.series(symbol: "aaa", labelOriginalHeader: "Symbol",
                                         currentOriginalHeaders: ["Symbol", "var 1", "CLOSE"])
            .filter { $0.day.hasPrefix("1999") }
        XCTAssertEqual(points.map(\.day), [day1, day2])
        XCTAssertEqual(points.map { $0.row.number(2) }, [100, 110])     // CLOSE, matched by name
        XCTAssertEqual(points.map { $0.row.number(1) }, [5, 7])
    }
}

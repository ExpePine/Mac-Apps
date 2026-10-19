import XCTest
@testable import StockScreener

final class StrategyTests: XCTestCase {
    func testExitRules() {
        let path: [Double] = [0, 5, 12, 25, 18, 8, 3, 1, 0, -2, -4, -6]
        XCTAssertEqual(ExitRule(target: 20, stop: nil, trail: nil, hold: 10).simulate(path)!.0, 25)          // take profit day 3
        XCTAssertEqual(ExitRule(target: 20, stop: nil, trail: nil, hold: 10).simulate(path)!.1, 3)
        XCTAssertEqual(ExitRule(target: nil, stop: nil, trail: 15, hold: 10).simulate(path)!.1, 5)           // 108/125 = −13.6%… day 5: 108→ 1.08/1.25 = −13.6%; day 6: 1.03/1.25 = −17.6%
        XCTAssertEqual(ExitRule(target: nil, stop: 3, trail: nil, hold: 10).simulate(path)!.0, -4)           // stop on day 10
        XCTAssertEqual(ExitRule(target: nil, stop: nil, trail: nil, hold: 10).simulate(path)!.0, -4)         // hold to day 10
        XCTAssertNil(ExitRule(target: nil, stop: nil, trail: nil, hold: 50).simulate(path))
    }

    private func row(_ sym: String, day: String, path: [Double], pre: Double?, market: Double?) -> PerfRow {
        PerfRow(symbol: sym, value: "1", eventDay: day, tradingDaysSince: path.count - 1, entry: 100, now: 100 + path.last!,
                returnNow: path.last!, peak: path.max()!, daysToPeak: 0, worst: path.min()!, hitDays: nil, horizons: [],
                benchmark: nil, group: "", path: path, preMove: pre, marketPre: market)
    }

    /// Signals in rising markets rise; in falling markets they fall — the finder and the tree should see it.
    func testFindsMarketFilterAndSeparator() {
        var rows: [PerfRow] = []
        for i in 0..<120 {
            let up = i % 2 == 0
            let path = (0...110).map { k in Double(k) * (up ? 0.4 : -0.3) }
            let day = HistoryStore.dayKey(Calendar.current.date(byAdding: .day, value: i, to: HistoryStore.date(fromKey: "2026-01-01")!)!)
            rows.append(row("S\(i)", day: day, path: path, pre: Double(i % 7) - 3, market: up ? 3 : -3))
        }
        var study = PerfStudy(); study.name = "X"
        let run = PerfRun(study: study, refDay: "2026-06-01", rows: rows, skipped: 0)
        let best = StrategyFinder.find([run]).first!
        XCTAssertTrue(best.filter == .marketUp || best.filter == .marketNotDown, "\(best.filter)")
        XCTAssertGreaterThan(best.testMean!, 0)
        XCTAssertTrue(best.heldUp)

        let st = IncidentAnalyzer.study([run], horizon: 21, sectors: [:])
        XCTAssertEqual(st.features.first?.name, "Nifty's move in the 21 days before")
        XCTAssertGreaterThan(st.features.first!.auc, 0.95)
        XCTAssertTrue(st.leaves.contains { $0.goodRate > 0.95 && $0.conditions.first?.contains("Nifty") == true })
    }
}

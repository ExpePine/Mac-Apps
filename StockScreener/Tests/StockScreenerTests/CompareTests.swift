import XCTest
@testable import StockScreener

final class CompareTests: XCTestCase {
    /// A row whose path rises `perDay` % per day (linear) for `days` days.
    private func row(_ sym: String, perDay: Double, days: Int = 40, dip: Double = 0, pre: Double? = nil, market: Double? = nil) -> PerfRow {
        let path = (0...days).map { k in k == 1 ? -dip : Double(k) * perDay }
        return PerfRow(symbol: sym, value: "\(days)", eventDay: "2026-01-01", tradingDaysSince: days, entry: 100,
                       now: 100 + path.last!, returnNow: path.last!, peak: path.max()!, daysToPeak: days, worst: path.min()!,
                       hitDays: nil, horizons: [], benchmark: nil, group: "", path: path, preMove: pre, marketPre: market)
    }
    private func run(_ name: String, _ rows: [PerfRow]) -> PerfRun {
        var s = PerfStudy(); s.name = name
        return PerfRun(study: s, refDay: "2026-03-01", rows: rows, skipped: 0)
    }

    func testFastStrongSignalWins() {
        let fast = run("Fast", (0..<30).map { row("F\($0)", perDay: 2, dip: 1) })          // +20% in 10 days
        let slow = run("Slow", (0..<30).map { row("S\($0)", perDay: 0.5, dip: 8) })        // +20% in 40 days, deep dip
        let r = PerfCompare.compare([fast, slow], horizon: 21, target: 20, stop: 5, rounds: 200)
        XCTAssertEqual(r.stats.count, 2)
        let f = r.stats.first { $0.name == "Fast" }!, s = r.stats.first { $0.name == "Slow" }!
        XCTAssertEqual(f.median, 42, accuracy: 1e-9)
        XCTAssertEqual(f.kmMedianDays, 10)
        XCTAssertEqual(f.avgBestDay, 21, accuracy: 1e-9)      // a steady climb peaks on the last day of the window
        XCTAssertEqual(f.medianBestDay, 21, accuracy: 1e-9)
        XCTAssertEqual(s.kmMedianDays, 40)
        XCTAssertEqual(r.best.profit, fast.id)
        XCTAssertEqual(r.best.fast, fast.id)
        XCTAssertEqual(r.best.safe, fast.id)
        XCTAssertEqual(s.stopFirst, 1, accuracy: 1e-9)      // −8% on day 1 hits the 5% stop first
        XCTAssertEqual(f.targetFirst, 1, accuracy: 1e-9)
        let pair = r.pairs.first!
        XCTAssertGreaterThan(pair.ciLow, 0)
        XCTAssertEqual(pair.probABetter, 1, accuracy: 1e-9)
    }

    func testKaplanMeierCountsShortHistories() {
        // 2 stocks reach +20% on day 5; 2 have only 3 days of history (censored) → half reached by day 5
        let rows = [row("A", perDay: 4, days: 10), row("B", perDay: 4, days: 10), row("C", perDay: 0, days: 3), row("D", perDay: 0, days: 3)]
        let km = PerfCompare.kaplanMeier(run("x", rows), target: 20)
        XCTAssertEqual(km.first { $0.day == 5 }!.reached, 1, accuracy: 1e-9)   // the 2 still at risk both reached
        XCTAssertEqual(km.first { $0.day == 3 }!.reached, 0, accuracy: 1e-9)
    }

    func testConfluenceAndRegime() {
        let a = run("A", [row("X", perDay: 2, market: 5), row("Y", perDay: 0, market: -5), row("Z", perDay: 1, market: 0)])
        let b = run("B", [row("X", perDay: 2, market: 5)])
        let r = PerfCompare.compare([a, b], horizon: 10, target: 20, stop: 10, rounds: 50)
        XCTAssertEqual(r.confluence.first { $0.count == 2 }?.n, 1)       // X flagged by both
        XCTAssertEqual(r.confluence.first { $0.count == 1 }?.n, 2)
        XCTAssertEqual(r.regime[0].pooled.n, 2)                          // rising market: X in A and in B
        XCTAssertEqual(r.regime[2].pooled.n, 1)
    }

    func testRunRoundTrip() throws {
        let r = run("A", [row("X", perDay: 1, pre: 3, market: 2)])
        let back = try JSONDecoder().decode(PerfRun.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.rows.first?.preMove, 3)
        XCTAssertEqual(back.title, "A")
    }
}

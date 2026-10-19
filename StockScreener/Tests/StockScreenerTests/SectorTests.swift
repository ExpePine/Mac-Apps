import XCTest
@testable import StockScreener

final class SectorTests: XCTestCase {
    private func days(_ n: Int) -> [String] {
        let start = HistoryStore.date(fromKey: "2025-06-01")!
        return (0..<n).map { HistoryStore.dayKey(Calendar.current.date(byAdding: .day, value: $0, to: start)!) }
    }

    func testRotationTrendAndBreadth() {
        let n = 200, d = days(n)
        var book = PriceBook()
        book.series["^NSEI"] = PriceSeries(days: d, closes: (0..<n).map { 1000 * pow(1.0005, Double($0)) })
        // Strong sector: accelerates in the last 40 days; weak sector: falls steadily
        for k in 0..<4 {
            book.series["UP\(k)"] = PriceSeries(days: d, closes: (0..<n).map { t in
                100 * pow(1.001, Double(t)) * (t > 160 ? pow(1.01, Double(t - 160)) : 1) * (1 + Double(k) * 0.01)
            })
            book.series["DN\(k)"] = PriceSeries(days: d, closes: (0..<n).map { t in 100 * pow(0.997, Double(t)) * (1 + Double(k) * 0.01) })
        }
        let r = SectorEngine.compute(members: ["Strong": (0..<4).map { "UP\($0)" }, "Weak": (0..<4).map { "DN\($0)" }],
                                     book: book, minMembers: 3)
        XCTAssertEqual(r.sectors.count, 2)
        let strong = r.sectors.first { $0.name == "Strong" }!, weak = r.sectors.first { $0.name == "Weak" }!
        XCTAssertEqual(strong.rank, 1)
        XCTAssertEqual(strong.quadrant, .leading)
        XCTAssertEqual(strong.trend, .up)
        XCTAssertEqual(strong.breadth, 1, accuracy: 1e-9)
        XCTAssertEqual(weak.trend, .down)
        XCTAssertTrue(weak.quadrant == .lagging || weak.quadrant == .improving)
        XCTAssertEqual(weak.breadth, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(strong.r1m!, weak.r1m!)
        XCTAssertEqual(r.pricedStocks, 8)
    }

    func testDetectNeedsConfirmation() {
        let seq = [("d1", "A"), ("d2", "B"), ("d3", "A"), ("d4", "B"), ("d5", "B"), ("d6", "B")]
        let c = SectorEngine.detect(seq, confirm: 2)
        XCTAssertEqual(c.count, 1)                 // the one-day blip at d2 is ignored
        XCTAssertEqual(c[0].0, "d4")
        XCTAssertEqual(c[0].1, "A"); XCTAssertEqual(c[0].2, "B")
        XCTAssertEqual(SectorEngine.detect(seq, confirm: 1).count, 3)
    }

    func testMerge() {
        let a = PriceSeries(days: ["2026-01-01", "2026-01-02"], closes: [1, 2])
        let b = PriceSeries(days: ["2026-01-02", "2026-01-03"], closes: [5, 6])
        let m = a.merged(with: b)
        XCTAssertEqual(m.days, ["2026-01-01", "2026-01-02", "2026-01-03"])
        XCTAssertEqual(m.closes, [1, 5, 6])
    }
}

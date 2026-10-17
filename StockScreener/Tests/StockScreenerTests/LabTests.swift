import XCTest
@testable import StockScreener

final class LabTests: XCTestCase {

    /// 200 stocks: flag (feature 0) = 1 and score (feature 1) high → gainer; feature 2 is noise.
    private func dataset() -> [LabeledStock] {
        var rng = SeededRandom(seed: 42)
        return (0..<200).map { i in
            let flag = Double(i % 2)
            let score = Double((i * 37) % 100)
            let noise = Double(rng.next() % 1000) / 10
            let gainer = flag == 1 && score > 66
            return LabeledStock(symbol: "S\(i)", features: [flag, score, noise],
                                gain: gainer ? 40 : 5, isGainer: gainer)
        }
    }

    func testMinerFindsTheGainerCombination() {
        let data = dataset()
        let combos = PatternMiner.mine(data, featureCount: 3, names: ["Flag", "Score", "Noise"])
        XCTAssertFalse(combos.isEmpty)
        let top = combos[0]
        let features = Set(top.items.map(\.feature))
        XCTAssertTrue(features.contains(0) && features.contains(1), "top combo: \(top.items.map { $0.describe(["Flag", "Score", "Noise"]) })")
        XCTAssertGreaterThan(top.lift, 3)
        XCTAssertEqual(top.hitRate, 1, accuracy: 0.001)
    }

    func testTinyNetLearnsSeparablePattern() {
        let data = dataset()
        var net = TinyNet(inputs: 3)
        net.train(data.map(\.features), data.map(\.isGainer), epochs: 300, lr: 0.01)
        let scores = data.map { net.predict($0.features) }
        XCTAssertGreaterThan(ModelMetrics.auc(scores, data.map(\.isGainer)), 0.9)
    }

    func testAUC() {
        XCTAssertEqual(ModelMetrics.auc([0.9, 0.8, 0.2, 0.1], [true, true, false, false]), 1, accuracy: 1e-9)
        XCTAssertEqual(ModelMetrics.auc([0.1, 0.2, 0.8, 0.9], [true, true, false, false]), 0, accuracy: 1e-9)
        XCTAssertEqual(ModelMetrics.precisionAtK([0.9, 0.8, 0.2, 0.1], [true, false, true, false], k: 2), 0.5, accuracy: 1e-9)
    }

    func testPriceSeriesMath() {
        let s = PriceSeries(days: ["2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06"],
                            closes: [100, 110, 99, 143])
        XCTAssertEqual(s.dailyChange(on: "2026-10-02")!, 10, accuracy: 1e-9)
        XCTAssertNil(s.dailyChange(on: "2026-10-03"))                 // holiday: no trading
        XCTAssertEqual(s.change(over: 3, endingOn: "2026-10-06")!, 43, accuracy: 1e-9)
        XCTAssertEqual(s.maxGain(within: 2, after: "2026-10-01")!, 10, accuracy: 1e-9)
        XCTAssertEqual(s.maxGain(within: 5, after: "2026-10-01")!, 43, accuracy: 1e-9)
        XCTAssertEqual(s.index(onOrBefore: "2026-10-04"), 1)
        XCTAssertEqual(YahooClient.yahooSymbol("m&m"), "M%26M.NS")
    }
}

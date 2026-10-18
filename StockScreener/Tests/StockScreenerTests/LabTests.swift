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

final class FeatureClassifierTests: XCTestCase {
    private func kind(_ name: String, _ values: [Double?], label: Bool = false) -> ColumnKind {
        FeatureClassifier.classify(name: name, numbers: values, isLabel: label).0
    }
    private let prices: [Double?] = (0..<100).map { Double(20 + $0 * $0 * 3) }   // 20 … ~29,400
    private let small: [Double?] = (0..<100).map { Double($0 % 40) + 30 }        // 30 … 69

    func testKinds() {
        XCTAssertEqual(kind("SYMBOL", Array(repeating: nil, count: 100), label: true), .identifier)
        XCTAssertEqual(kind("D_CLOSE", prices), .priceLevel)
        XCTAssertEqual(kind("EMA_20", prices), .priceLevel)
        XCTAssertEqual(kind("PrevClose", prices), .priceLevel)
        XCTAssertEqual(kind("D_MONTH", small.map { $0.map { Double(Int($0) % 12 + 1) } }), .date)
        XCTAssertEqual(kind("D_DAY", small), .date)
        XCTAssertEqual(kind("RSI_14", small), .feature)
        XCTAssertEqual(kind("Vol Ratio", small), .feature)
        XCTAssertEqual(kind("Close vs EMA %", small), .feature)
        XCTAssertEqual(kind("Volume", prices), .rawSize)
        XCTAssertEqual(kind("SECTOR", Array(repeating: nil, count: 100)), .identifier)
        XCTAssertEqual(kind("Long_Green", (0..<100).map { Double($0 % 2) }), .feature)
        XCTAssertEqual(kind("var3", prices), .priceLevel)          // unnamed but looks like prices
        XCTAssertEqual(kind("var4", small), .feature)
        XCTAssertEqual(kind("Flat", Array(repeating: 1, count: 100)), .constant)
    }

    func testWords() {
        XCTAssertEqual(FeatureClassifier.words("D_close"), ["d", "close", "dclose"])
        XCTAssertTrue(FeatureClassifier.words("EMA20").contains("ema"))
        XCTAssertTrue(FeatureClassifier.words("PrevClose").contains("close"))
    }
}

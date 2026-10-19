import XCTest
@testable import StockScreener

final class StatsTests: XCTestCase {
    func testNormal() {
        XCTAssertEqual(Stats.normalCDF(0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Stats.normalCDF(1.959964), 0.975, accuracy: 1e-5)
        XCTAssertEqual(Stats.normalQuantile(0.975), 1.959964, accuracy: 1e-5)
        XCTAssertEqual(Stats.normalQuantile(0.01), -2.326348, accuracy: 1e-5)
    }

    func testBinomialAndBH() {
        // P(X ≥ 8 | n=10, p=0.5) = 56/1024
        XCTAssertEqual(Stats.binomialUpperTail(k: 8, n: 10, p: 0.5), 56.0 / 1024, accuracy: 1e-9)
        XCTAssertEqual(Stats.binomialUpperTail(k: 0, n: 10, p: 0.3), 1)
        let q = Stats.benjaminiHochberg([0.01, 0.04, 0.03, 0.5])
        XCTAssertEqual(q[0], 0.04, accuracy: 1e-9)
        XCTAssertEqual(q[1], 0.04 * 4 / 3, accuracy: 1e-9)
        XCTAssertEqual(q[2], 0.04 * 4 / 3, accuracy: 1e-9)   // monotone step-up
        XCTAssertEqual(q[3], 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(Stats.benjaminiHochberg([0.01], totalTests: 100)[0], 0.99)
    }

    func testDeflatedSharpe() {
        var rng = SeededRandom(seed: 3)
        let good = (0..<300).map { _ in 1.0 + rng.normal() * 2 }      // Sharpe ≈ 0.5 per trade
        let flat = (0..<300).map { _ in rng.normal() * 2 }
        let a = Stats.deflatedSharpe(returns: good, trials: 100, sharpeVarianceAcrossTrials: 0.01)!
        let b = Stats.deflatedSharpe(returns: flat, trials: 100, sharpeVarianceAcrossTrials: 0.01)!
        XCTAssertGreaterThan(a, 0.99)
        XCTAssertLessThan(b, 0.5)
        // more trials → harsher
        let few = Stats.deflatedSharpe(returns: flat.map { $0 + 0.3 }, trials: 2, sharpeVarianceAcrossTrials: 0.01)!
        let many = Stats.deflatedSharpe(returns: flat.map { $0 + 0.3 }, trials: 1000, sharpeVarianceAcrossTrials: 0.01)!
        XCTAssertGreaterThan(few, many)
    }

    func testBoostedTreesAndShapley() {
        var rng = SeededRandom(seed: 9)
        var xs: [[Double?]] = [], ys: [Bool] = []
        for _ in 0..<800 {
            let a = rng.normal(), b = rng.normal(), noise = rng.normal()
            xs.append([a, b, noise, rng.next() % 5 == 0 ? nil : noise])
            ys.append(a + 0.5 * b + 0.3 * rng.normal() > 0)
        }
        let m = GBM.train(Array(xs[0..<600]), Array(ys[0..<600]), rounds: 80, minLeaf: 15)
        let auc = ModelMetrics.auc(xs[600...].map { m.predict($0) }, Array(ys[600...]))
        XCTAssertGreaterThan(auc, 0.85, "AUC \(auc)")
        // Shapley efficiency: Σφ = f(x) − E[f]  (E[f] = all features unknown)
        let groups = [0, 1, 2, 2]
        let x = xs[700]
        let phi = m.shap(x, groupOf: groups, groups: 3)
        let expected = m.conditional(x, known: { _ in false })
        XCTAssertEqual(phi.reduce(0, +), m.rawScore(x) - expected, accuracy: 1e-9)
        // the strongest real driver gets the biggest average |φ|
        var imp = [0.0, 0.0, 0.0]
        for xi in xs[600..<700] { let p = m.shap(xi, groupOf: groups, groups: 3); for g in 0..<3 { imp[g] += abs(p[g]) } }
        XCTAssertGreaterThan(imp[0], imp[1]); XCTAssertGreaterThan(imp[1], imp[2])
    }

    func testCombosGetQValues() {
        var data: [LabeledStock] = []
        for i in 0..<300 {
            let flag = Double(i % 2), score = Double((i * 37) % 100)
            data.append(LabeledStock(symbol: "S\(i)", features: [flag, score], gain: 0, isGainer: flag == 1 && score > 66))
        }
        let combos = PatternMiner.mine(data, featureCount: 2, names: ["Flag", "Score"])
        XCTAssertNotNil(combos.first?.qValue)
        XCTAssertLessThan(combos.first!.qValue!, 0.001)
    }
}

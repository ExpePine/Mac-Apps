import XCTest
@testable import StockScreener

final class PanelTests: XCTestCase {

    func testRanksCentredWithTiesAndBlanks() {
        let r = PanelBuilder.ranks([10, nil, 30, 20, 20])
        XCTAssertEqual(r[0], -1, accuracy: 1e-9)
        XCTAssertEqual(r[1], 0, accuracy: 1e-9)          // blank → middle
        XCTAssertEqual(r[2], 1, accuracy: 1e-9)
        XCTAssertEqual(r[3], r[4], accuracy: 1e-9)       // ties share a rank
        XCTAssertEqual(r[3], 0, accuracy: 1e-9)
    }

    func testForwardGain() {
        let s = PriceSeries(days: ["2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06"], closes: [100, 130, 90, 110])
        let f = s.forward(2, from: "2026-10-01")!
        XCTAssertEqual(f.change, -10, accuracy: 1e-9)
        XCTAssertEqual(f.maxGain, 30, accuracy: 1e-9)
        XCTAssertNil(s.forward(3, from: "2026-10-02"))    // not enough days yet
    }

    /// Backward pass must match numerical gradients (MLP + linear + pairwise parts).
    func testGradientsMatchNumerical() {
        var net = PanelNet(inputs: 5, outputs: 2, seed: 3)
        var rng = SeededRandom(seed: 9)
        for i in net.p.indices { net.p[i] += rng.normal() * 0.1 }    // make the pairwise part non-trivial
        let x: [Double] = [0.5, -0.3, 0.9, 0, -0.7]
        let g: [Double] = [0.7, -1.3]                                  // dLoss/dOut, loss = g·out
        var grad = [Double](repeating: 0, count: net.p.count)
        net.backward(x, net.forward(x), g, &grad)
        let eps = 1e-6
        for q in stride(from: 0, to: net.p.count, by: 3) {
            var a = net, b = net
            a.p[q] += eps; b.p[q] -= eps
            let la = zip(a.predict(x), g).reduce(0) { $0 + $1.0 * $1.1 }
            let lb = zip(b.predict(x), g).reduce(0) { $0 + $1.0 * $1.1 }
            XCTAssertEqual(grad[q], (la - lb) / (2 * eps), accuracy: 1e-5, "param \(q)")
        }
    }

    /// Synthetic panel: forward gain depends on feature 0 and on the PAIR (1 × 2); feature 3 is noise.
    func testLearnsSignalAndPair() {
        var rng = SeededRandom(seed: 1)
        var rows: [PanelRow] = []
        for day in 0..<20 {
            var dayRows: [PanelRow] = []
            for s in 0..<120 {
                let x = (0..<4).map { _ in Double(rng.next() % 2001) / 1000 - 1 }
                let gain = 6 * x[0] + 8 * x[1] * x[2] + Double(rng.next() % 1000) / 1000 - 0.5
                dayRows.append(PanelRow(day: day, symbol: "S\(s)", x: x, raw: x.map { Optional($0) },
                                        fwd: [gain], fwdMax: [max(0, gain)], target: [nil]))
            }
            let r = PanelBuilder.ranks(dayRows.map { $0.fwd[0] })
            for k in dayRows.indices { dayRows[k].target[0] = r[k] }
            rows += dayRows
        }
        let train = rows.indices.filter { rows[$0].day < 14 }
        let val = rows.indices.filter { rows[$0].day >= 14 && rows[$0].day < 16 }
        let test = rows.indices.filter { rows[$0].day >= 16 }
        let net = PanelTrainer.train(rows, train: train, val: val, main: 0, threshold: 5, seed: 7)
        let testRows = test.map { rows[$0] }
        let ic = PanelTrainer.dailyIC(scores: testRows.map { net.predict($0.x)[0] }, rows: testRows, main: 0).mean
        XCTAssertGreaterThan(ic, 0.6, "IC \(ic)")
        // The pair 1×2 should outweigh pairs with the noise column
        XCTAssertGreaterThan(abs(net.pairWeight(1, 2)), abs(net.pairWeight(1, 3)))
        XCTAssertGreaterThan(abs(net.pairWeight(1, 2)), abs(net.pairWeight(2, 3)))

        // Shuffled labels → near-zero IC
        let fake = PanelTrainer.shuffledLabels(rows, indices: train + val, seed: 3)
        let luck = PanelTrainer.train(fake, train: train, val: val, main: 0, threshold: 5, seed: 8)
        let luckIC = PanelTrainer.dailyIC(scores: testRows.map { luck.predict($0.x)[0] }, rows: testRows, main: 0).mean
        XCTAssertLessThan(abs(luckIC), ic - 0.2, "luck IC \(luckIC) vs real \(ic)")   // a random net can line up with a strong input by chance
    }

    func testDeltaFeatures() {
        let today: PanelBuilder.DayValues = ["A": [10], "B": [20], "C": [30]]
        let prev: PanelBuilder.DayValues = ["A": [5], "B": [25], "C": [30]]
        let x = PanelBuilder.features(today: today, prev1: prev, prev5: nil, symbols: ["A", "B", "C"], columns: 1)
        XCTAssertEqual(x[0][1], 1, accuracy: 1e-9)    // A rose most
        XCTAssertEqual(x[1][1], -1, accuracy: 1e-9)   // B fell
        XCTAssertEqual(x[2][2], 0, accuracy: 1e-9)    // no Δ5d → middle
    }
}

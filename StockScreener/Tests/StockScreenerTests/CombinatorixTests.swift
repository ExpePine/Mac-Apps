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

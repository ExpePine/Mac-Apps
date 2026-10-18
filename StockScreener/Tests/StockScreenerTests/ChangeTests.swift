import XCTest
@testable import StockScreener

final class ChangeTests: XCTestCase {
    private func t(_ csv: String) throws -> SheetTable { try SheetService.parse(Data(csv.utf8)).table }

    func testCards() throws {
        let before = try t("SYMBOL,RSI,D_Trigger\nAAA,50,\nBBB,70,3\nCCC,40,1\nOLD,10,\n")
        let now = try t("SYMBOL,RSI,D_Trigger\nAAA,62,2\nBBB,65,\nCCC,40,1\nNEW,30,\n")
        func run(_ card: ChangeCard, fNow: Set<String> = [], fBefore: Set<String> = []) -> [String] {
            ChangeEngine.evaluate(card, current: now, previous: before, label: 0, filterNow: fNow, filterBefore: fBefore, watch: [])
                .items.map(\.symbol)
        }
        XCTAssertEqual(run(ChangeCard(name: "", kind: .increased, column: "RSI", color: "#000000")), ["AAA"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .increased, column: "RSI", amount: 20, unit: .percent, color: "#000000")), ["AAA"])  // +24%
        XCTAssertEqual(run(ChangeCard(name: "", kind: .increased, column: "RSI", amount: 30, unit: .percent, color: "#000000")), [])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .decreased, column: "RSI", color: "#000000")), ["BBB"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .crossedAbove, column: "RSI", amount: 60, color: "#000000")), ["AAA"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .crossedBelow, column: "RSI", amount: 68, color: "#000000")), ["BBB"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .appeared, column: "D_Trigger", color: "#000000")), ["AAA"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .cleared, column: "D_Trigger", color: "#000000")), ["BBB"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .newStock, column: "RSI", color: "#000000")), ["NEW"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .droppedStock, column: "RSI", color: "#000000")), ["OLD"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .enteredFilter, column: "RSI", color: "#000000"),
                           fNow: ["AAA", "CCC"], fBefore: ["BBB", "CCC"]), ["AAA"])
        XCTAssertEqual(run(ChangeCard(name: "", kind: .leftFilter, column: "RSI", color: "#000000"),
                           fNow: ["AAA", "CCC"], fBefore: ["BBB", "CCC"]), ["BBB"])
        let missing = ChangeEngine.evaluate(ChangeCard(name: "", kind: .increased, column: "Nope", color: "#000000"),
                                            current: now, previous: before, label: 0, filterNow: [], filterBefore: [], watch: [])
        XCTAssertNotNil(missing.problem)
    }

    func testCardDecodesOldOrPartialJSON() throws {
        let json = #"{"name":"X","kind":"crossedAbove","column":"RSI","amount":60}"#
        let c = try JSONDecoder().decode(ChangeCard.self, from: Data(json.utf8))
        XCTAssertEqual(c.kind, .crossedAbove)
        XCTAssertEqual(c.scope, .all)
        XCTAssertTrue(c.isEnabled)
    }
}

import XCTest
@testable import SamsaraCore

final class ParserTests: XCTestCase {
    let ist = TimeZone(identifier: "Asia/Kolkata")!

    // Mirrors the quirks seen in a real Samsara export (made-up values).
    let fixture = "\u{FEFF}ID,Product,Price,Category,Platform/Vendor,\"Saved By\",Quantity,Date\n" +
        "766,Zomato,104,Eat-Out,,Dona,1,\"2026-10-21 20:32:33\"\n" +
        "761,\"Frozen Mixed V...\",₹59,Vegetables,\"Flipkart Minutes\",Dona,\"1 x 500 g\",\"2026-10-21 20:31:33\"\n" +
        "755,\"Peanuts | Salted, Spicy\",₹61,Snack,Zepto,Raja,\"1 pack (160 g) - 1 unit\",\"2026-10-20 20:08:42\"\n" +
        "3,\"Potato Chips\",\"₹50 ₹42\",Uncategorized,,,\"90 g x 1\",\"2026-07-28 22:45:29\"\n" +
        "4,\"Masala Dosa\",,Eat-Out,\"Dosa N Chatny\\'s\",Dona,1,\"2026-09-02 13:00:00\"\n" +
        "5,\"Bike petrol\",\"1,500\",FUEL,,Dona,1,\"2026-09-15 09:00:00\"\n" +
        "354,\"Mineral Water\",20.00,Beverages,Swiggy,Dona,1,\"0000-00-00 00:00:00\"\r\n" +
        "\n"

    func testParsesSamsaraQuirks() throws {
        let r = try ExpenseParser.parse(text: fixture, timeZone: ist)
        XCTAssertEqual(r.expenses.count, 7)
        XCTAssertEqual(r.header.first, "ID")   // BOM stripped

        let byID = Dictionary(uniqueKeysWithValues: r.expenses.map { ($0.id, $0) })
        XCTAssertEqual(byID["766"]?.amount, 104)
        XCTAssertEqual(byID["766"]?.vendor, "")
        XCTAssertEqual(byID["766"]?.vendorLabel, "Not set")
        XCTAssertEqual(byID["761"]?.amount, 59)
        XCTAssertEqual(byID["761"]?.vendor, "Flipkart Minutes")
        XCTAssertEqual(byID["755"]?.product, "Peanuts | Salted, Spicy")
        XCTAssertEqual(byID["755"]?.savedBy, "Raja")
        XCTAssertEqual(byID["3"]?.amount, 42)                    // MRP and price paid → paid
        XCTAssertEqual(byID["3"]?.personLabel, "Unknown")
        XCTAssertEqual(byID["4"]?.amount, 0)                     // empty price
        XCTAssertEqual(byID["4"]?.vendor, "Dosa N Chatny's")     // \' unescaped
        XCTAssertEqual(byID["5"]?.amount, 1500)
        XCTAssertEqual(byID["354"]?.amount, 20)
        XCTAssertNil(byID["354"]?.date)                          // 0000-00-00

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ist
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: byID["766"]!.date!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 10, 21, 20, 32])

        XCTAssertEqual(r.warnings.count, 2)
    }

    func testPriceParsing() {
        XCTAssertEqual(ExpenseParser.parsePrice("₹9"), 9)
        XCTAssertEqual(ExpenseParser.parsePrice("99.50"), 99.5)
        XCTAssertEqual(ExpenseParser.parsePrice("Rs. 1,250.00"), 1250)
        XCTAssertEqual(ExpenseParser.parsePrice("₹50 ₹42"), 42)
        XCTAssertNil(ExpenseParser.parsePrice(""))
        XCTAssertNil(ExpenseParser.parsePrice("free"))
    }

    func testMissingColumnsThrows() {
        XCTAssertThrowsError(try ExpenseParser.parse(text: "Name,Cost\nA,1\n")) { err in
            XCTAssertEqual(err as? ParseError, .missingColumns(["Product"]))
        }
        XCTAssertThrowsError(try ExpenseParser.parse(text: ""))
    }

    func testDuplicateAndMissingIDsAreMadeUnique() throws {
        let text = "ID,Product,Price\n1,A,10\n1,B,20\n,C,30\n"
        let r = try ExpenseParser.parse(text: text)
        XCTAssertEqual(Set(r.expenses.map(\.id)).count, 3)
    }

    func testCSVRoundTrip() throws {
        let r = try ExpenseParser.parse(text: fixture, timeZone: ist)
        let out = ExpenseParser.csv(for: r.expenses, timeZone: ist)
        let again = try ExpenseParser.parse(text: out, timeZone: ist)
        XCTAssertEqual(again.expenses.map(\.amount), r.expenses.map(\.amount))
        XCTAssertEqual(again.expenses.map(\.product), r.expenses.map(\.product))
        XCTAssertEqual(again.expenses.map(\.date), r.expenses.map(\.date))
    }

    func testCSVQuotedNewline() {
        let rows = CSV.parse("a,b\n\"line1\nline2\",\"say \"\"hi\"\"\"\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["line1\nline2", "say \"hi\""])
    }

    func testSampleDataParses() throws {
        let r = try ExpenseParser.parse(text: SampleData.csv(timeZone: ist), timeZone: ist)
        XCTAssertGreaterThan(r.expenses.count, 150)
        XCTAssertEqual(r.expenses.filter { $0.date == nil }.count, 1)
        XCTAssertGreaterThan(Analyzer.total(r.expenses), 0)
    }
}

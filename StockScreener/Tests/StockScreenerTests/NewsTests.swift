import XCTest
@testable import StockScreener

final class NewsTests: XCTestCase {
    func testRSSParsing() {
        let xml = """
        <?xml version="1.0"?><rss><channel><title>x</title>
        <item><title>Tata Motors jumps 6% on strong JLR sales - Moneycontrol</title><link>https://news.google.com/a</link>
        <pubDate>Mon, 19 Oct 2026 05:30:00 GMT</pubDate><source url="https://moneycontrol.com">Moneycontrol</source></item>
        <item><title>Second &amp; story</title><link>https://b</link><pubDate>bad date</pubDate></item>
        </channel></rss>
        """
        let h = RSSParser.parse(Data(xml.utf8))
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h[0].title, "Tata Motors jumps 6% on strong JLR sales")      // " - Source" removed
        XCTAssertEqual(h[0].source, "Moneycontrol")
        XCTAssertNotNil(h[0].date)
        XCTAssertEqual(h[1].title, "Second & story")
        XCTAssertNil(h[1].date)
    }

    func testIndexSymbols() {
        XCTAssertEqual(YahooClient.yahooSymbol("^BSESN"), "%5EBSESN")
    }
}

final class QuickFilterTests: XCTestCase {
    func testQuickFilter() throws {
        let t = try SheetService.parse(Data("SYMBOL,RSI,SECTOR\nA,55,IT\nB,72,Bank\nC,,IT Services\n".utf8)).table
        var f = ColumnQuickFilter(); f.min = 60
        XCTAssertEqual(t.rows.filter { f.passes($0, column: 1) }.map { $0.text(0) }, ["B"])
        f = ColumnQuickFilter(); f.contains = "it"
        XCTAssertEqual(t.rows.filter { f.passes($0, column: 2) }.map { $0.text(0) }, ["A", "C"])
        f = ColumnQuickFilter(); f.nonEmpty = true
        XCTAssertEqual(t.rows.filter { f.passes($0, column: 1) }.count, 2)
        XCTAssertFalse(ColumnQuickFilter().isActive)
    }
}

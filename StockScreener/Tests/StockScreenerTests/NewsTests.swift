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

final class ChartLinkTests: XCTestCase {
    func testImportAndPattern() throws {
        let csv = """
        Symbol,Link1
        20MICRONS,https://in.tradingview.com/chart/vnr7IqQO/?symbol=NSE%3A20MICRONS
        360ONE,https://in.tradingview.com/chart/I7dkKisW/?symbol=NSE%3A360ONE
        3MINDIA,https://in.tradingview.com/chart/I7dkKisW/?symbol=NSE%3A3MINDIA
        """
        let t = try SheetService.parse(Data(csv.utf8)).table
        let b = ChartLinkBook.from(t, symbolColumn: "Symbol")
        XCTAssertEqual(b.columns, ["Link1"])
        XCTAssertEqual(b.templates.first, "https://in.tradingview.com/chart/I7dkKisW/?symbol=NSE%3A{SYMBOL}")
        XCTAssertEqual(b.url(for: "20microns", fallbackTemplate: "")?.absoluteString, "https://in.tradingview.com/chart/vnr7IqQO/?symbol=NSE%3A20MICRONS")
        XCTAssertEqual(b.url(for: "M&M", fallbackTemplate: "")?.absoluteString, "https://in.tradingview.com/chart/I7dkKisW/?symbol=NSE%3AM%26M")
    }
}

final class PickTests: XCTestCase {
    func testPickRoundTrip() throws {
        let p = Pick(symbol: "TCS", day: "2026-10-19", grade: .ok, change: 6.2, close: 4100, sector: "IT", why: "Strong Q2", note: "watch 4200")
        let back = try JSONDecoder().decode([Pick].self, from: JSONEncoder().encode([p]))
        XCTAssertEqual(back, [p])
    }
}

final class ChartTemplateTests: XCTestCase {
    func testTemplateFromLink() {
        XCTAssertEqual(ScreenerViewModel.templateFromLink("https://in.tradingview.com/chart/vnr7IqQO/?symbol=NSE%3ATCS"),
                       "https://in.tradingview.com/chart/vnr7IqQO/?symbol=NSE%3A{SYMBOL}")
        XCTAssertEqual(ScreenerViewModel.templateFromLink("https://in.tradingview.com/chart/ab/?symbol=NSE:INFY&interval=W"),
                       "https://in.tradingview.com/chart/ab/?symbol=NSE:{SYMBOL}&interval=W")
    }
}

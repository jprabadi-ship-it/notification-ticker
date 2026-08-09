import Foundation
import XCTest
@testable import NotificationTicker

final class FeedXMLParserTests: XCTestCase {
    func testParsesRSSFeed() {
        let xml = """
        <rss version="2.0"><channel><title>NHKニュース</title>
        <item><title>最初のニュース</title><link>https://example.com/1</link><guid>news-1</guid></item>
        <item><title>次のニュース</title><link>https://example.com/2</link></item>
        </channel></rss>
        """
        let feed = FeedXMLParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(feed?.title, "NHKニュース")
        XCTAssertEqual(feed?.items, [
            FeedItem(title: "最初のニュース", identifier: "news-1"),
            FeedItem(title: "次のニュース", identifier: "https://example.com/2")
        ])
    }

    func testParsesAtomFeed() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Example Atom</title>
        <entry><title>Atom headline</title><id>tag:example,1</id><link href="https://example.com/a" /></entry>
        </feed>
        """
        let feed = FeedXMLParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(feed?.title, "Example Atom")
        XCTAssertEqual(feed?.items, [FeedItem(title: "Atom headline", identifier: "tag:example,1")])
    }

    func testParsesCDATATitles() {
        let xml = """
        <rss version="2.0"><channel><title><![CDATA[ギズモード・ジャパン]]></title>
        <item><title><![CDATA[水に濡れないサーフィン]]></title>
        <guid>https://example.com/giz</guid>
        <pubDate>Mon, 27 Jul 2026 04:00:00 GMT</pubDate></item>
        </channel></rss>
        """
        let feed = FeedXMLParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(feed?.title, "ギズモード・ジャパン")
        XCTAssertEqual(feed?.items.first?.title, "水に濡れないサーフィン")
        XCTAssertNotNil(feed?.items.first?.publishedAt)
    }

    func testHeadlineKeepsPublishedTime() {
        let item = FeedItem(
            title: "見出し",
            identifier: "id-1",
            publishedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(FeedMonitor.headline(feedTitle: "フィード", item: item).hasSuffix("見出し"))
    }

    func testDetectsEarthquakeHeadlines() {
        XCTAssertTrue(FeedMonitor.isEarthquakeHeadline("千葉県東方沖で震度1の地震"))
        XCTAssertTrue(FeedMonitor.isEarthquakeHeadline("津波注意報を解除"))
        XCTAssertTrue(FeedMonitor.isEarthquakeHeadline("緊急地震速報を発表"))
    }

    func testKeepsUnrelatedHeadlines() {
        XCTAssertFalse(FeedMonitor.isEarthquakeHeadline("日経平均が続伸"))
        XCTAssertFalse(FeedMonitor.isEarthquakeHeadline("台風5号が接近"))
    }

    func testParsesPublishedTimeAndBuildsSingleLineHeadline() {
        let xml = """
        <rss version="2.0"><channel><title>NHKニュース</title>
        <item><title>速報</title><guid>news-1</guid><pubDate>Tue, 28 Jul 2026 09:05:00 +0900</pubDate></item>
        </channel></rss>
        """
        let item = FeedXMLParser.parse(data: Data(xml.utf8))?.items.first
        XCTAssertNotNil(item?.publishedAt)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let components = calendar.dateComponents([.hour, .minute], from: item!.publishedAt!)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 5)

        let headline = FeedMonitor.headline(
            feedTitle: "NHKニュース",
            item: FeedItem(title: "速報", identifier: "news-1", publishedAt: item?.publishedAt)
        )
        XCTAssertFalse(headline.contains("NHKニュース"))
        XCTAssertTrue(headline.hasPrefix("09:05"))
        XCTAssertTrue(headline.hasSuffix("  •  速報"))
        XCTAssertEqual(headline.components(separatedBy: "\n").count, 1)
    }
}

import Foundation
import XCTest
@testable import NotificationTicker

final class JMAEarthquakeParserTests: XCTestCase {
    func testParsesJMAFeedEntry() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>震源・震度に関する情報</title>
          <id>quake-1</id><updated>2026-07-20T01:02:03Z</updated>
          <link type="application/xml" href="https://example.com/quake.xml"/>
        </entry></feed>
        """
        let entries = JMAFeedParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(entries?.first?.id, "quake-1")
        XCTAssertEqual(entries?.first?.title, "震源・震度に関する情報")
        XCTAssertEqual(entries?.first?.link, "https://example.com/quake.xml")
        XCTAssertNotNil(entries?.first?.updated)
    }

    func testReportsIntensityFourWithNoTsunami() {
        let report = parseReport(maxInt: "4", comment: "この地震による津波の心配はありません。")
        XCTAssertEqual(report?.hypocenter, "千葉県東方沖")
        XCTAssertEqual(report?.magnitude, "5.1")
        XCTAssertEqual(report?.maxIntensity, "4")
        XCTAssertEqual(report?.tsunamiStatus, "なし")
        XCTAssertTrue(report?.meetsAlertThreshold == true)
    }

    func testReportsStrongIntensityAndTsunamiWarning() {
        let report = parseReport(maxInt: "6-", comment: "津波警報・津波注意報を発表中です。")
        XCTAssertEqual(report?.maxIntensity, "6弱")
        XCTAssertEqual(report?.tsunamiStatus, "あり")
        XCTAssertTrue(report?.tickerText.contains("津波あり") == true)
    }

    func testDoesNotAlertBelowIntensityFour() {
        XCTAssertFalse(parseReport(maxInt: "3", comment: "津波の心配はありません。")?.meetsAlertThreshold == true)
    }

    private func parseReport(maxInt: String, comment: String) -> JMAEarthquakeReport? {
        let xml = """
        <Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
          <Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/"><EventID>event-1</EventID></Head>
          <Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/seismology1/">
            <Earthquake><Hypocenter><Area><Name>千葉県東方沖</Name></Area></Hypocenter><Magnitude>5.1</Magnitude></Earthquake>
            <Intensity><Observation><MaxInt>\(maxInt)</MaxInt></Observation></Intensity>
            <Comments><ForecastComment><Text>\(comment)</Text></ForecastComment></Comments>
          </Body>
        </Report>
        """
        return JMAEarthquakeXMLParser.parse(data: Data(xml.utf8))
    }
}

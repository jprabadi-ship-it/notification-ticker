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
        XCTAssertTrue(report?.meetsAlertThreshold(minimumIntensity: "4") == true)
    }

    func testReportsStrongIntensityAndTsunamiWarning() {
        let report = parseReport(maxInt: "6-", comment: "津波警報・津波注意報を発表中です。")
        XCTAssertEqual(report?.maxIntensity, "6弱")
        XCTAssertEqual(report?.tsunamiStatus, "あり")
        XCTAssertTrue(report?.tickerText.contains("津波あり") == true)
    }

    func testDoesNotAlertBelowSelectedIntensity() {
        let report = parseReport(maxInt: "3", comment: "津波の心配はありません。")

        XCTAssertFalse(report?.meetsAlertThreshold(minimumIntensity: "4") == true)
        XCTAssertTrue(report?.meetsAlertThreshold(minimumIntensity: "3") == true)
        XCTAssertTrue(report?.meetsAlertThreshold(minimumIntensity: "1") == true)
    }

    func testTreatsWeakAndStrongFiveAsDistinctThresholds() {
        let report = parseReport(maxInt: "5-", comment: "津波の心配はありません。")

        XCTAssertTrue(report?.meetsAlertThreshold(minimumIntensity: "5弱") == true)
        XCTAssertFalse(report?.meetsAlertThreshold(minimumIntensity: "5強") == true)
    }

    func testParsesAreaIntensitiesAndFindsLocalArea() {
        let report = parseObservationReport()

        XCTAssertEqual(report?.localIntensity(matching: "練馬区")?.intensity, "3")
        // 都道府県だけ書いた場合は、その都道府県の値を拾う。
        XCTAssertEqual(report?.localIntensity(matching: "東京都")?.intensity, "4")
        // 「東京都 練馬区」のように書いたときは細かい方を優先する。
        XCTAssertEqual(report?.localIntensity(matching: "東京都 練馬区")?.name, "練馬区")
        XCTAssertNil(report?.localIntensity(matching: "沖縄県"))
    }

    func testAppendsLocalIntensityToTickerText() {
        let report = parseObservationReport()

        XCTAssertTrue(report?.tickerText(localArea: "練馬区").hasSuffix("練馬区 震度3") == true)
        XCTAssertTrue(report?.tickerText(localArea: "沖縄県").hasSuffix("沖縄県 観測なし") == true)
        // 地点が空欄なら本文はそのまま。
        XCTAssertEqual(report?.tickerText(localArea: "  "), report?.tickerText)
    }

    private func parseObservationReport() -> JMAEarthquakeReport? {
        let xml = """
        <Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
          <Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/"><EventID>event-2</EventID></Head>
          <Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/seismology1/">
            <Earthquake><Hypocenter><Area><Name>東京湾</Name></Area></Hypocenter><Magnitude>5.0</Magnitude></Earthquake>
            <Intensity><Observation>
              <MaxInt>4</MaxInt>
              <Pref><Name>東京都</Name><MaxInt>4</MaxInt>
                <Area><Name>東京都23区</Name><MaxInt>4</MaxInt>
                  <City><Name>練馬区</Name><MaxInt>3</MaxInt></City>
                  <City><Name>千代田区</Name><MaxInt>4</MaxInt></City>
                </Area>
              </Pref>
            </Observation></Intensity>
            <Comments><ForecastComment><Text>この地震による津波の心配はありません。</Text></ForecastComment></Comments>
          </Body>
        </Report>
        """
        return JMAEarthquakeXMLParser.parse(data: Data(xml.utf8))
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

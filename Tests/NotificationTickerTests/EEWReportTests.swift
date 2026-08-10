import XCTest
@testable import NotificationTicker

final class EEWReportTests: XCTestCase {
    func testParsesAreasAndHypocenter() {
        let report = makeReport()

        XCTAssertEqual(report?.eventID, "20260729221939")
        XCTAssertEqual(report?.serial, "1")
        XCTAssertEqual(report?.cancelled, false)
        XCTAssertEqual(report?.hypocenter, "熊本県天草・芦北地方")
        XCTAssertEqual(report?.magnitude, "4.5")
        XCTAssertEqual(report?.areas.count, 3)
    }

    func testPicksAreaMatchingLocalName() {
        let report = makeReport()

        // 「熊本県」と予報区名「熊本県熊本」を突き合わせる。
        XCTAssertEqual(report?.prediction(matching: "熊本県 熊本市")?.name, "熊本県熊本")
        XCTAssertEqual(report?.prediction(matching: "鹿児島県")?.name, "鹿児島県薩摩")
    }

    func testFallsBackToStrongestAreaWhenLocalIsUnknown() {
        let report = makeReport()

        // 該当が無ければ、発表された中で最も大きい予測を返す。
        XCTAssertEqual(report?.prediction(matching: "北海道")?.scale, 45)
        XCTAssertEqual(report?.prediction(matching: nil)?.scale, 45)
    }

    func testBuildsTickerTextWithSecondsUntilArrival() {
        let report = makeReport()
        // 到達予測の10秒前に受け取ったと仮定する。
        let now = arrivalDate().addingTimeInterval(-10)
        let text = report?.tickerText(localArea: "熊本県", now: now)

        XCTAssertEqual(text?.contains("【緊急地震速報】予測震度5弱"), true)
        XCTAssertEqual(text?.contains("熊本県熊本"), true)
        XCTAssertEqual(text?.contains("あと約10秒"), true)
        XCTAssertEqual(text?.contains("第1報・予測値"), true)
    }

    func testSaysImminentWhenArrivalHasPassed() {
        let report = makeReport()
        let now = arrivalDate().addingTimeInterval(5)

        XCTAssertEqual(report?.tickerText(localArea: "熊本県", now: now)?.contains("まもなく到達"), true)
    }

    func testAppliesIntensityThresholdToTheLocalArea() {
        let report = makeReport()

        // 熊本県熊本は5弱の予測。
        XCTAssertEqual(report?.meetsThreshold(minimumIntensity: "5弱", localArea: "熊本県"), true)
        XCTAssertEqual(report?.meetsThreshold(minimumIntensity: "5強", localArea: "熊本県"), false)
        // 鹿児島県薩摩は震度4の予測なので、下限5弱では出さない。
        XCTAssertEqual(report?.meetsThreshold(minimumIntensity: "5弱", localArea: "鹿児島県"), false)
        XCTAssertEqual(report?.meetsThreshold(minimumIntensity: "4", localArea: "鹿児島県"), true)
    }

    func testCancellationIsAlwaysReported() {
        let report = EEWReport.parse(data: Data(cancelledJSON.utf8))

        XCTAssertEqual(report?.cancelled, true)
        XCTAssertEqual(report?.meetsThreshold(minimumIntensity: "7", localArea: "東京都"), true)
        XCTAssertEqual(report?.tickerText(localArea: "東京都")?.contains("取り消し"), true)
    }

    func testIgnoresOtherMessageCodes() {
        let other = #"{"code":551,"areas":[]}"#

        XCTAssertNil(EEWReport.parse(data: Data(other.utf8)))
    }

    private func arrivalDate() -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.date(from: "2026/07/29 22:19:44")!
    }

    private func makeReport() -> EEWReport? {
        EEWReport.parse(data: Data(sampleJSON.utf8))
    }

    private let sampleJSON = """
    {
      "code": 556,
      "cancelled": false,
      "id": "6a69fdf1e88ee598246bf002",
      "issue": { "eventId": "20260729221939", "serial": "1", "time": "2026/07/29 22:19:44" },
      "earthquake": {
        "originTime": "2026/07/29 22:19:36",
        "hypocenter": { "name": "熊本県天草・芦北地方", "depth": 10, "magnitude": 4.5 }
      },
      "areas": [
        { "name": "熊本県熊本", "pref": "熊本", "scaleFrom": 45, "scaleTo": 45, "arrivalTime": "2026/07/29 22:19:44" },
        { "name": "熊本県球磨", "pref": "熊本", "scaleFrom": 40, "scaleTo": 40, "arrivalTime": "2026/07/29 22:19:43" },
        { "name": "鹿児島県薩摩", "pref": "鹿児島", "scaleFrom": 40, "scaleTo": 40, "arrivalTime": "2026/07/29 22:19:43" }
      ]
    }
    """

    private let cancelledJSON = """
    {
      "code": 556,
      "cancelled": true,
      "issue": { "eventId": "20260729221939", "serial": "5" },
      "earthquake": { "hypocenter": { "name": "熊本県天草・芦北地方", "magnitude": 4.5 } },
      "areas": []
    }
    """
}

import XCTest
@testable import NotificationTicker

final class NotificationTextParserTests: XCTestCase {
    func testParsesTypicalNotification() {
        let result = NotificationTextParser.parse(["Messages", "Alice", "今から向かいます"])
        XCTAssertEqual(result?.appName, "Messages")
        XCTAssertEqual(result?.title, "Alice")
        XCTAssertEqual(result?.body, "今から向かいます")
        XCTAssertEqual(result?.tickerText, "Messages  •  Alice  •  今から向かいます")
    }

    func testFiltersControlsAndDuplicates() {
        let result = NotificationTextParser.parse(["通知センター", "メール", "件名", "件名", "本文", "閉じる"])
        XCTAssertEqual(result, CapturedNotification(appName: "メール", title: "件名", body: "本文"))
    }

    func testRejectsEmptyContent() {
        XCTAssertNil(NotificationTextParser.parse([" ", "閉じる"]))
    }

    func testFiltersClockWeekdayAndTemperatureGlanceText() {
        XCTAssertNil(NotificationTextParser.parse(["午前 5:42", "月曜日", "28°", "晴れ"]))
        XCTAssertNil(NotificationTextParser.parse(["17:30", "Sunday", "22℃", "Cloudy"]))
        XCTAssertNil(NotificationTextParser.parse(["5:58:13", "月曜日 30°C"]))
        XCTAssertNil(NotificationTextParser.parse(["17:58:13", "Monday 30°C"]))
        XCTAssertNil(NotificationTextParser.parse(["13:40:17 木曜日 42°C"]))
        XCTAssertNil(NotificationTextParser.parse(["13:40:17 Thursday 42°C"]))
        XCTAssertNil(NotificationTextParser.parse([
            "33.8", "°", "C", "練馬区三原台 注意報 (Lv.2)", "26", "38", "18"
        ]))
    }

    func testCanIncludeClockWeatherWidgetWhenFilterIsDisabled() {
        let result = NotificationTextParser.parse(
            ["13:40:17 木曜日 42°C"],
            ignoringClockWeatherWidgets: false
        )
        XCTAssertEqual(result?.body, "13:40:17 木曜日 42°C")

        let splitResult = NotificationTextParser.parse(
            ["33.8", "°", "C", "練馬区三原台 注意報 (Lv.2)"],
            ignoringClockWeatherWidgets: false
        )
        XCTAssertEqual(splitResult?.tickerText, "33.8  •  °  •  C  練馬区三原台 注意報 (Lv.2)")
    }

    func testRecognizesWidgyWindowAndContainerRegardlessOfTextLayout() {
        XCTAssertTrue(NotificationWidgetClassifier.isClockWeatherWidget(
            windowTitle: "Widgy Widget",
            elementMarkers: []
        ))
        XCTAssertTrue(NotificationWidgetClassifier.isClockWeatherWidget(
            windowTitle: nil,
            elementMarkers: ["widget-local:com.woodsign.Widgy:Home-Widget:Medium #1"]
        ))
        XCTAssertFalse(NotificationWidgetClassifier.isClockWeatherWidget(
            windowTitle: "メール",
            elementMarkers: ["新着メッセージ"]
        ))
    }

    func testKeepsTimeWhenItIsPartOfNotificationBody() {
        let result = NotificationTextParser.parse(["カレンダー", "会議", "開始は10:30です"])
        XCTAssertEqual(result?.body, "開始は10:30です")
    }

    func testTickerEdgesExposeJapaneseLabelsAndOrientation() {
        XCTAssertEqual(TickerEdge.allCases.map(\.label), ["上", "下", "左", "右"])
        XCTAssertFalse(TickerEdge.top.isVertical)
        XCTAssertFalse(TickerEdge.bottom.isVertical)
        XCTAssertTrue(TickerEdge.left.isVertical)
        XCTAssertTrue(TickerEdge.right.isVertical)
    }
}

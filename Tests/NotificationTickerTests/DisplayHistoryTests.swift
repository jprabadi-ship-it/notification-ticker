import XCTest
@testable import NotificationTicker

final class DisplayHistoryTests: XCTestCase {
    func testRecordsNewestFirstAndTrimsBadge() {
        let history = DisplayHistory()
        let link = URL(string: "https://example.com/a")!
        history.record(text: "最初", badge: "  通達  ", link: link, at: Date(timeIntervalSince1970: 1))
        history.record(text: "次", badge: "  通知  ", link: nil, at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(history.entries.map(\.text), ["次", "最初"])
        XCTAssertEqual(history.entries.map(\.kind), ["通知", "通達"])
        XCTAssertEqual(history.entries.last?.link, link)
        XCTAssertNil(history.entries.first?.link)
    }

    func testDropsOldestBeyondLimit() {
        let history = DisplayHistory(limit: 3)
        for i in 1...5 {
            history.record(text: "m\(i)", badge: "通知", link: nil)
        }
        XCTAssertEqual(history.entries.map(\.text), ["m5", "m4", "m3"])
    }

    func testIgnoresBlankTextAndNotifiesOnChange() {
        let history = DisplayHistory()
        var changes = 0
        history.onChange = { changes += 1 }

        history.record(text: "   ", badge: "通知", link: nil)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(changes, 0)

        history.record(text: "本文", badge: "通知", link: nil)
        history.clear()
        history.clear()  // 空のときは通知しない
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(changes, 2)
    }
}

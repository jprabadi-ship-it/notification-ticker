import XCTest
@testable import NotificationTicker

final class DisplayHistoryTests: XCTestCase {
    func testRecordsNewestFirstAndTrimsBadge() {
        let history = DisplayHistory(storageURL: nil)
        let link = URL(string: "https://example.com/a")!
        history.record(text: "最初", badge: "  通達  ", link: link, at: Date(timeIntervalSince1970: 1))
        history.record(text: "次", badge: "  通知  ", link: nil, at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(history.entries.map(\.text), ["次", "最初"])
        XCTAssertEqual(history.entries.map(\.kind), ["通知", "通達"])
        XCTAssertEqual(history.entries.last?.link, link)
        XCTAssertNil(history.entries.first?.link)
    }

    func testDropsOldestBeyondLimit() {
        let history = DisplayHistory(limit: 3, storageURL: nil)
        for i in 1...5 {
            history.record(text: "m\(i)", badge: "通知", link: nil)
        }
        XCTAssertEqual(history.entries.map(\.text), ["m5", "m4", "m3"])
    }

    func testDefaultLimitIsTwenty() {
        XCTAssertEqual(DisplayHistory(storageURL: nil).limit, 20)
        XCTAssertEqual(DisplayHistory.defaultStorageURL.path, "/tmp/NotificationTicker/history.json")
    }

    func testIgnoresBlankTextAndNotifiesOnChange() {
        let history = DisplayHistory(storageURL: nil)
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

    func testPersistsToFileAndReloadsWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayHistoryTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let link = URL(string: "https://example.com/x")!
        let writer = DisplayHistory(limit: 2, storageURL: url)
        writer.record(text: "古い", badge: "通達", link: link, at: Date(timeIntervalSince1970: 10))
        writer.record(text: "新しい", badge: "通知", link: nil, at: Date(timeIntervalSince1970: 20))

        // 別のインスタンスで読み直せる。
        let reader = DisplayHistory(limit: 2, storageURL: url)
        XCTAssertEqual(reader.entries, writer.entries)
        XCTAssertEqual(reader.entries.first?.text, "新しい")
        XCTAssertEqual(reader.entries.last?.link, link)

        // 本人だけが読める権限になっている。
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o600)

        // 読み直すときも上限を守る。
        let narrow = DisplayHistory(limit: 1, storageURL: url)
        XCTAssertEqual(narrow.entries.map(\.text), ["新しい"])

        writer.clear()
        XCTAssertTrue(DisplayHistory(limit: 2, storageURL: url).entries.isEmpty)
    }
}

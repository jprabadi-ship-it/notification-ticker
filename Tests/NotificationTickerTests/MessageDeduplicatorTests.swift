import XCTest
@testable import NotificationTicker

final class MessageDeduplicatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MessageDeduplicatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSuppressesSameTextWithinWindow() {
        let deduplicator = MessageDeduplicator(defaults: defaults)
        let now = Date()

        XCTAssertTrue(deduplicator.shouldEmit("同じ本文", now: now))
        XCTAssertFalse(deduplicator.shouldEmit("同じ本文", now: now.addingTimeInterval(60 * 60)))
        XCTAssertFalse(
            deduplicator.shouldEmit("同じ本文", now: now.addingTimeInterval(23 * 60 * 60))
        )
    }

    func testAllowsSameTextAfterWindow() {
        let deduplicator = MessageDeduplicator(defaults: defaults)
        let now = Date()

        XCTAssertTrue(deduplicator.shouldEmit("同じ本文", now: now))
        XCTAssertTrue(
            deduplicator.shouldEmit("同じ本文", now: now.addingTimeInterval(24 * 60 * 60 + 1))
        )
    }

    func testTreatsWhitespaceDifferencesAsSameText() {
        let deduplicator = MessageDeduplicator(defaults: defaults)
        let now = Date()

        XCTAssertTrue(deduplicator.shouldEmit("見出し  •  本文", now: now))
        XCTAssertFalse(deduplicator.shouldEmit("見出し • 本文", now: now))
    }

    func testDistinguishesDifferentText() {
        let deduplicator = MessageDeduplicator(defaults: defaults)
        let now = Date()

        XCTAssertTrue(deduplicator.shouldEmit("本文A", now: now))
        XCTAssertTrue(deduplicator.shouldEmit("本文B", now: now))
    }

    func testAllowsWaitingNoticesToRepeatAfterShortWindow() {
        let deduplicator = MessageDeduplicator(defaults: defaults)
        let now = Date()
        let text = "許可待ち: 通知ウィジェット  •  Bash の実行を待っています"

        XCTAssertTrue(deduplicator.shouldEmit(text, now: now))
        // 連投は抑える。
        XCTAssertFalse(deduplicator.shouldEmit(text, now: now.addingTimeInterval(60)))
        // 3分を過ぎたら、同じ文面でも再び流す。
        XCTAssertTrue(deduplicator.shouldEmit(text, now: now.addingTimeInterval(3 * 60 + 1)))
    }

    func testKeepsLongWindowForOrdinaryNotices() {
        let deduplicator = MessageDeduplicator(defaults: defaults)
        let now = Date()

        XCTAssertTrue(deduplicator.shouldEmit("ビルドが完了しました", now: now))
        XCTAssertFalse(
            deduplicator.shouldEmit("ビルドが完了しました", now: now.addingTimeInterval(60 * 60))
        )
    }

    func testIgnoresEmptyText() {
        let deduplicator = MessageDeduplicator(defaults: defaults)

        XCTAssertFalse(deduplicator.shouldEmit("   "))
    }

    func testKeepsRecordAcrossRestarts() {
        let now = Date()
        XCTAssertTrue(MessageDeduplicator(defaults: defaults).shouldEmit("再起動テスト", now: now))

        let restarted = MessageDeduplicator(defaults: defaults)
        XCTAssertFalse(restarted.shouldEmit("再起動テスト", now: now.addingTimeInterval(60)))
    }
}

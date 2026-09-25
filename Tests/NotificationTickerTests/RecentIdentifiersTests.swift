import XCTest
@testable import NotificationTicker

final class RecentIdentifiersTests: XCTestCase {
    func testDropsOldestFirstWhenOverLimit() {
        var seen = RecentIdentifiers(limit: 3)
        ["a", "b", "c", "d"].forEach { seen.insert($0) }
        XCTAssertEqual(seen.ordered, ["b", "c", "d"])
        XCTAssertFalse(seen.contains("a"))
        XCTAssertTrue(seen.contains("d"))
    }

    func testRecentlySeenSurvivesManyOlderInsertions() {
        // 上限に張り付いた状態で古い記事が大量に流れ込んでも、直近に見たものは残る。
        var seen = RecentIdentifiers(limit: 100)
        (0..<100).forEach { seen.insert("old-\($0)") }
        seen.insert("just-shown")
        (0..<50).forEach { seen.insert("older-\($0)") }
        XCTAssertTrue(seen.contains("just-shown"))
        XCTAssertEqual(seen.count, 100)
    }

    func testIgnoresDuplicatesAndEmpty() {
        var seen = RecentIdentifiers(limit: 5, initial: ["x", "y", "x", ""])
        XCTAssertEqual(seen.ordered, ["x", "y"])
        seen.insert("x")
        XCTAssertEqual(seen.ordered, ["x", "y"])
    }

    func testPreservesStoredOrderOnLoad() {
        let seen = RecentIdentifiers(limit: 2, initial: ["1", "2", "3"])
        XCTAssertEqual(seen.ordered, ["2", "3"])
    }
}

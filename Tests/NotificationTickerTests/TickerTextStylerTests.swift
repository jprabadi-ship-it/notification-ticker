import AppKit
import XCTest
@testable import NotificationTicker

final class TickerTextStylerTests: XCTestCase {
    func testStylesTitleContentAndClockTime() {
        let text = "会議  •  開始は10:30です"
        let styled = makeStyled(text)

        assertColor(styled, at: (text as NSString).range(of: "会議").location, equals: TickerTextStyler.titleColor)
        assertColor(styled, at: (text as NSString).range(of: "開始").location, equals: TickerTextStyler.contentColor)
        assertColor(styled, at: (text as NSString).range(of: "10:30").location, equals: TickerTextStyler.timeColor)
    }

    func testStylesRelativeTimeOrange() {
        let text = "メール  •  5分前に受信"
        let styled = makeStyled(text)

        assertColor(styled, at: (text as NSString).range(of: "5分前").location, equals: TickerTextStyler.timeColor)
    }

    func testMessageWithoutExplicitTitleRemainsContentColor() {
        let text = "本文だけの通知"
        let styled = makeStyled(text)

        assertColor(styled, at: 0, equals: TickerTextStyler.contentColor)
    }

    func testLimitsTickerExpansionToFourLinesWithoutDroppingOverflowText() {
        let text = "1行目\n2行目\n3行目\n4行目\n5行目\n6行目"
        let limited = TickerTextLayout.limitingLines(in: text)

        XCTAssertEqual(limited.components(separatedBy: "\n").count, 4)
        XCTAssertEqual(limited, "1行目\n2行目\n3行目\n4行目  5行目  6行目")
    }

    func testFormatsTitleTimeAndContentOnSingleLineWithLeadingBadge() {
        let text = "タイトル  •  12:34  •  内容1  •  内容2"
        let formatted = TickerTextLayout.titleAndContentLines(in: text)
        let body = ["タイトル", "12:34", "内容1", "内容2"]
            .joined(separator: TickerTextStyler.displaySeparator)

        XCTAssertEqual(formatted, TickerTextStyler.badge + TickerTextStyler.badgeSpacing + body)
        XCTAssertEqual(formatted.components(separatedBy: "\n").count, 1)
        XCTAssertFalse(formatted.contains("•"))
    }

    func testCollapsesMultilineMessageToSingleLine() {
        let text = "タイトル  •  内容1\n内容2"
        let formatted = TickerTextLayout.titleAndContentLines(in: text)
        let body = ["タイトル", "内容1", "内容2"]
            .joined(separator: TickerTextStyler.displaySeparator)

        XCTAssertEqual(formatted, TickerTextStyler.badge + TickerTextStyler.badgeSpacing + body)
    }

    func testDrawsLeadingBadgeInRedAndKeepsTitleColored() {
        let text = TickerTextLayout.titleAndContentLines(in: "タイトル  •  内容1")
        let styled = makeStyled(text)
        let nsText = text as NSString
        let badgeLocation = nsText.range(of: TickerTextStyler.badge).location + 1

        XCTAssertTrue(text.hasPrefix(TickerTextStyler.badge))
        assertColor(styled, at: badgeLocation, equals: TickerTextStyler.badgeTextColor)
        // 赤地は六角形で描くため、矩形になる背景色属性は付けない。
        XCTAssertNil(styled.attribute(.backgroundColor, at: badgeLocation, effectiveRange: nil))

        assertColor(styled, at: nsText.range(of: "タイトル").location, equals: TickerTextStyler.titleColor)
        assertColor(styled, at: nsText.range(of: "内容1").location, equals: TickerTextStyler.contentColor)
    }

    func testBadgeShapeIsHexagonThatEnclosesTheText() {
        let rect = NSRect(x: 10, y: 20, width: 120, height: 40)
        let path = TickerTextStyler.hexagonPath(in: rect)

        // move + 5 line + closePath + 始点への復帰
        XCTAssertEqual(path.elementCount, 8)
        XCTAssertTrue(path.contains(NSPoint(x: rect.midX, y: rect.midY)))
        // 文字が置かれる中央帯は六角形の内側に収まる。
        XCTAssertTrue(path.contains(NSPoint(x: rect.minX + 1, y: rect.midY)))
        XCTAssertTrue(path.contains(NSPoint(x: rect.maxX - 1, y: rect.midY)))
    }

    func testDrawsNotificationBadgeForNonFeedMessages() {
        let text = TickerTextLayout.titleAndContentLines(
            in: "タイトル  •  内容1",
            badge: TickerTextStyler.notificationBadge
        )
        let styled = makeStyled(text)
        let nsText = text as NSString
        let badgeLocation = nsText.range(of: TickerTextStyler.notificationBadge).location + 1

        XCTAssertTrue(text.hasPrefix(TickerTextStyler.notificationBadge))
        assertColor(styled, at: badgeLocation, equals: TickerTextStyler.badgeTextColor)
        // 赤地は六角形で描くため、矩形になる背景色属性は付けない。
        XCTAssertNil(styled.attribute(.backgroundColor, at: badgeLocation, effectiveRange: nil))

        assertColor(styled, at: nsText.range(of: "タイトル").location, equals: TickerTextStyler.titleColor)
        assertColor(styled, at: nsText.range(of: "内容1").location, equals: TickerTextStyler.contentColor)
    }

    func testBadgeColorsFollowSeverity() {
        let styler = TickerTextStyler.self
        XCTAssertEqual(styler.backgroundColor(forBadge: styler.badge), styler.feedBadgeColor)
        XCTAssertEqual(styler.backgroundColor(forBadge: styler.notificationBadge), styler.neutralBadgeColor)
        XCTAssertEqual(styler.backgroundColor(forBadge: styler.earthquakeBadge), styler.neutralBadgeColor)
        XCTAssertEqual(styler.backgroundColor(forBadge: styler.earthquakeWarningBadge), styler.cautionBadgeColor)
        XCTAssertEqual(
            styler.backgroundColor(forBadge: styler.earthquakeEvacuationBadge),
            styler.badgeBackgroundColor
        )

        // 黄色の警戒バッジだけ黒文字。
        XCTAssertEqual(styler.textColor(forBadge: styler.earthquakeWarningBadge), styler.badgeDarkTextColor)
        XCTAssertEqual(styler.textColor(forBadge: styler.badge), styler.badgeTextColor)
    }

    func testBadgeRectStaysInsideTickerBackground() {
        // 背景が 2pt 内側にある 60pt のティッカーに、はみ出す高さのバッジを置く。
        let clamped = TickerTextStyler.badgeRect(
            x: 5, y: -6, width: 100, height: 80, clampedTo: 2...58
        )
        XCTAssertEqual(clamped.minY, 2)
        XCTAssertEqual(clamped.maxY, 58)
        XCTAssertEqual(clamped.width, 100)

        // 収まっている場合はそのまま。
        let untouched = TickerTextStyler.badgeRect(
            x: 5, y: 12, width: 100, height: 30, clampedTo: 2...58
        )
        XCTAssertEqual(untouched, NSRect(x: 5, y: 12, width: 100, height: 30))
    }

    func testDetectsAIToolNotifications() {
        XCTAssertTrue(TickerTextStyler.isAIToolNotification(appName: "Claude", title: "完了しました"))
        XCTAssertTrue(TickerTextStyler.isAIToolNotification(appName: "Terminal", title: "Codex finished"))
        XCTAssertTrue(TickerTextStyler.isAIToolNotification(appName: "claude code", title: nil))
        XCTAssertFalse(TickerTextStyler.isAIToolNotification(appName: "メッセージ", title: "新着"))
        XCTAssertFalse(TickerTextStyler.isAIToolNotification(appName: nil, title: nil))
    }

    func testEarthquakeBadgeFollowsIntensity() {
        for intensity in ["1", "2", "3"] {
            XCTAssertEqual(
                TickerTextStyler.earthquakeBadge(forIntensity: intensity),
                TickerTextStyler.earthquakeBadge
            )
        }
        XCTAssertEqual(
            TickerTextStyler.earthquakeBadge(forIntensity: "4"),
            TickerTextStyler.earthquakeWarningBadge
        )
        for intensity in ["5-", "5弱", "5+", "6-", "6+", "7"] {
            XCTAssertEqual(
                TickerTextStyler.earthquakeBadge(forIntensity: intensity),
                TickerTextStyler.earthquakeEvacuationBadge
            )
        }
    }

    func testInsertsPublishTimeAtHead() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 28
        components.hour = 9
        components.minute = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!

        let result = TickerTextLayout.insertingTime(date, into: "メッセージ  •  本文")

        XCTAssertEqual(result, "09:05  •  メッセージ  •  本文")
    }

    func testStylesTitleTimeAndContentOnSingleLine() {
        let text = "タイトル  •  12:34  •  内容1"
        let styled = makeStyled(text)

        assertColor(styled, at: (text as NSString).range(of: "タイトル").location, equals: TickerTextStyler.titleColor)
        assertColor(styled, at: (text as NSString).range(of: "内容1").location, equals: TickerTextStyler.contentColor)
        assertColor(styled, at: (text as NSString).range(of: "12:34").location, equals: TickerTextStyler.timeColor)
    }

    private func makeStyled(_ text: String) -> NSAttributedString {
        TickerTextStyler.attributedString(
            for: text,
            font: .systemFont(ofSize: 18),
            strokeWidth: 0
        )
    }

    private func assertColor(
        _ attributed: NSAttributedString,
        at index: Int,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let color = attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        XCTAssertTrue(color?.isEqual(expected) == true, file: file, line: line)
    }

    func testCondensesOnlyOverlongText() {
        let threshold = TickerTextLayout.longTextThreshold
        let short = String(repeating: "あ", count: threshold)
        let long = String(repeating: "い", count: threshold + 1)

        XCTAssertEqual(TickerTextLayout.condensed(short), short)
        XCTAssertEqual(TickerTextLayout.condensed(long), String(repeating: "い", count: 50) + "…")
    }

    func testMapsClickPointToScrollPositionForEachEdge() {
        // 横型はそのまま x。
        let horizontal = NSRect(x: 0, y: 0, width: 1000, height: 80)
        XCTAssertEqual(TickerView.scrollPosition(of: NSPoint(x: 120, y: 30), in: horizontal, edge: .top), 120)
        XCTAssertEqual(TickerView.scrollPosition(of: NSPoint(x: 120, y: 30), in: horizontal, edge: .bottom), 120)
        // 縦型は描画時に回転しているため、左辺は y がそのまま、右辺は上下が反転する。
        let vertical = NSRect(x: 0, y: 0, width: 80, height: 600)
        XCTAssertEqual(TickerView.scrollPosition(of: NSPoint(x: 40, y: 150), in: vertical, edge: .left), 150)
        XCTAssertEqual(TickerView.scrollPosition(of: NSPoint(x: 40, y: 150), in: vertical, edge: .right), 450)
    }
}

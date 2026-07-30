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
        let background = styled.attribute(.backgroundColor, at: badgeLocation, effectiveRange: nil) as? NSColor
        XCTAssertTrue(background?.isEqual(TickerTextStyler.badgeBackgroundColor) == true)

        assertColor(styled, at: nsText.range(of: "タイトル").location, equals: TickerTextStyler.titleColor)
        assertColor(styled, at: nsText.range(of: "内容1").location, equals: TickerTextStyler.contentColor)
    }

    func testDrawsAnnouncementBadgeForNonFeedMessages() {
        let text = TickerTextLayout.titleAndContentLines(
            in: "タイトル  •  内容1",
            badge: TickerTextStyler.announcementBadge
        )
        let styled = makeStyled(text)
        let nsText = text as NSString
        let badgeLocation = nsText.range(of: TickerTextStyler.announcementBadge).location + 1

        XCTAssertTrue(text.hasPrefix(TickerTextStyler.announcementBadge))
        assertColor(styled, at: badgeLocation, equals: TickerTextStyler.badgeTextColor)
        let background = styled.attribute(.backgroundColor, at: badgeLocation, effectiveRange: nil) as? NSColor
        XCTAssertTrue(background?.isEqual(TickerTextStyler.badgeBackgroundColor) == true)

        assertColor(styled, at: nsText.range(of: "タイトル").location, equals: TickerTextStyler.titleColor)
        assertColor(styled, at: nsText.range(of: "内容1").location, equals: TickerTextStyler.contentColor)
    }

    func testInsertsPublishTimeAfterTitle() {
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

        XCTAssertEqual(result, "メッセージ  •  09:05  •  本文")
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
}

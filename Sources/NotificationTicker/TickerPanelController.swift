import AppKit
import os
import QuartzCore

/// スリープ復帰や画面構成の変化をまたいだ不具合を追えるように、要所だけ記録する。
/// 読み出し: log show --predicate 'subsystem == "jp.local.NotificationTicker"' --last 12h
let tickerLog = Logger(subsystem: "jp.local.NotificationTicker", category: "ticker")

enum TickerTextStyler {
    static let titleColor = NSColor(calibratedRed: 1, green: 0.03, blue: 0.03, alpha: 1)
    static let contentColor = NSColor.white
    static let timeColor = NSColor(calibratedRed: 1, green: 0.47, blue: 0.04, alpha: 1)
    static let badgeTextColor = NSColor.white
    /// 黄色のバッジは白文字だと読めないので黒にする。
    static let badgeDarkTextColor = NSColor.black
    static let badgeBackgroundColor = NSColor(calibratedRed: 0.85, green: 0.04, blue: 0.04, alpha: 1)
    static let feedBadgeColor = NSColor(calibratedRed: 0.16, green: 0.66, blue: 0.88, alpha: 1)
    static let neutralBadgeColor = NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.47, alpha: 1)
    static let cautionBadgeColor = NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.05, alpha: 1)
    /// Claude Code / Codex など、AIツール由来の通知に使う地色。
    static let aiBadgeColor = NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.08, alpha: 1)
    /// 各モニターがメッセージを組み立てるときに使う入力用の区切り。
    static let separator = "  •  "
    /// 行頭に赤地の六角形で描画されるバッジ（フィード由来のメッセージ用）。
    /// 前後の空白は、六角形の斜辺に文字がかからないようにするための余白。
    static let badge = "  通達  "
    /// macOS通知など、フィード以外のメッセージに使うバッジ。
    static let notificationBadge = "  通知  "
    /// 地震速報のバッジ。震度に応じて切り替える。
    static let earthquakeBadge = "  地震  "
    static let earthquakeWarningBadge = "  警戒  "
    static let earthquakeEvacuationBadge = "  退避  "
    /// 行頭バッジとして扱う文字列の一覧。
    static let badges = [
        badge,
        notificationBadge,
        earthquakeBadge,
        earthquakeWarningBadge,
        earthquakeEvacuationBadge
    ]

    /// バッジの地色。通達=水色、通知/地震=灰色、警戒=黄色、退避=赤。
    static func backgroundColor(forBadge badgeText: String) -> NSColor {
        switch badgeText {
        case badge: return feedBadgeColor
        case notificationBadge, earthquakeBadge: return neutralBadgeColor
        case earthquakeWarningBadge: return cautionBadgeColor
        default: return badgeBackgroundColor
        }
    }

    /// Claude Code / Codex など、AIツール由来の通知かどうか。
    static func isAIToolNotification(appName: String?, title: String?) -> Bool {
        let haystack = [appName, title].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["claude", "codex", "luminella"].contains { haystack.contains($0) }
    }

    /// バッジの文字色。黄色の地には黒、それ以外は白。
    static func textColor(forBadge badgeText: String) -> NSColor {
        badgeText == earthquakeWarningBadge ? badgeDarkTextColor : badgeTextColor
    }

    /// 震度4で「警戒」、震度5弱以上で「退避」、それ未満は「地震」。
    static func earthquakeBadge(forIntensity intensity: String) -> String {
        switch JMAEarthquakeReport.intensityRank(intensity) {
        case ...3: return earthquakeBadge
        case 4: return earthquakeWarningBadge
        default: return earthquakeEvacuationBadge
        }
    }
    /// バッジとタイトルの間隔。
    static let badgeSpacing = "  "
    /// 表示上の区切り（記号は出さず空白のみ）。
    static let displaySeparator = "   "

    static func attributedString(
        for text: String,
        font: NSFont,
        strokeWidth: Double,
        paragraphStyle: NSParagraphStyle? = nil
    ) -> NSAttributedString {
        var baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: contentColor,
            .strokeColor: contentColor,
            .strokeWidth: strokeWidth
        ]
        if let paragraphStyle { baseAttributes[.paragraphStyle] = paragraphStyle }

        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        let fullRange = NSRange(location: 0, length: result.length)

        // バッジ自体はタイトル色を塗らず、その後ろのタイトル部分だけを赤くする。
        let leadingBadge = badges.first { text.hasPrefix($0) }
        let titleStart = leadingBadge.map { text.index(text.startIndex, offsetBy: $0.count) }
            ?? text.startIndex
        let titleEnd = text.range(of: displaySeparator, range: titleStart..<text.endIndex)?.lowerBound
            ?? text.range(of: separator, range: titleStart..<text.endIndex)?.lowerBound
            ?? text[titleStart...].firstIndex(of: "\n")
        if let titleEnd {
            let titleRange = NSRange(titleStart..<titleEnd, in: text)
            result.addAttributes([
                .foregroundColor: titleColor,
                .strokeColor: titleColor
            ], range: titleRange)
        }

        let patterns = [
            #"(?:午前|午後)?\s*\d{1,2}[:：]\d{2}(?:[:：]\d{2})?(?:\s*(?:AM|PM|am|pm))?"#,
            #"\d+\s*(?:秒|分|時間)前"#,
            #"たった今"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                result.addAttributes([
                    .foregroundColor: timeColor,
                    .strokeColor: timeColor
                ], range: match.range)
            }
        }

        // 赤地は矩形の背景色ではなく六角形で描くため、ここでは文字色だけを白にする。
        for badgeText in badges {
            var searchStart = text.startIndex
            while let badgeRange = text.range(of: badgeText, range: searchStart..<text.endIndex) {
                let foreground = textColor(forBadge: badgeText)
                result.addAttributes([
                    .foregroundColor: foreground,
                    .strokeColor: foreground,
                    .strokeWidth: 0
                ], range: NSRange(badgeRange, in: text))
                searchStart = badgeRange.upperBound
            }
        }
        return result
    }

    /// バッジの外形。ティッカーの背景からはみ出さないよう上下を切り詰める。
    static func badgeRect(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        clampedTo verticalBounds: ClosedRange<CGFloat>
    ) -> NSRect {
        let minY = max(y, verticalBounds.lowerBound)
        let maxY = min(y + height, verticalBounds.upperBound)
        return NSRect(x: x, y: minY, width: width, height: max(0, maxY - minY))
    }

    /// 左右が尖った横長の六角形。文字を囲む矩形をそのまま渡す。
    static func hexagonPath(in rect: NSRect) -> NSBezierPath {
        let inset = min(rect.height * 0.28, rect.width * 0.3)
        let midY = rect.midY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: midY))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: midY))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.minY))
        path.close()
        return path
    }
}

enum TickerTextLayout {
    static let maximumLines = 4

    static func limitingLines(in text: String, maximum: Int = maximumLines) -> String {
        guard maximum > 0 else { return "" }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maximum else { return normalized }

        var result = Array(lines.prefix(maximum - 1))
        let overflow = lines.dropFirst(maximum - 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        result.append(overflow)
        return result.joined(separator: "\n")
    }

    /// これを超えた通知は読み切れないまま流れていくだけなので、手を入れる。
    /// 要約するときも切り詰めるときも、同じ長さを境目にする。
    /// 会議変更・配送・決済といった日常的な通知が110〜135字に収まるため、
    /// そこを拾える 100 にしている。
    static let longTextThreshold = 100

    /// 長すぎる通知は読み切れないまま流れていくだけなので、思い切って切り詰める。
    /// しきい値を超えたものだけが対象。少し長い程度の通知はそのまま全文を流す。
    static func condensed(
        _ text: String,
        threshold: Int = longTextThreshold,
        limit: Int = 50
    ) -> String {
        guard text.count > threshold else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// 先頭にバッジを付け、タイトル・発行時刻・内容を1行にまとめる。
    static func titleAndContentLines(
        in text: String,
        badge: String = TickerTextStyler.badge
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let sections = normalized.components(separatedBy: TickerTextStyler.separator)
        guard sections.count > 1 else {
            return prefixingBadge(singleLine(in: normalized), badge: badge)
        }

        let parts = sections.flatMap { section in
            section.split(separator: "\n", omittingEmptySubsequences: true).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.filter { !$0.isEmpty }

        return prefixingBadge(parts.joined(separator: TickerTextStyler.displaySeparator), badge: badge)
    }

    private static func prefixingBadge(_ text: String, badge: String) -> String {
        guard !text.isEmpty else { return text }
        return badge + TickerTextStyler.badgeSpacing + text
    }

    /// 先頭に発行時刻を差し込む。フィード以外（通知・地震速報）の入力用。
    static func insertingTime(_ date: Date, into text: String) -> String {
        let time = FeedDateParser.displayTime(for: date)
        return ([time, text]).joined(separator: TickerTextStyler.separator)
    }

    private static func singleLine(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
    }
}

final class TickerView: NSView {
    private let settings: TickerSettings
    private var displayLinkTimer: Timer?
    /// 流れている最中のメッセージ。前後が途切れないよう複数を同時に保持する。
    private struct TickerItem {
        let text: String
        let badgeColor: NSColor
        /// このメッセージが先頭にいる間に鳴らす音。nil なら共通の通知音。
        let soundSelection: String?
        /// ループの上書き。nil なら音源ごとの設定に従う。
        let soundLoops: Bool?
        /// クリックで開くページ。フィードの記事など。
        let link: URL?
        var x: CGFloat
        var width: CGFloat
        var lineCount: Int
    }

    private var items: [TickerItem] = []
    /// メッセージ同士の間隔。
    private let messageGap: CGFloat = 72
    /// 背景の警告ストライプが右方向へ進んだ距離。1周期ぶんで折り返す。
    private var stripePhase: CGFloat = 0
    /// ストライプのスクロール速度（pt/秒）。本文より大幅に遅くしてゆっくり流す。
    private let stripeScrollSpeed: CGFloat = 8
    private var previousTimestamp = ProcessInfo.processInfo.systemUptime
    var onActivityChange: ((Bool) -> Void)?
    /// 先頭メッセージが入れ替わり、鳴らすべき音が変わったときに呼ばれる。
    var onLeadingSoundChange: ((String?, Bool?) -> Void)?
    private var lastReportedSoundSelection: String??
    /// クリック（ビュー座標の位置と回数）。振り分けは呼び出し側が行う。
    var onClick: ((NSPoint, Int) -> Void)?
    var onContentMetricsChange: (() -> Void)?

    var hasContent: Bool { !items.isEmpty }

    /// ティッカーの背景が上下に持つ余白。
    private static let backgroundVerticalInset: CGFloat = 2
    /// 警告ストライプの最大帯幅。`drawWarningStripes` の上限値と一致させる。
    private static let maximumStripeBandHeight: CGFloat = 10
    /// 背景の内側マージン（bounds の inset ＋ 帯幅）。
    /// 本文とバッジは斜線の帯の内側いっぱいを使う。
    private static var contentInset: CGFloat { backgroundVerticalInset + maximumStripeBandHeight }

    var requiredThickness: CGFloat {
        let rowHeight = textRowHeight
        // 同時に流れている中で最も行数の多いものに合わせる。
        let lineCount = items.map(\.lineCount).max() ?? 1
        return max(60, rowHeight * CGFloat(lineCount) + Self.contentInset * 2)
    }

    init(frame frameRect: NSRect, settings: TickerSettings) {
        self.settings = settings
        super.init(frame: frameRect)
        wantsLayer = true
        startAnimating()
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil), event.clickCount)
        super.mouseDown(with: event)
    }

    /// クリック位置を、メッセージが流れる方向の座標に直す。
    /// 縦型は描画時に回転しているため、左辺は y がそのまま、右辺は上下が反転する。
    static func scrollPosition(of point: NSPoint, in bounds: NSRect, edge: TickerEdge) -> CGFloat {
        switch edge {
        case .left: return point.y
        case .right: return bounds.height - point.y
        default: return point.x
        }
    }

    /// その位置に流れているメッセージのリンク。無ければ nil。
    func link(at point: NSPoint) -> URL? {
        let position = Self.scrollPosition(of: point, in: bounds, edge: settings.edge)
        return items.first { $0.x <= position && position <= $0.x + $0.width }?.link
    }

    var leadingSoundSelection: String? { items.first?.soundSelection }

    func enqueue(
        _ message: String,
        badge: String = TickerTextStyler.badge,
        badgeColor: NSColor? = nil,
        soundSelection: String? = nil,
        soundLoops: Bool? = nil,
        link: URL? = nil
    ) {
        let cleaned = TickerTextLayout.titleAndContentLines(
            in: message.trimmingCharacters(in: .whitespacesAndNewlines),
            badge: badge
        )
        guard !cleaned.isEmpty else { return }
        let wasEmpty = items.isEmpty
        // 直前のメッセージの末尾に続けて並べる。画面右端より手前には置かない。
        let trailing = items.map { $0.x + $0.width }.max()
        let startX = max(scrollExtent + 24, (trailing ?? 0) + messageGap)
        items.append(
            TickerItem(
                text: cleaned,
                badgeColor: badgeColor ?? TickerTextStyler.backgroundColor(forBadge: badge),
                soundSelection: soundSelection,
                soundLoops: soundLoops,
                link: link,
                x: startX,
                width: measuredSize(of: cleaned).width,
                lineCount: min(
                    TickerTextLayout.maximumLines,
                    max(1, cleaned.components(separatedBy: "\n").count)
                )
            )
        )
        onContentMetricsChange?()
        if wasEmpty { onActivityChange?(true) }
        notifyLeadingSoundIfNeeded()
        needsDisplay = true
    }

    /// 先頭が入れ替わったときだけ通知する。毎フレーム鳴らし直さないための番人。
    private func notifyLeadingSoundIfNeeded() {
        let selection = leadingSoundSelection
        if let last = lastReportedSoundSelection, last == selection { return }
        lastReportedSoundSelection = .some(selection)
        onLeadingSoundChange?(selection, items.first?.soundLoops)
    }

    func clear() {
        items.removeAll()
        lastReportedSoundSelection = nil
        onContentMetricsChange?()
        onActivityChange?(false)
        needsDisplay = true
    }

    func refreshAppearance() {
        needsDisplay = true
    }

    /// フォントや表示位置が変わると文字幅も変わるため、幅を測り直して並べ直す。
    func refreshLayout() {
        var nextX = scrollExtent + 24
        for index in items.indices {
            items[index].width = measuredSize(of: items[index].text).width
            items[index].x = nextX
            nextX = items[index].x + items[index].width + messageGap
        }
        onContentMetricsChange?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard settings.isEnabled else { return }

        let backgroundRect = bounds.insetBy(dx: 0, dy: Self.backgroundVerticalInset)
        let path = NSBezierPath(roundedRect: backgroundRect, xRadius: 2, yRadius: 2)
        NSColor.black.withAlphaComponent(settings.backgroundOpacity).setFill()
        path.fill()
        drawWarningStripes(in: backgroundRect)

        guard !items.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        // 画面に掛かっているものだけ描く。右側で待機中のものは描画しない。
        let onScreen = items.filter { $0.x < scrollExtent && $0.x + $0.width > 0 }
        guard !onScreen.isEmpty else { return }

        if settings.edge.isVertical {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            if settings.edge == .left {
                context.translateBy(x: bounds.width, y: 0)
                context.rotate(by: .pi / 2)
            } else {
                context.translateBy(x: 0, y: bounds.height)
                context.rotate(by: -.pi / 2)
            }
            // 回転後は元の height が横方向になるため、縦方向の余白は付かない。
            for item in onScreen {
                drawLines(
                    styledText(item.text, paragraphStyle: paragraph),
                    sourceText: item.text,
                    x: item.x,
                    canvasHeight: bounds.width,
                    badgeVerticalInset: 0,
                    badgeColor: item.badgeColor
                )
            }
            context.restoreGState()
        } else {
            for item in onScreen {
                drawLines(
                    styledText(item.text, paragraphStyle: paragraph),
                    sourceText: item.text,
                    x: item.x,
                    canvasHeight: bounds.height,
                    badgeVerticalInset: Self.contentInset,
                    badgeColor: item.badgeColor
                )
            }
        }
    }

    private func startAnimating() {
        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(displayLinkTimer!, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(now - previousTimestamp, 0.1)
        previousTimestamp = now
        stripePhase += stripeScrollSpeed * CGFloat(elapsed)

        guard settings.isEnabled, !items.isEmpty else {
            needsDisplay = true
            return
        }

        let distance = CGFloat(settings.speed * elapsed)
        for index in items.indices { items[index].x -= distance }

        let remaining = items.filter { $0.x + $0.width >= 0 }
        if remaining.count != items.count {
            items = remaining
            onContentMetricsChange?()
            if items.isEmpty {
                lastReportedSoundSelection = nil
                onActivityChange?(false)
            } else {
                notifyLeadingSoundIfNeeded()
            }
        }
        needsDisplay = true
    }

    private var scrollExtent: CGFloat {
        settings.edge.isVertical ? bounds.height : bounds.width
    }

    /// ホイールイベントを本文の移動量へ変換する。上回しで負（早送り）、下回しで正（逆戻り）。
    /// 「ナチュラルなスクロール」設定でも上回し＝早送りになるよう符号を揃える。
    static func scrollNudge(for event: NSEvent) -> CGFloat? {
        let raw = event.scrollingDeltaY
        guard raw != 0 else { return nil }
        let normalized = event.isDirectionInvertedFromDevice ? -raw : raw
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        return -normalized * step
    }

    /// クリックスルーが無効なときは、パネル自身にホイールイベントが届く。
    override func scrollWheel(with event: NSEvent) {
        guard let delta = TickerView.scrollNudge(for: event) else {
            super.scrollWheel(with: event)
            return
        }
        nudgeScroll(by: delta)
    }

    /// ホイール操作で本文の位置を手送りする。正の値で逆戻り、負の値で早送り。
    /// 逆戻りは表示開始位置より手前には戻さない。
    func nudgeScroll(by delta: CGFloat) {
        guard let leading = items.first else { return }
        // 先頭のメッセージが表示開始位置より右へ戻らない範囲で、全体をまとめて動かす。
        let clamped = min(delta, scrollExtent + 24 - leading.x)
        guard clamped != 0 else { return }
        for index in items.indices { items[index].x += clamped }
        needsDisplay = true
    }

    private var selectedFont: NSFont {
        if settings.fontFamily == TickerSettings.boldMinchoFontFamily {
            return boldMinchoFont
        }
        if settings.fontFamily != "__system__",
           let font = NSFontManager.shared.font(
               withFamily: settings.fontFamily,
               traits: [],
               weight: 5,
               size: settings.fontSize
           ) {
            return font
        }
        return NSFont.systemFont(ofSize: settings.fontSize, weight: .medium)
    }

    private var textRowHeight: CGFloat {
        ceil(selectedFont.ascender - selectedFont.descender + selectedFont.leading)
    }

    private var textVerticalCenteringOffset: CGFloat {
        max(0, selectedFont.leading / 2)
    }

    private func drawLines(
        _ attributed: NSAttributedString,
        sourceText: String,
        x: CGFloat,
        canvasHeight: CGFloat,
        badgeVerticalInset: CGFloat,
        badgeColor: NSColor
    ) {
        let source = sourceText as NSString
        var location = 0
        // Point-based drawing leaves the font's leading above the glyphs.
        // Split it across both sides so the visible letters sit centrally.
        var y = canvasHeight - Self.contentInset - textRowHeight + textVerticalCenteringOffset

        let lines = Array(sourceText.components(separatedBy: "\n").prefix(TickerTextLayout.maximumLines))
        // 1行のときはバッジを帯の内側いっぱいまで広げる。複数行では行の高さに収める。
        let badgeFillsBounds = lines.count == 1

        for line in lines {
            let length = (line as NSString).length
            let range = NSRange(location: location, length: length)
            if length > 0 {
                let lineText = attributed.attributedSubstring(from: range)
                drawBadgeHexagon(
                    for: line,
                    in: lineText,
                    x: x,
                    y: y,
                    verticalBounds: badgeVerticalInset...(canvasHeight - badgeVerticalInset),
                    fillsBounds: badgeFillsBounds,
                    color: badgeColor
                )
                lineText.draw(at: NSPoint(x: x, y: y))
            }
            location += length + 1
            y -= textRowHeight
            if location > source.length { break }
        }
    }

    /// 行頭バッジの文字幅を測り、その背後に赤い六角形を敷く。
    private func drawBadgeHexagon(
        for line: String,
        in attributedLine: NSAttributedString,
        x: CGFloat,
        y: CGFloat,
        verticalBounds: ClosedRange<CGFloat>,
        fillsBounds: Bool,
        color: NSColor
    ) {
        guard let badge = TickerTextStyler.badges.first(where: { line.hasPrefix($0) }) else { return }
        let badgeLength = (badge as NSString).length
        guard badgeLength <= attributedLine.length else { return }
        let badgeWidth = measuredSize(
            of: attributedLine.attributedSubstring(from: NSRange(location: 0, length: badgeLength))
        ).width
        guard badgeWidth > 0 else { return }

        let rect = TickerTextStyler.badgeRect(
            x: x,
            y: fillsBounds ? verticalBounds.lowerBound : y,
            width: badgeWidth,
            height: fillsBounds
                ? verticalBounds.upperBound - verticalBounds.lowerBound
                : textRowHeight,
            clampedTo: verticalBounds
        )
        guard rect.height > 0 else { return }
        color.setFill()
        TickerTextStyler.hexagonPath(in: rect).fill()
    }

    private var boldMinchoFont: NSFont {
        for postScriptName in ["YuMin-Demibold", "HiraMinProN-W6"] {
            if let font = NSFont(name: postScriptName, size: settings.fontSize) { return font }
        }
        if let font = NSFontManager.shared.font(
            withFamily: "Hiragino Mincho ProN",
            traits: [.boldFontMask],
            weight: 15,
            size: settings.fontSize
        ) {
            return font
        }
        let descriptor = NSFont.systemFont(ofSize: settings.fontSize, weight: .black).fontDescriptor
        if let serifDescriptor = descriptor.withDesign(.serif),
           let font = NSFont(descriptor: serifDescriptor, size: settings.fontSize) {
            return font
        }
        return NSFont.systemFont(ofSize: settings.fontSize, weight: .black)
    }

    private func drawWarningStripes(in backgroundRect: NSRect) {
        let bandHeight = min(Self.maximumStripeBandHeight, max(7, backgroundRect.height * 0.16))
        let bands = [
            NSRect(x: backgroundRect.minX, y: backgroundRect.minY, width: backgroundRect.width, height: bandHeight),
            NSRect(x: backgroundRect.minX, y: backgroundRect.maxY - bandHeight, width: backgroundRect.width, height: bandHeight)
        ]

        NSColor(calibratedRed: 1, green: 0.03, blue: 0.03, alpha: 0.98).setFill()
        for band in bands {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: band).addClip()
            let stripeWidth = max(13, bandHeight * 1.55)
            let gap = max(8, bandHeight * 0.9)
            let slant = bandHeight * 0.62
            // 1周期ぶん手前から描き始め、位相を足すことで右へ流れて見せる。
            let period = stripeWidth + gap
            let offset = stripePhase.truncatingRemainder(dividingBy: period)
            var x = band.minX - stripeWidth - slant - period + offset
            while x < band.maxX + slant {
                let stripe = NSBezierPath()
                stripe.move(to: NSPoint(x: x, y: band.minY))
                stripe.line(to: NSPoint(x: x + stripeWidth, y: band.minY))
                stripe.line(to: NSPoint(x: x + stripeWidth + slant, y: band.maxY))
                stripe.line(to: NSPoint(x: x + slant, y: band.maxY))
                stripe.close()
                stripe.fill()
                x += stripeWidth + gap
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func measuredSize(
        of text: String
    ) -> NSSize {
        measuredSize(of: styledText(text))
    }

    private func measuredSize(of attributed: NSAttributedString) -> NSSize {
        let bounds = attributed.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    private func styledText(_ text: String, paragraphStyle: NSParagraphStyle? = nil) -> NSAttributedString {
        TickerTextStyler.attributedString(
            for: text,
            font: selectedFont,
            strokeWidth: settings.fontFamily == TickerSettings.boldMinchoFontFamily ? -3.0 : 0,
            paragraphStyle: paragraphStyle
        )
    }
}

final class TickerPanelController {
    let panel: NSPanel
    let tickerView: TickerView
    var onTickerWillHide: (() -> Void)?
    var onTickerDidShow: (() -> Void)?
    private let settings: TickerSettings
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    /// シングルクリックで開く予定のリンク。ダブルクリックに化けたら取り消す。
    private var pendingLinkOpen: DispatchWorkItem?
    private var globalMouseMonitor: Any?
    private var globalScrollMonitor: Any?
    private var fadeGeneration = 0
    private var isSuppressed = false

    init(settings: TickerSettings) {
        self.settings = settings
        let initialFrame = NSRect(x: 20, y: 12, width: 900, height: 52)
        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tickerView = TickerView(frame: NSRect(origin: .zero, size: initialFrame.size), settings: settings)

        panel.contentView = tickerView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        applyAllSpacesBehavior()

        tickerView.onActivityChange = { [weak self] isActive in
            guard let self else { return }
            if isActive && self.settings.isEnabled {
                self.showPanel()
            } else {
                self.fadeOutPanel()
            }
        }
        tickerView.onClick = { [weak self] point, count in
            self?.handleClick(viewPoint: point, clickCount: count)
        }
        tickerView.onContentMetricsChange = { [weak self] in self?.reposition() }

        // クリック透過中はパネルにクリックが届かないので、他アプリへ渡った
        // イベントをグローバル監視で拾う（透過でないときは mouseDown 側が受ける）。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let clickCount = event.clickCount
            DispatchQueue.main.async {
                guard let self,
                      self.panel.isVisible,
                      self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                let windowPoint = self.panel.convertPoint(fromScreen: NSEvent.mouseLocation)
                let viewPoint = self.tickerView.convert(windowPoint, from: nil)
                self.handleClick(viewPoint: viewPoint, clickCount: clickCount)
            }
        }

        // ティッカーはクリックスルー（ignoresMouseEvents）で使うことが多く、
        // パネル自身にはホイールが届かない。ダブルクリック終了と同じくグローバル監視で拾う。
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let raw = event.scrollingDeltaY
            guard raw != 0 else { return }
            // 「ナチュラルなスクロール」設定に関わらず、上回し＝正になるよう揃える。
            let normalized = event.isDirectionInvertedFromDevice ? -raw : raw
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
            DispatchQueue.main.async {
                guard let self,
                      self.panel.isVisible,
                      self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                // 上回しは早送り（左へ進める）、下回しは逆戻り（右へ戻す）。
                self.tickerView.nudgeScroll(by: -normalized * step)
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reposition() }

        // デスクトップ（操作スペース）を切り替えたとき、表示中のパネルが元の
        // スペースに取り残されることがある。切替のたびに全スペース表示を宣言し直し、
        // 出したままにする。
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.applyAllSpacesBehavior()
            self.reposition()
            self.panel.orderFrontRegardless()
            tickerLog.notice("space changed: re-shown")
        }

        applySettings()
        reposition()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
    }

    /// `overridingSuppression` は緊急地震速報のように、睡眠時間帯でも必ず出すもの向け。
    func enqueue(
        _ text: String,
        badge: String = TickerTextStyler.badge,
        badgeColor: NSColor? = nil,
        soundSelection: String? = nil,
        soundLoops: Bool? = nil,
        overridingSuppression: Bool = false,
        link: URL? = nil
    ) {
        guard !isSuppressed || overridingSuppression else { return }
        tickerView.enqueue(
            text,
            badge: badge,
            badgeColor: badgeColor,
            soundSelection: soundSelection,
            soundLoops: soundLoops,
            link: link
        )
        guard settings.isEnabled else { return }
        showPanel(overridingSuppression: overridingSuppression)
    }

    func applySettings() {
        panel.ignoresMouseEvents = settings.ignoresMouse
        reposition()
        tickerView.refreshLayout()
        if settings.isEnabled && !isSuppressed && tickerView.hasContent {
            showPanel()
        } else {
            if panel.isVisible { onTickerWillHide?() }
            fadeGeneration += 1
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        guard suppressed else { return }
        tickerView.clear()
        if panel.isVisible { onTickerWillHide?() }
        fadeGeneration += 1
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    func dismiss() {
        guard tickerView.hasContent || panel.isVisible else { return }
        tickerView.clear()
    }

    /// クリックの振り分け。ダブルクリックは閉じる。シングルクリックは、その位置に
    /// 流れているメッセージにリンクがあれば開く。ダブルクリックの1回目で開いて
    /// しまわないよう、システムのダブルクリック間隔だけ待ってから確定する。
    /// どのメッセージを押したかは、待つ前のクリック時点で決める（流れ続けるため）。
    private func handleClick(viewPoint: NSPoint, clickCount: Int) {
        pendingLinkOpen?.cancel()
        pendingLinkOpen = nil
        if clickCount >= 2 {
            dismiss()
            return
        }
        guard let link = tickerView.link(at: viewPoint) else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingLinkOpen = nil
            NSWorkspace.shared.open(link)
            tickerLog.notice("opened link: \(link.absoluteString, privacy: .public)")
        }
        pendingLinkOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// すべての操作スペースとフルスクリーンの上に出す宣言。macOS 側で
    /// 割り当てが外れることがあるため、表示のたびに宣言し直す。
    private func applyAllSpacesBehavior() {
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    private func showPanel(overridingSuppression: Bool = false) {
        guard !isSuppressed || overridingSuppression else {
            tickerLog.notice("showPanel skipped: suppressed")
            return
        }
        // 非表示の間にディスプレイ構成が変わっていると、パネルが消えた画面に
        // 取り残されたまま orderFront しても映らない。表示直前に必ず置き直す。
        reposition()
        // 非表示の間にスペースを移動していると割り当てが外れていることがある。
        applyAllSpacesBehavior()
        tickerLog.notice("showPanel: frame=\(String(describing: self.panel.frame), privacy: .public)")
        fadeGeneration += 1
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
        panel.orderFrontRegardless()
        onTickerDidShow?()
    }

    private func fadeOutPanel() {
        onTickerWillHide?()
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self,
                  generation == self.fadeGeneration,
                  !self.tickerView.hasContent else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    private func reposition() {
        guard let screen = selectedScreen() else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 10
        let inset: CGFloat = 20
        let thickness = tickerView.requiredThickness
        let frame: NSRect

        switch settings.edge {
        case .top:
            frame = NSRect(
                x: visible.minX + inset,
                y: visible.maxY - thickness - margin,
                width: max(300, visible.width - inset * 2),
                height: thickness
            )
        case .bottom:
            frame = NSRect(
                x: visible.minX + inset,
                y: visible.minY + margin,
                width: max(300, visible.width - inset * 2),
                height: thickness
            )
        case .left:
            frame = NSRect(
                x: visible.minX + margin,
                y: visible.minY + inset,
                width: thickness,
                height: max(300, visible.height - inset * 2)
            )
        case .right:
            frame = NSRect(
                x: visible.maxX - thickness - margin,
                y: visible.minY + inset,
                width: thickness,
                height: max(300, visible.height - inset * 2)
            )
        }
        panel.setFrame(frame, display: true)
        tickerView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func selectedScreen() -> NSScreen? {
        let screens = NSScreen.screens
        // id と名前の両方が一致するものが最優先。id は再起動で振り直されることが
        // あるため、一致しなければ名前だけで探す。名前でも見つからなければ id。
        if settings.displayID != 0 || !settings.displayName.isEmpty {
            if let exact = screens.first(where: {
                $0.displayID == settings.displayID && $0.localizedName == settings.displayName
            }) {
                return exact
            }
            if !settings.displayName.isEmpty,
               let byName = screens.first(where: { $0.localizedName == settings.displayName }) {
                return byName
            }
            if settings.displayID != 0,
               let byID = screens.first(where: { $0.displayID == settings.displayID }) {
                return byID
            }
        }
        return NSScreen.main ?? screens.first
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

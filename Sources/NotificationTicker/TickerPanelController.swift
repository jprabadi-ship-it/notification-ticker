import AppKit
import QuartzCore

enum TickerTextStyler {
    static let titleColor = NSColor(calibratedRed: 1, green: 0.03, blue: 0.03, alpha: 1)
    static let contentColor = NSColor.white
    static let timeColor = NSColor(calibratedRed: 1, green: 0.47, blue: 0.04, alpha: 1)
    static let badgeTextColor = NSColor.white
    static let badgeBackgroundColor = NSColor(calibratedRed: 0.85, green: 0.04, blue: 0.04, alpha: 1)
    /// 各モニターがメッセージを組み立てるときに使う入力用の区切り。
    static let separator = "  •  "
    /// 行頭に赤地で描画されるバッジ（フィード由来のメッセージ用）。
    static let badge = " 通知 "
    /// フィード以外（macOS通知・地震速報など）に使うバッジ。
    static let announcementBadge = " 告知 "
    /// 行頭バッジとして扱う文字列の一覧。
    static let badges = [badge, announcementBadge]
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

        for badgeText in badges {
            var searchStart = text.startIndex
            while let badgeRange = text.range(of: badgeText, range: searchStart..<text.endIndex) {
                result.addAttributes([
                    .foregroundColor: badgeTextColor,
                    .strokeColor: badgeTextColor,
                    .strokeWidth: 0,
                    .backgroundColor: badgeBackgroundColor
                ], range: NSRange(badgeRange, in: text))
                searchStart = badgeRange.upperBound
            }
        }
        return result
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

    /// タイトルの直後に発行時刻を差し込む。フィード以外（通知・地震速報）の入力用。
    static func insertingTime(_ date: Date, into text: String) -> String {
        let time = FeedDateParser.displayTime(for: date)
        var sections = text.components(separatedBy: TickerTextStyler.separator)
        guard sections.count > 1 else {
            return ([time, text]).joined(separator: TickerTextStyler.separator)
        }
        sections.insert(time, at: 1)
        return sections.joined(separator: TickerTextStyler.separator)
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
    private var messages: [String] = []
    private var currentMessage: String?
    private var currentX: CGFloat = 0
    /// 背景の警告ストライプが右方向へ進んだ距離。1周期ぶんで折り返す。
    private var stripePhase: CGFloat = 0
    /// ストライプのスクロール速度（pt/秒）。本文より大幅に遅くしてゆっくり流す。
    private let stripeScrollSpeed: CGFloat = 8
    private var previousTimestamp = ProcessInfo.processInfo.systemUptime
    var onActivityChange: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContentMetricsChange: (() -> Void)?

    var hasContent: Bool { currentMessage != nil || !messages.isEmpty }

    var requiredThickness: CGFloat {
        let rowHeight = textRowHeight
        let baseThickness = max(60, rowHeight + 24)
        guard let currentMessage else { return baseThickness }
        let lineCount = min(
            TickerTextLayout.maximumLines,
            max(1, currentMessage.components(separatedBy: "\n").count)
        )
        return max(60, rowHeight * CGFloat(lineCount) + 24)
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
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    func enqueue(_ message: String, badge: String = TickerTextStyler.badge) {
        let cleaned = TickerTextLayout.titleAndContentLines(
            in: message.trimmingCharacters(in: .whitespacesAndNewlines),
            badge: badge
        )
        guard !cleaned.isEmpty else { return }
        messages.append(cleaned)
        if currentMessage == nil { advanceMessage() }
    }

    func clear() {
        messages.removeAll()
        currentMessage = nil
        onContentMetricsChange?()
        onActivityChange?(false)
        needsDisplay = true
    }

    func refreshAppearance() {
        needsDisplay = true
    }

    func refreshLayout() {
        if currentMessage != nil { currentX = scrollExtent + 24 }
        onContentMetricsChange?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard settings.isEnabled else { return }

        let backgroundRect = bounds.insetBy(dx: 0, dy: 2)
        let path = NSBezierPath(roundedRect: backgroundRect, xRadius: 2, yRadius: 2)
        NSColor.black.withAlphaComponent(settings.backgroundOpacity).setFill()
        path.fill()
        drawWarningStripes(in: backgroundRect)

        guard let currentMessage else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let styledMessage = styledText(currentMessage, paragraphStyle: paragraph)

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
            drawLines(styledMessage, sourceText: currentMessage, x: currentX, canvasHeight: bounds.width)
            context.restoreGState()
        } else {
            drawLines(styledMessage, sourceText: currentMessage, x: currentX, canvasHeight: bounds.height)
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

        guard settings.isEnabled, let currentMessage else {
            needsDisplay = true
            return
        }

        currentX -= CGFloat(settings.speed * elapsed)
        let width = measuredSize(of: currentMessage).width

        if currentX + width < 0 { advanceMessage() }
        needsDisplay = true
    }

    private func advanceMessage() {
        if messages.isEmpty {
            currentMessage = nil
            onContentMetricsChange?()
            onActivityChange?(false)
            needsDisplay = true
            return
        }
        currentMessage = messages.removeFirst()
        onContentMetricsChange?()
        currentX = scrollExtent + 24
        onActivityChange?(true)
        needsDisplay = true
    }

    private var scrollExtent: CGFloat {
        settings.edge.isVertical ? bounds.height : bounds.width
    }

    private var selectedFont: NSFont {
        if settings.fontFamily == TickerSettings.evaMinchoFontFamily {
            return evaMinchoFont
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
        canvasHeight: CGFloat
    ) {
        let source = sourceText as NSString
        var location = 0
        // Point-based drawing leaves the font's leading above the glyphs.
        // Split it across both sides so the visible letters sit centrally.
        var y = canvasHeight - 12 - textRowHeight + textVerticalCenteringOffset

        for line in sourceText.components(separatedBy: "\n").prefix(TickerTextLayout.maximumLines) {
            let length = (line as NSString).length
            let range = NSRange(location: location, length: length)
            if length > 0 {
                attributed.attributedSubstring(from: range).draw(at: NSPoint(x: x, y: y))
            }
            location += length + 1
            y -= textRowHeight
            if location > source.length { break }
        }
    }

    private var evaMinchoFont: NSFont {
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
        let bandHeight = min(10, max(7, backgroundRect.height * 0.16))
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
            strokeWidth: settings.fontFamily == TickerSettings.evaMinchoFontFamily ? -3.0 : 0,
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
    private var globalMouseMonitor: Any?
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        tickerView.onActivityChange = { [weak self] isActive in
            guard let self else { return }
            if isActive && self.settings.isEnabled {
                self.showPanel()
            } else {
                self.fadeOutPanel()
            }
        }
        tickerView.onDoubleClick = { [weak self] in self?.dismiss() }
        tickerView.onContentMetricsChange = { [weak self] in self?.reposition() }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.clickCount >= 2 else { return }
            DispatchQueue.main.async {
                guard let self,
                      self.panel.isVisible,
                      self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.dismiss()
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reposition() }

        applySettings()
        reposition()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    func enqueue(_ text: String, badge: String = TickerTextStyler.badge) {
        guard !isSuppressed else { return }
        tickerView.enqueue(text, badge: badge)
        if settings.isEnabled { showPanel() }
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

    private func showPanel() {
        guard !isSuppressed else { return }
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
        if settings.displayID != 0,
           let selected = NSScreen.screens.first(where: { $0.displayID == settings.displayID }) {
            return selected
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

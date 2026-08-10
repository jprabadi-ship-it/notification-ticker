import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// 原点を左上にするビュー。NSScrollView に縦積みの設定項目を載せるために使う。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settings: TickerSettings
    private let monitor: NotificationMonitor
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let opacityValue = NSTextField(labelWithString: "")
    private let speedValue = NSTextField(labelWithString: "")
    private let fontValue = NSTextField(labelWithString: "")
    private let earthquakeStatusLabel = NSTextField(labelWithString: "")
    private let earthquakeIntensityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let earthquakeSoundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let earthquakeLoopCheckbox = NSButton(checkboxWithTitle: "この音をループ再生", target: nil, action: nil)
    private let localAreaCheckbox = NSButton(checkboxWithTitle: "自分の地点の震度も表示", target: nil, action: nil)
    private let localAreaField = NSTextField()
    private let eewCheckbox = NSButton(checkboxWithTitle: "緊急地震速報（揺れる前の予測）を表示", target: nil, action: nil)
    private let eewIntensityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let eewStatusLabel = NSTextField(labelWithString: "")
    private let edgePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let soundLoopCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "ログイン時に開く", target: nil, action: nil)
    private let soundsFolderLabel = NSTextField(labelWithString: "")
    private let quietHoursCheckbox = NSButton()
    private let quietStartPicker = NSDatePicker()
    private let quietEndPicker = NSDatePicker()
    private let quietStatusLabel = NSTextField(labelWithString: "")
    private var screenObserver: NSObjectProtocol?
    private var quietStatusTimer: Timer?
    var onTest: (() -> Void)?
    var onTestSound: (() -> Void)?
    var onShowFeeds: (() -> Void)?
    /// 効果音を選び直したときの試聴。
    var onPreviewSound: ((String) -> Void)?

    init(settings: TickerSettings, monitor: NotificationMonitor) {
        self.settings = settings
        self.monitor = monitor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 775),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notification Ticker 設定"
        window.minSize = NSSize(width: 520, height: 420)
        // 項目が増えて画面に収まらない場合に備え、可視領域より高くしない。
        if let visible = NSScreen.main?.visibleFrame {
            let height = min(775, visible.height - 40)
            window.setContentSize(NSSize(width: 520, height: height))
        }
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reloadDisplays() }
        quietStatusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateQuietHoursUI()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        quietStatusTimer?.invalidate()
    }

    override func showWindow(_ sender: Any?) {
        // 他の場所（システム設定）で変更されている場合があるので開くたびに読み直す。
        updateLaunchAtLoginCheckbox()
        super.showWindow(sender)
    }

    func updateStatus(_ status: NotificationMonitor.Status) {
        statusLabel.stringValue = status.label
        switch status {
        case .monitoring:
            statusLabel.textColor = .systemGreen
        case .pausedForQuietHours:
            statusLabel.textColor = .secondaryLabelColor
        default:
            statusLabel.textColor = .systemOrange
        }
        updateStatusIcon(hasPermission: status != .permissionRequired)
    }

    func updateEarthquakeStatus(_ status: String) {
        earthquakeStatusLabel.stringValue = status
    }

    func updateEEWStatus(_ status: String) {
        eewStatusLabel.stringValue = status
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Notification Ticker")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.stringValue = monitor.isTrusted ? "通知を監視中" : "アクセシビリティ許可が必要です"
        statusLabel.textColor = monitor.isTrusted ? .systemGreen : .systemOrange
        updateStatusIcon(hasPermission: monitor.isTrusted)

        let permissionButton = NSButton(title: "アクセシビリティ設定を開く", target: self, action: #selector(requestPermission))
        permissionButton.bezelStyle = .rounded

        let opacity = makeSlider(
            label: "背景の濃さ",
            min: 0.05,
            max: 0.95,
            value: settings.backgroundOpacity,
            action: #selector(opacityChanged(_:)),
            valueLabel: opacityValue
        )
        updateOpacityLabel()

        let speed = makeSlider(
            label: "スクロール速度",
            min: 30,
            max: 280,
            value: settings.speed,
            action: #selector(speedChanged(_:)),
            valueLabel: speedValue
        )
        updateSpeedLabel()

        let font = makeSlider(
            label: "文字サイズ",
            min: 12,
            max: 60,
            value: settings.fontSize,
            action: #selector(fontChanged(_:)),
            valueLabel: fontValue
        )
        updateFontLabel()

        fontPopup.addItem(withTitle: "極太明朝")
        fontPopup.lastItem?.representedObject = TickerSettings.boldMinchoFontFamily
        fontPopup.addItem(withTitle: "システム標準")
        fontPopup.lastItem?.representedObject = "__system__"
        for family in NSFontManager.shared.availableFontFamilies.sorted(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        }) {
            fontPopup.addItem(withTitle: family)
            fontPopup.lastItem?.representedObject = family
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))
        let selectedFontIndex = fontPopup.itemArray.firstIndex {
            ($0.representedObject as? String) == settings.fontFamily
        } ?? 0
        fontPopup.selectItem(at: selectedFontIndex)
        let fontFamilyRow = makePopupRow(label: "フォント", popup: fontPopup)

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginChanged(_:))
        launchAtLoginCheckbox.toolTip = "macOS のログイン項目に登録します。"
        updateLaunchAtLoginCheckbox()

        let clickThrough = NSButton(
            checkboxWithTitle: "ティッカー上のクリックを背後へ通す",
            target: self,
            action: #selector(clickThroughChanged(_:))
        )
        clickThrough.state = settings.ignoresMouse ? .on : .off

        let ignoreClockWeatherWidgets = NSButton(
            checkboxWithTitle: "時計・曜日・気温ウィジェット（Widgy等）を無視",
            target: self,
            action: #selector(ignoreClockWeatherWidgetsChanged(_:))
        )
        ignoreClockWeatherWidgets.state = settings.ignoresClockWeatherWidgets ? .on : .off

        quietHoursCheckbox.setButtonType(.switch)
        quietHoursCheckbox.title = "睡眠時間帯は通知・ニュース・地震速報・音声を停止（緊急地震速報を除く）"
        quietHoursCheckbox.target = self
        quietHoursCheckbox.action = #selector(quietHoursEnabledChanged(_:))
        quietHoursCheckbox.state = settings.quietHoursEnabled ? .on : .off

        configureTimePicker(
            quietStartPicker,
            minutes: settings.quietHoursStartMinutes,
            action: #selector(quietStartChanged(_:))
        )
        configureTimePicker(
            quietEndPicker,
            minutes: settings.quietHoursEndMinutes,
            action: #selector(quietEndChanged(_:))
        )
        let quietTimeLabel = NSTextField(labelWithString: "停止時間")
        quietTimeLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let quietSeparator = NSTextField(labelWithString: "〜")
        quietStatusLabel.textColor = .secondaryLabelColor
        quietStatusLabel.alignment = .right
        let quietTimeRow = NSStackView(views: [quietTimeLabel, quietStartPicker, quietSeparator, quietEndPicker, quietStatusLabel])
        quietTimeRow.orientation = .horizontal
        quietTimeRow.alignment = .centerY
        quietTimeRow.spacing = 8
        updateQuietHoursUI()

        let earthquakeEnabled = NSButton(
            checkboxWithTitle: "地震を津波情報付きで表示",
            target: self,
            action: #selector(earthquakeEnabledChanged(_:))
        )
        earthquakeEnabled.state = settings.earthquakeAlertsEnabled ? .on : .off
        earthquakeStatusLabel.textColor = .secondaryLabelColor
        earthquakeStatusLabel.alignment = .right

        earthquakeIntensityPopup.removeAllItems()
        for intensity in JMAEarthquakeReport.selectableIntensities {
            earthquakeIntensityPopup.addItem(withTitle: "震度\(intensity)以上")
            earthquakeIntensityPopup.lastItem?.representedObject = intensity
        }
        earthquakeIntensityPopup.target = self
        earthquakeIntensityPopup.action = #selector(earthquakeIntensityChanged(_:))
        selectCurrentEarthquakeIntensity()
        let earthquakeIntensityRow = makePopupRow(label: "地震の下限震度", popup: earthquakeIntensityPopup)

        earthquakeSoundPopup.target = self
        earthquakeSoundPopup.action = #selector(earthquakeSoundChanged(_:))
        earthquakeLoopCheckbox.target = self
        earthquakeLoopCheckbox.action = #selector(earthquakeLoopChanged(_:))
        reloadEarthquakeSoundPopup()
        localAreaCheckbox.target = self
        localAreaCheckbox.action = #selector(localAreaEnabledChanged(_:))
        localAreaCheckbox.state = settings.localAreaEnabled ? .on : .off

        localAreaField.stringValue = settings.localAreaName
        localAreaField.placeholderString = "例: 東京都 練馬区"
        localAreaField.target = self
        localAreaField.action = #selector(localAreaNameChanged(_:))
        localAreaField.delegate = self
        localAreaField.toolTip = "気象庁が発表する地域名と突き合わせます。市区町村が無ければ都道府県の震度を表示します。"
        let localAreaRow = makePopupRowLike(label: "自分の地点", field: localAreaField)

        eewCheckbox.target = self
        eewCheckbox.action = #selector(eewEnabledChanged(_:))
        eewCheckbox.state = settings.eewEnabled ? .on : .off
        eewCheckbox.toolTip = "P2P地震情報から緊急地震速報を受け取ります。予測値のため外れることがあり、公式の防災情報提供手段ではありません。"
        eewStatusLabel.textColor = .secondaryLabelColor
        eewStatusLabel.alignment = .right
        let eewRow = NSStackView(views: [eewCheckbox, eewStatusLabel])
        eewRow.orientation = .horizontal
        eewRow.alignment = .centerY
        eewRow.distribution = .fill
        eewRow.spacing = 10

        eewIntensityPopup.removeAllItems()
        for intensity in JMAEarthquakeReport.selectableIntensities {
            eewIntensityPopup.addItem(withTitle: "震度\(intensity)以上")
            eewIntensityPopup.lastItem?.representedObject = intensity
        }
        eewIntensityPopup.target = self
        eewIntensityPopup.action = #selector(eewIntensityChanged(_:))
        if let selected = eewIntensityPopup.itemArray.first(where: {
            ($0.representedObject as? String) == settings.eewMinimumIntensity
        }) {
            eewIntensityPopup.select(selected)
        } else {
            eewIntensityPopup.selectItem(at: 0)
        }
        let eewIntensityRow = makePopupRow(label: "予測震度の下限", popup: eewIntensityPopup)

        let earthquakeSoundRow = NSStackView(views: [
            {
                let label = NSTextField(labelWithString: "地震の効果音")
                label.widthAnchor.constraint(equalToConstant: 120).isActive = true
                return label
            }(),
            earthquakeSoundPopup,
            earthquakeLoopCheckbox
        ])
        earthquakeSoundRow.orientation = .horizontal
        earthquakeSoundRow.alignment = .centerY
        earthquakeSoundRow.distribution = .fill
        earthquakeSoundRow.spacing = 10
        earthquakeSoundPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateEarthquakeUI()

        let earthquakeRow = NSStackView(views: [earthquakeEnabled, earthquakeStatusLabel])
        earthquakeRow.orientation = .horizontal
        earthquakeRow.alignment = .centerY
        earthquakeRow.distribution = .fill
        earthquakeRow.spacing = 10

        let soundEnabled = NSButton(
            checkboxWithTitle: "新しい通知を検出したら音を鳴らす",
            target: self,
            action: #selector(soundEnabledChanged(_:))
        )
        soundEnabled.state = settings.soundEnabled ? .on : .off

        soundPopup.target = self
        soundPopup.action = #selector(soundChanged(_:))
        reloadSoundPopup()

        soundLoopCheckbox.title = "この音をループ再生"
        soundLoopCheckbox.target = self
        soundLoopCheckbox.action = #selector(soundLoopChanged(_:))
        updateSoundLoopCheckbox()

        let soundTestButton = NSButton(title: "音を試す", target: self, action: #selector(testSound))
        soundTestButton.bezelStyle = .rounded
        let soundLabel = NSTextField(labelWithString: "通知音")
        soundLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let soundRow = NSStackView(views: [soundLabel, soundPopup, soundLoopCheckbox, soundTestButton])
        soundRow.orientation = .horizontal
        soundRow.alignment = .centerY
        soundRow.distribution = .fill
        soundRow.spacing = 10
        soundPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let importSoundButton = NSButton(title: "MP3を追加…", target: self, action: #selector(importMP3))
        importSoundButton.bezelStyle = .rounded

        soundsFolderLabel.lineBreakMode = .byTruncatingHead
        soundsFolderLabel.textColor = .secondaryLabelColor
        soundsFolderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        soundsFolderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateSoundsFolderLabel()
        let chooseFolderButton = NSButton(title: "変更…", target: self, action: #selector(chooseSoundsFolder))
        chooseFolderButton.bezelStyle = .rounded
        let resetFolderButton = NSButton(title: "既定に戻す", target: self, action: #selector(resetSoundsFolder))
        resetFolderButton.bezelStyle = .rounded
        let soundsFolderNameLabel = NSTextField(labelWithString: "MP3の保存先")
        soundsFolderNameLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let soundsFolderRow = NSStackView(views: [
            soundsFolderNameLabel, soundsFolderLabel, chooseFolderButton, resetFolderButton
        ])
        soundsFolderRow.orientation = .horizontal
        soundsFolderRow.alignment = .centerY
        soundsFolderRow.distribution = .fill
        soundsFolderRow.spacing = 10

        let testButton = NSButton(title: "テスト表示", target: self, action: #selector(showTest))
        testButton.bezelStyle = .rounded
        let feedsButton = NSButton(title: "ニュース／RSSフィード…", target: self, action: #selector(showFeeds))
        feedsButton.bezelStyle = .rounded
        let bottomRow = NSStackView(views: [feedsButton, testButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 10

        let header = NSStackView(views: [statusIcon, statusLabel, permissionButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 12
        statusIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        for edge in TickerEdge.allCases {
            edgePopup.addItem(withTitle: edge.label)
            edgePopup.lastItem?.representedObject = edge.rawValue
        }
        edgePopup.target = self
        edgePopup.action = #selector(edgeChanged(_:))
        edgePopup.selectItem(withTitle: settings.edge.label)

        displayPopup.target = self
        displayPopup.action = #selector(displayChanged(_:))
        reloadDisplays()

        let edgeRow = makePopupRow(label: "表示位置", popup: edgePopup)
        let displayRow = makePopupRow(label: "表示ディスプレイ", popup: displayPopup)

        let stack = NSStackView(views: [
            title, header, separator(), edgeRow, displayRow,
            opacity, speed, fontFamilyRow, font, launchAtLoginCheckbox, clickThrough, ignoreClockWeatherWidgets,
            separator(), quietHoursCheckbox, quietTimeRow, earthquakeRow, earthquakeIntensityRow,
            localAreaCheckbox, localAreaRow, earthquakeSoundRow,
            eewRow, eewIntensityRow,
            soundEnabled, soundRow, soundsFolderRow, importSoundButton, bottomRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 設定項目が増えてウィンドウ高を超えても全項目に到達できるようスクロールさせる。
        // 反転させないと NSScrollView は下端起点になり、先頭が隠れる。
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            opacity.widthAnchor.constraint(equalTo: stack.widthAnchor),
            speed.widthAnchor.constraint(equalTo: stack.widthAnchor),
            font.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fontFamilyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quietTimeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            earthquakeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            earthquakeIntensityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            earthquakeSoundRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            localAreaRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            eewRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            eewIntensityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            edgeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            displayRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            soundRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            soundsFolderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            soundTestButton.trailingAnchor.constraint(equalTo: soundRow.trailingAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            testButton.trailingAnchor.constraint(equalTo: bottomRow.trailingAnchor)
        ])
    }

    /// ラベル＋入力欄の行。ポップアップ行と幅と間隔を揃える。
    private func makePopupRowLike(label: String, field: NSTextField) -> NSStackView {
        let name = NSTextField(labelWithString: label)
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func makePopupRow(label: String, popup: NSPopUpButton) -> NSStackView {
        let name = NSTextField(labelWithString: label)
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func configureTimePicker(_ picker: NSDatePicker, minutes: Int, action: Selector) {
        picker.datePickerElements = [.hourMinute]
        picker.datePickerStyle = .textFieldAndStepper
        picker.target = self
        picker.action = action
        picker.dateValue = dateForMinutes(minutes)
    }

    private func dateForMinutes(_ minutes: Int) -> Date {
        let clamped = min(max(minutes, 0), 23 * 60 + 59)
        return Calendar.current.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func minutesFromDate(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func updateQuietHoursUI() {
        let enabled = settings.quietHoursEnabled
        quietStartPicker.isEnabled = enabled
        quietEndPicker.isEnabled = enabled
        if !enabled {
            quietStatusLabel.stringValue = "無効"
        } else if settings.isQuietHoursActive {
            quietStatusLabel.stringValue = "現在停止中"
        } else {
            quietStatusLabel.stringValue = "時間外"
        }
    }

    private func updateStatusIcon(hasPermission: Bool) {
        let symbolName = hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        statusIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        statusIcon.contentTintColor = hasPermission ? .systemGreen : .systemOrange
    }

    private func availableSystemSoundNames() -> [String] {
        let soundDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: soundDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var names = Set(urls
            .filter { ["aiff", "wav", "caf"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent })
        names.insert(settings.soundName)
        names.insert("Glass")
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// ループ設定は音源ごとなので、選択中の音に合わせて表示を更新する。
    private func updateSoundLoopCheckbox() {
        soundLoopCheckbox.state = settings.loopsSound(settings.soundSelection) ? .on : .off
    }

    @objc private func soundLoopChanged(_ sender: NSButton) {
        settings.setLoops(sender.state == .on, forSound: settings.soundSelection)
        updateEarthquakeUI()
    }

    private func reloadSoundPopup() {
        soundPopup.removeAllItems()
        for name in availableSystemSoundNames() {
            soundPopup.addItem(withTitle: name)
            soundPopup.lastItem?.representedObject = "system:\(name)"
        }

        let customPaths = settings.customSoundPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !customPaths.isEmpty {
            soundPopup.menu?.addItem(.separator())
            for path in customPaths {
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                soundPopup.addItem(withTitle: "MP3: \(name)")
                soundPopup.lastItem?.representedObject = "file:\(path)"
            }
        }

        if let selected = soundPopup.itemArray.first(where: {
            ($0.representedObject as? String) == settings.soundSelection
        }) {
            soundPopup.select(selected)
        } else {
            soundPopup.selectItem(at: 0)
            if let value = soundPopup.selectedItem?.representedObject as? String {
                settings.soundSelection = value
            }
        }
    }

    private func importSoundFiles(_ urls: [URL]) throws -> [String] {
        let manager = FileManager.default
        guard let directory = settings.soundsFolder else {
            throw CocoaError(.fileNoSuchFile)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var imported: [String] = []
        for source in urls {
            let baseName = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension.lowercased()
            var destination = directory.appendingPathComponent("\(baseName).\(ext)")
            var suffix = 2
            while manager.fileExists(atPath: destination.path) {
                destination = directory.appendingPathComponent("\(baseName)-\(suffix).\(ext)")
                suffix += 1
            }
            try manager.copyItem(at: source, to: destination)
            imported.append(destination.path)
        }
        return imported
    }

    private func reloadDisplays() {
        displayPopup.removeAllItems()
        displayPopup.addItem(withTitle: "メインディスプレイ（自動）")
        displayPopup.lastItem?.representedObject = NSNumber(value: UInt32(0))

        for (index, screen) in NSScreen.screens.enumerated() {
            guard let displayID = screen.displayID else { continue }
            let width = Int(screen.frame.width)
            let height = Int(screen.frame.height)
            let title = "\(index + 1): \(screen.localizedName)（\(width)×\(height)）"
            displayPopup.addItem(withTitle: title)
            displayPopup.lastItem?.representedObject = NSNumber(value: displayID)
        }

        let selectedIndex = displayPopup.itemArray.firstIndex { item in
            (item.representedObject as? NSNumber)?.uint32Value == settings.displayID
        } ?? 0
        displayPopup.selectItem(at: selectedIndex)
    }

    private func makeSlider(
        label: String,
        min: Double,
        max: Double,
        value: Double,
        action: Selector,
        valueLabel: NSTextField
    ) -> NSStackView {
        let name = NSTextField(labelWithString: label)
        name.frame.size.width = 120
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        valueLabel.alignment = .right
        valueLabel.frame.size.width = 58
        let row = NSStackView(views: [name, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        valueLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func requestPermission() {
        monitor.requestPermission()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        settings.backgroundOpacity = sender.doubleValue
        updateOpacityLabel()
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        settings.speed = sender.doubleValue
        updateSpeedLabel()
    }

    @objc private func fontChanged(_ sender: NSSlider) {
        settings.fontSize = sender.doubleValue
        updateFontLabel()
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        guard let family = sender.selectedItem?.representedObject as? String else { return }
        settings.fontFamily = family
    }

    /// ログイン項目の登録状態は macOS 側が持つので、設定には保存せず都度読み出す。
    private func updateLaunchAtLoginCheckbox() {
        launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let service = SMAppService.mainApp
        do {
            if sender.state == .on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "ログイン項目を変更できませんでした"
            alert.informativeText = """
            \(error.localizedDescription)

            アプリケーションフォルダに置いたうえで、システム設定 → 一般 → ログイン項目 から追加してください。
            """
            alert.alertStyle = .warning
            alert.runModal()
        }
        updateLaunchAtLoginCheckbox()
    }

    @objc private func clickThroughChanged(_ sender: NSButton) {
        settings.ignoresMouse = sender.state == .on
    }

    @objc private func ignoreClockWeatherWidgetsChanged(_ sender: NSButton) {
        settings.ignoresClockWeatherWidgets = sender.state == .on
    }

    @objc private func quietHoursEnabledChanged(_ sender: NSButton) {
        settings.quietHoursEnabled = sender.state == .on
        updateQuietHoursUI()
    }

    @objc private func quietStartChanged(_ sender: NSDatePicker) {
        settings.quietHoursStartMinutes = minutesFromDate(sender.dateValue)
        updateQuietHoursUI()
    }

    @objc private func quietEndChanged(_ sender: NSDatePicker) {
        settings.quietHoursEndMinutes = minutesFromDate(sender.dateValue)
        updateQuietHoursUI()
    }

    @objc private func earthquakeEnabledChanged(_ sender: NSButton) {
        settings.earthquakeAlertsEnabled = sender.state == .on
        updateEarthquakeUI()
    }

    @objc private func earthquakeIntensityChanged(_ sender: NSPopUpButton) {
        guard let intensity = sender.selectedItem?.representedObject as? String else { return }
        settings.earthquakeMinimumIntensity = intensity
        updateEarthquakeUI()
    }

    private func selectCurrentEarthquakeIntensity() {
        let selected = earthquakeIntensityPopup.itemArray.first {
            ($0.representedObject as? String) == settings.earthquakeMinimumIntensity
        }
        if let selected {
            earthquakeIntensityPopup.select(selected)
        } else {
            earthquakeIntensityPopup.selectItem(at: 0)
        }
    }

    /// 地震の効果音。先頭は共通の通知音を使う選択肢。
    private func reloadEarthquakeSoundPopup() {
        earthquakeSoundPopup.removeAllItems()
        earthquakeSoundPopup.addItem(withTitle: "共通の通知音")
        earthquakeSoundPopup.lastItem?.representedObject = ""
        for name in availableSystemSoundNames() {
            earthquakeSoundPopup.addItem(withTitle: name)
            earthquakeSoundPopup.lastItem?.representedObject = "system:\(name)"
        }
        let customPaths = settings.customSoundPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !customPaths.isEmpty {
            earthquakeSoundPopup.menu?.addItem(.separator())
            for path in customPaths {
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                earthquakeSoundPopup.addItem(withTitle: "MP3: \(name)")
                earthquakeSoundPopup.lastItem?.representedObject = "file:\(path)"
            }
        }
        let selection = settings.earthquakeSoundSelection
        if let selected = earthquakeSoundPopup.itemArray.first(where: {
            ($0.representedObject as? String) == selection
        }) {
            earthquakeSoundPopup.select(selected)
        } else {
            earthquakeSoundPopup.selectItem(at: 0)
        }
    }

    private var effectiveEarthquakeSound: String {
        settings.earthquakeSoundSelection.isEmpty
            ? settings.soundSelection
            : settings.earthquakeSoundSelection
    }

    @objc private func eewEnabledChanged(_ sender: NSButton) {
        settings.eewEnabled = sender.state == .on
        updateEarthquakeUI()
    }

    @objc private func eewIntensityChanged(_ sender: NSPopUpButton) {
        guard let intensity = sender.selectedItem?.representedObject as? String else { return }
        settings.eewMinimumIntensity = intensity
    }

    @objc private func localAreaEnabledChanged(_ sender: NSButton) {
        settings.localAreaEnabled = sender.state == .on
        updateEarthquakeUI()
    }

    @objc private func localAreaNameChanged(_ sender: NSTextField) {
        settings.localAreaName = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func earthquakeSoundChanged(_ sender: NSPopUpButton) {
        guard let selection = sender.selectedItem?.representedObject as? String else { return }
        settings.earthquakeSoundSelection = selection
        updateEarthquakeUI()
        onPreviewSound?(selection.isEmpty ? settings.soundSelection : selection)
    }

    @objc private func earthquakeLoopChanged(_ sender: NSButton) {
        settings.setLoops(sender.state == .on, forSound: effectiveEarthquakeSound)
        updateSoundLoopCheckbox()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === localAreaField else { return }
        settings.localAreaName = localAreaField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 下限震度は地震速報が有効なときだけ操作できる。状態表示も合わせて更新する。
    private func updateEarthquakeUI() {
        let enabled = settings.earthquakeAlertsEnabled
        localAreaCheckbox.isEnabled = enabled
        localAreaField.isEnabled = enabled && settings.localAreaEnabled
        eewIntensityPopup.isEnabled = settings.eewEnabled
        if !settings.eewEnabled { eewStatusLabel.stringValue = "緊急地震速報は停止中" }
        earthquakeIntensityPopup.isEnabled = enabled
        earthquakeSoundPopup.isEnabled = enabled
        earthquakeLoopCheckbox.isEnabled = enabled
        earthquakeLoopCheckbox.state = settings.loopsSound(effectiveEarthquakeSound) ? .on : .off
        earthquakeStatusLabel.stringValue = enabled
            ? "震度\(settings.earthquakeMinimumIntensity)以上を監視中"
            : "地震速報は停止中"
    }

    @objc private func edgeChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let edge = TickerEdge(rawValue: rawValue) else { return }
        settings.edge = edge
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        guard let number = sender.selectedItem?.representedObject as? NSNumber else { return }
        settings.displayID = number.uint32Value
    }

    @objc private func soundEnabledChanged(_ sender: NSButton) {
        settings.soundEnabled = sender.state == .on
    }

    @objc private func soundChanged(_ sender: NSPopUpButton) {
        guard let selection = sender.selectedItem?.representedObject as? String else { return }
        settings.soundSelection = selection
        updateSoundLoopCheckbox()
        onTestSound?()
    }

    /// 保存先はパスが長くなりがちなので、ホーム配下は ~ に省略して表示する。
    private func updateSoundsFolderLabel() {
        let path = settings.soundsFolder?.path ?? "(取得できません)"
        soundsFolderLabel.stringValue = (path as NSString).abbreviatingWithTildeInPath
        soundsFolderLabel.toolTip = path
    }

    @objc private func chooseSoundsFolder() {
        let panel = NSOpenPanel()
        panel.title = "MP3のコピー先フォルダを選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let current = settings.soundsFolder, FileManager.default.fileExists(atPath: current.path) {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 書き込めない場所を選ぶと、追加のたびに失敗するので先に確かめる。
        guard FileManager.default.isWritableFileDirectory(url) else {
            let alert = NSAlert()
            alert.messageText = "そのフォルダには書き込めません"
            alert.informativeText = "書き込み可能な別のフォルダを選んでください。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        settings.soundsFolderPath = url.path
        applySoundsFolderChange()
    }

    @objc private func resetSoundsFolder() {
        settings.soundsFolderPath = ""
        applySoundsFolderChange()
    }

    /// 保存先を切り替えたら、登録済みのMP3も新しい保存先へ集約する。
    private func applySoundsFolderChange() {
        settings.consolidateSoundsIntoFolder()
        reloadSoundPopup()
        reloadEarthquakeSoundPopup()
        updateSoundLoopCheckbox()
        updateSoundsFolderLabel()
    }

    @objc private func importMP3() {
        let panel = NSOpenPanel()
        panel.title = "通知音に使うMP3を選択"
        panel.prompt = "追加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mp3")!]
        guard panel.runModal() == .OK else { return }

        do {
            let imported = try importSoundFiles(panel.urls)
            settings.customSoundPaths.append(contentsOf: imported)
            if let first = imported.first { settings.soundSelection = "file:\(first)" }
            reloadSoundPopup()
            reloadEarthquakeSoundPopup()
            onTestSound?()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "MP3を追加できませんでした"
            alert.runModal()
        }
    }

    @objc private func testSound() { onTestSound?() }

    @objc private func showFeeds() { onShowFeeds?() }

    @objc private func showTest() { onTest?() }

    private func updateOpacityLabel() {
        opacityValue.stringValue = "\(Int(settings.backgroundOpacity * 100))%"
    }

    private func updateSpeedLabel() {
        speedValue.stringValue = "\(Int(settings.speed)) px/s"
    }

    private func updateFontLabel() {
        fontValue.stringValue = "\(Int(settings.fontSize)) pt"
    }
}

private extension FileManager {
    /// 選んだフォルダが実在し、かつ書き込めるか。
    func isWritableFileDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return isWritableFile(atPath: url.path)
    }
}

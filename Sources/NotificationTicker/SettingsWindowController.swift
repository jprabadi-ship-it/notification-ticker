import AppKit
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    private let settings: TickerSettings
    private let monitor: NotificationMonitor
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let opacityValue = NSTextField(labelWithString: "")
    private let speedValue = NSTextField(labelWithString: "")
    private let fontValue = NSTextField(labelWithString: "")
    private let earthquakeStatusLabel = NSTextField(labelWithString: "")
    private let edgePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quietHoursCheckbox = NSButton()
    private let quietStartPicker = NSDatePicker()
    private let quietEndPicker = NSDatePicker()
    private let quietStatusLabel = NSTextField(labelWithString: "")
    private var screenObserver: NSObjectProtocol?
    private var quietStatusTimer: Timer?
    var onTest: (() -> Void)?
    var onTestSound: (() -> Void)?
    var onShowFeeds: (() -> Void)?

    init(settings: TickerSettings, monitor: NotificationMonitor) {
        self.settings = settings
        self.monitor = monitor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 775),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "通知ティッカー設定"
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

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "画面端の通知ティッカー")
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

        fontPopup.addItem(withTitle: "エヴァ風・極太明朝")
        fontPopup.lastItem?.representedObject = TickerSettings.evaMinchoFontFamily
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
        quietHoursCheckbox.title = "睡眠時間帯は通知・ニュース・地震速報・音声を停止"
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
            checkboxWithTitle: "震度4以上の地震を津波情報付きで表示",
            target: self,
            action: #selector(earthquakeEnabledChanged(_:))
        )
        earthquakeEnabled.state = settings.earthquakeAlertsEnabled ? .on : .off
        earthquakeStatusLabel.stringValue = settings.earthquakeAlertsEnabled ? "震度4以上を監視中" : "地震速報は停止中"
        earthquakeStatusLabel.textColor = .secondaryLabelColor
        earthquakeStatusLabel.alignment = .right
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

        let soundTestButton = NSButton(title: "音を試す", target: self, action: #selector(testSound))
        soundTestButton.bezelStyle = .rounded
        let soundLabel = NSTextField(labelWithString: "通知音")
        soundLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let soundRow = NSStackView(views: [soundLabel, soundPopup, soundTestButton])
        soundRow.orientation = .horizontal
        soundRow.alignment = .centerY
        soundRow.distribution = .fill
        soundRow.spacing = 10
        soundPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let importSoundButton = NSButton(title: "MP3を追加…", target: self, action: #selector(importMP3))
        importSoundButton.bezelStyle = .rounded

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
            opacity, speed, fontFamilyRow, font, clickThrough, ignoreClockWeatherWidgets,
            separator(), quietHoursCheckbox, quietTimeRow, earthquakeRow,
            soundEnabled, soundRow, importSoundButton, bottomRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            opacity.widthAnchor.constraint(equalTo: stack.widthAnchor),
            speed.widthAnchor.constraint(equalTo: stack.widthAnchor),
            font.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fontFamilyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quietTimeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            earthquakeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            edgeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            displayRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            soundRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            soundTestButton.trailingAnchor.constraint(equalTo: soundRow.trailingAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            testButton.trailingAnchor.constraint(equalTo: bottomRow.trailingAnchor)
        ])
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
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = support
            .appendingPathComponent("NotificationTicker", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
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
        onTestSound?()
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

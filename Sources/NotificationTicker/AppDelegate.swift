import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = TickerSettings()
    private lazy var monitor = NotificationMonitor(settings: settings)
    private var tickerController: TickerPanelController!
    private var settingsController: SettingsWindowController!
    private var feedSettingsController: FeedSettingsWindowController!
    private var feedMonitor: FeedMonitor!
    private var earthquakeMonitor: JMAEarthquakeMonitor!
    private var eewMonitor: EEWMonitor!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var activeSound: NSSound?
    private var activeSoundSelection: String?
    /// 先頭メッセージに割り当てられた音。nil なら共通の通知音を使う。
    private var leadingSoundSelection: String?
    /// 先頭メッセージによるループの上書き。nil なら音源ごとの設定に従う。
    private var leadingSoundLoops: Bool?
    private var soundFadeTimer: Timer?
    private var quietHoursTimer: Timer?
    private var isQuietHoursActive = false
    /// 緊急地震速報を出している間だけ、睡眠時間帯の停止を上書きする期限。
    private var emergencyOverrideUntil: Date?
    private var isEmergencyOverrideActive: Bool {
        guard let until = emergencyOverrideUntil else { return false }
        return until > Date()
    }
    /// 発信元をまたいで、同じ本文の24時間以内の再表示を防ぐ。
    private let deduplicator = MessageDeduplicator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保存先の外にある登録済みMP3を、保存先へ集約してから各画面を組み立てる。
        settings.consolidateSoundsIntoFolder()
        tickerController = TickerPanelController(settings: settings)
        tickerController.onTickerWillHide = { [weak self] in self?.fadeOutNotificationSound() }
        tickerController.onTickerDidShow = { [weak self] in
            guard let self, self.settings.soundEnabled else { return }
            self.playNotificationSound(looping: true)
        }
        // 先頭メッセージが変わったら、そのフィードに割り当てた音へ切り替える。
        tickerController.tickerView.onLeadingSoundChange = { [weak self] selection, loops in
            guard let self else { return }
            self.leadingSoundSelection = selection
            self.leadingSoundLoops = loops
            guard self.settings.soundEnabled, self.tickerController.panel.isVisible else { return }
            self.playNotificationSound(looping: true)
        }
        settingsController = SettingsWindowController(settings: settings, monitor: monitor)
        feedMonitor = FeedMonitor(settings: settings)
        earthquakeMonitor = JMAEarthquakeMonitor(settings: settings)
        eewMonitor = EEWMonitor(settings: settings)
        feedSettingsController = FeedSettingsWindowController(settings: settings)
        settingsController.onTest = { [weak self] in self?.showTestMessage() }
        settingsController.onTestSound = { [weak self] in
            guard let self else { return }
            self.playNotificationSound(looping: false, overriding: self.settings.soundSelection)
        }
        settingsController.onShowFeeds = { [weak self] in self?.showFeedSettings() }
        settingsController.onPreviewSound = { [weak self] selection in
            self?.playNotificationSound(looping: false, overriding: selection)
        }
        feedSettingsController.onRefresh = { [weak self] in self?.feedMonitor.refreshNow() }
        feedSettingsController.onPreviewSound = { [weak self] selection in
            guard let self else { return }
            self.playNotificationSound(
                looping: false,
                overriding: selection ?? self.settings.soundSelection
            )
        }
        feedSettingsController.onRefreshURL = { [weak self] urlString in
            self?.feedMonitor.refreshNow(urlString: urlString)
        }

        settings.onChange = { [weak self] in
            self?.applySettingsAndRuntimeState()
        }

        monitor.onNotification = { [weak self] notification in
            guard let self, !self.isQuietHoursActive else { return }
            guard self.deduplicator.shouldEmit(notification.tickerText) else { return }
            // Claude Code の状態（Bash実行待ち・許可待ち・入力待ち・応答完了）ごとに音を変えられる。
            // 通知の読み取りでアプリ名やタイトルが欠けることがあるため、AIツール判定には
            // 頼らず、本文の目印だけで状態を見分ける。目印は Clauminella 固有の文言なので
            // 他アプリと衝突しない。
            let status = ClaudeCodeStatus.detect(in: notification.tickerText)
            let statusSound = status.flatMap { self.settings.soundSelection(forClaudeStatus: $0) }
            let isAITool = status != nil || TickerTextStyler.isAIToolNotification(
                appName: notification.appName,
                title: notification.title
            )
            // 状態の知らせは1回鳴れば足りるので、ループさせない。
            self.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: notification.tickerText),
                badge: TickerTextStyler.notificationBadge,
                badgeColor: isAITool ? TickerTextStyler.aiBadgeColor : nil,
                soundSelection: statusSound,
                soundLoops: statusSound != nil ? false : nil
            )
        }
        monitor.onStatusChange = { [weak self] status in
            guard let self else { return }
            let effectiveStatus: NotificationMonitor.Status = self.isQuietHoursActive ? .pausedForQuietHours : status
            self.statusMenuItem.title = effectiveStatus.label
            self.settingsController.updateStatus(effectiveStatus)
        }
        feedMonitor.onHeadline = { [weak self] headline, urlString in
            guard let self else { return }
            guard !self.isQuietHoursActive else { return }
            guard self.deduplicator.shouldEmit(headline) else { return }
            self.tickerController.enqueue(
                headline,
                soundSelection: self.settings.soundSelection(forFeedURL: urlString)
            )
        }
        feedMonitor.onStatusChange = { [weak self] status in
            self?.feedSettingsController.updateStatus(status)
        }
        earthquakeMonitor.onReport = { [weak self] report in
            guard let self else { return }
            guard !self.isQuietHoursActive else { return }
            let text = self.settings.effectiveLocalAreaName
                .map { report.tickerText(localArea: $0) } ?? report.tickerText
            guard self.deduplicator.shouldEmit(text) else { return }
            self.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: text),
                badge: TickerTextStyler.earthquakeBadge(forIntensity: report.maxIntensity),
                soundSelection: self.settings.effectiveEarthquakeSoundSelection
            )
        }
        earthquakeMonitor.onStatusChange = { [weak self] status in
            self?.settingsController.updateEarthquakeStatus(status)
        }
        eewMonitor.onReport = { [weak self] report in
            guard let self else { return }
            let localArea = self.settings.effectiveLocalAreaName
            guard report.meetsThreshold(
                minimumIntensity: self.settings.eewMinimumIntensity,
                localArea: localArea
            ) else { return }
            guard let text = report.tickerText(localArea: localArea) else { return }
            // 揺れが来る前の知らせなので、睡眠時間帯でも表示して鳴らす。
            self.emergencyOverrideUntil = Date().addingTimeInterval(60)
            // 続報ごとに内容が変わるため、共通の重複判定は通さない。
            self.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: text),
                badge: TickerTextStyler.earthquakeEvacuationBadge,
                soundSelection: self.settings.effectiveEarthquakeSoundSelection,
                overridingSuppression: true
            )
        }
        eewMonitor.onStatusChange = { [weak self] status in
            self?.settingsController.updateEEWStatus(status)
        }
        eewMonitor.configure()

        installEditMenu()
        configureStatusItem()
        startQuietHoursTimer()
        updateQuietHoursState(force: true)
        previewNHKAfterFeedBehaviorUpgradeIfNeeded()
        if !monitor.isTrusted {
            settingsController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            monitor.requestPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        feedMonitor.stop()
        earthquakeMonitor.stop()
        eewMonitor.stop()
        quietHoursTimer?.invalidate()
    }

    /// LSUIElement（accessory）アプリはメインメニューを持たないため、⌘V などの
    /// 編集系キーが responder chain に届かず、テキスト欄に貼り付けできない。
    /// メニューバーには表示されないが、キー等価物の解決にはメインメニューが必要。
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("取り消す", Selector(("undo:")), "z", .command),
            ("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            ("カット", #selector(NSText.cut(_:)), "x", .command),
            ("コピー", #selector(NSText.copy(_:)), "c", .command),
            ("ペースト", #selector(NSText.paste(_:)), "v", .command),
            ("すべてを選択", #selector(NSText.selectAll(_:)), "a", .command)
        ]
        for (title, action, key, modifiers) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            editMenu.addItem(item)
        }
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.line.first.and.arrowtriangle.forward", accessibilityDescription: "Notification Ticker")
        }

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "監視を開始しています…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(title: "ティッカーを停止", action: #selector(toggleTicker), keyEquivalent: "p")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let test = NSMenuItem(title: "テスト表示", action: #selector(showTestMessage), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)

        let settingsItem = NSMenuItem(title: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        updateToggleMenuItem()
    }

    @objc private func toggleTicker() {
        settings.isEnabled.toggle()
    }

    @objc private func showTestMessage() {
        guard !isQuietHoursActive else { return }
        tickerController.enqueue(
            TickerTextLayout.insertingTime(
                Date(),
                into: "メッセージ  •  Notification Ticker のテスト表示です  •  背景透明度と速度は設定画面で変更できます"
            ),
            badge: TickerTextStyler.notificationBadge
        )
    }

    @objc private func showSettings() {
        settingsController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `overriding` を渡すと、先頭メッセージの割り当てを無視して指定の音を鳴らす（試聴用）。
    private func playNotificationSound(looping: Bool, overriding: String? = nil) {
        guard !isQuietHoursActive || isEmergencyOverrideActive else { return }
        soundFadeTimer?.invalidate()
        soundFadeTimer = nil
        let selection = overriding ?? leadingSoundSelection ?? settings.soundSelection
        if activeSoundSelection != selection {
            activeSound?.stop()
            if selection.hasPrefix("file:") {
                let path = String(selection.dropFirst("file:".count))
                activeSound = NSSound(contentsOfFile: path, byReference: true)
            } else {
                let name = String(selection.dropFirst("system:".count))
                activeSound = NSSound(named: NSSound.Name(name))
            }
            activeSoundSelection = selection
        }
        // ループは、先頭メッセージに上書きがあればそれを、無ければ音源ごとの設定に従う。
        // 試聴（overriding 指定）のときは上書きを無視する。
        let itemLoops = overriding == nil ? leadingSoundLoops : nil
        let shouldLoop = looping && (itemLoops ?? settings.loopsSound(selection))
        if let activeSound {
            activeSound.volume = 1
            if shouldLoop && activeSound.isPlaying && activeSound.loops {
                return
            }
            activeSound.stop()
            activeSound.loops = shouldLoop
            activeSound.play()
        } else {
            NSSound.beep()
        }
    }

    private func fadeOutNotificationSound(duration: TimeInterval = 0.45) {
        guard let activeSound, activeSound.isPlaying else { return }
        soundFadeTimer?.invalidate()

        let startedAt = ProcessInfo.processInfo.systemUptime
        let startingVolume = activeSound.volume
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak activeSound] timer in
            guard let self, let activeSound else {
                timer.invalidate()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let progress = min(1, elapsed / duration)
            activeSound.volume = Float(Double(startingVolume) * (1 - progress))

            if progress >= 1 {
                timer.invalidate()
                activeSound.stop()
                activeSound.loops = false
                activeSound.volume = 1
                self.soundFadeTimer = nil
            }
        }
        soundFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showFeedSettings() {
        feedSettingsController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func previewNHKAfterFeedBehaviorUpgradeIfNeeded() {
        let migrationKey = "didPreviewNHKAfterAddBehaviorUpgradeV1"
        let defaults = UserDefaults.standard
        guard !isQuietHoursActive,
              settings.feedURLs.contains(FeedSettingsWindowController.nhkNewsURL),
              !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.feedMonitor.refreshNow(urlString: FeedSettingsWindowController.nhkNewsURL)
        }
    }

    private func updateToggleMenuItem() {
        toggleMenuItem?.title = settings.isEnabled ? "ティッカーを停止" : "ティッカーを再開"
    }

    private func startQuietHoursTimer() {
        quietHoursTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateQuietHoursState(force: false)
        }
        quietHoursTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applySettingsAndRuntimeState() {
        tickerController.applySettings()
        if !settings.soundEnabled {
            fadeOutNotificationSound()
        }
        updateToggleMenuItem()
        if !isQuietHoursActive { eewMonitor.configure() }
        updateQuietHoursState(force: true)
    }

    private func updateQuietHoursState(force: Bool) {
        let shouldPause = settings.isQuietHoursActive
        guard force || shouldPause != isQuietHoursActive else { return }
        isQuietHoursActive = shouldPause

        tickerLog.notice("quiet hours: \(shouldPause ? "enter" : "exit", privacy: .public)")
        if shouldPause {
            tickerController.setSuppressed(true)
            fadeOutNotificationSound()
            monitor.pauseForQuietHours()
            feedMonitor.pauseForQuietHours()
            earthquakeMonitor.pauseForQuietHours()
            // 緊急地震速報だけは止めない。揺れる前に知らせるためのもの。
            eewMonitor.configure()
            statusMenuItem.title = NotificationMonitor.Status.pausedForQuietHours.label
            settingsController.updateStatus(.pausedForQuietHours)
        } else {
            tickerController.setSuppressed(false)
            statusMenuItem.title = "監視を再開しています…"
            monitor.start()
            feedMonitor.configure()
            earthquakeMonitor.configure()
            eewMonitor.configure()
            previewNHKAfterFeedBehaviorUpgradeIfNeeded()
        }
    }
}

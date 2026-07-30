import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = TickerSettings()
    private lazy var monitor = NotificationMonitor(settings: settings)
    private var tickerController: TickerPanelController!
    private var settingsController: SettingsWindowController!
    private var feedSettingsController: FeedSettingsWindowController!
    private var feedMonitor: FeedMonitor!
    private var earthquakeMonitor: JMAEarthquakeMonitor!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var activeSound: NSSound?
    private var activeSoundSelection: String?
    private var soundFadeTimer: Timer?
    private var quietHoursTimer: Timer?
    private var isQuietHoursActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        tickerController = TickerPanelController(settings: settings)
        tickerController.onTickerWillHide = { [weak self] in self?.fadeOutNotificationSound() }
        tickerController.onTickerDidShow = { [weak self] in
            guard let self, self.settings.soundEnabled else { return }
            self.playNotificationSound(looping: true)
        }
        settingsController = SettingsWindowController(settings: settings, monitor: monitor)
        feedMonitor = FeedMonitor(settings: settings)
        earthquakeMonitor = JMAEarthquakeMonitor(settings: settings)
        feedSettingsController = FeedSettingsWindowController(settings: settings)
        settingsController.onTest = { [weak self] in self?.showTestMessage() }
        settingsController.onTestSound = { [weak self] in self?.playNotificationSound(looping: false) }
        settingsController.onShowFeeds = { [weak self] in self?.showFeedSettings() }
        feedSettingsController.onRefresh = { [weak self] in self?.feedMonitor.refreshNow() }
        feedSettingsController.onRefreshURL = { [weak self] urlString in
            self?.feedMonitor.refreshNow(urlString: urlString)
        }

        settings.onChange = { [weak self] in
            self?.applySettingsAndRuntimeState()
        }

        monitor.onNotification = { [weak self] notification in
            guard self?.isQuietHoursActive == false else { return }
            self?.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: notification.tickerText),
                badge: TickerTextStyler.announcementBadge
            )
        }
        monitor.onStatusChange = { [weak self] status in
            guard let self else { return }
            let effectiveStatus: NotificationMonitor.Status = self.isQuietHoursActive ? .pausedForQuietHours : status
            self.statusMenuItem.title = effectiveStatus.label
            self.settingsController.updateStatus(effectiveStatus)
        }
        feedMonitor.onHeadline = { [weak self] headline in
            guard let self else { return }
            guard !self.isQuietHoursActive else { return }
            self.tickerController.enqueue(headline)
        }
        feedMonitor.onStatusChange = { [weak self] status in
            self?.feedSettingsController.updateStatus(status)
        }
        earthquakeMonitor.onReport = { [weak self] report in
            guard let self else { return }
            guard !self.isQuietHoursActive else { return }
            self.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: report.tickerText),
                badge: TickerTextStyler.announcementBadge
            )
        }
        earthquakeMonitor.onStatusChange = { [weak self] status in
            self?.settingsController.updateEarthquakeStatus(status)
        }

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
        quietHoursTimer?.invalidate()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.line.first.and.arrowtriangle.forward", accessibilityDescription: "通知ティッカー")
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
                into: "メッセージ  •  通知ティッカーのテスト表示です  •  背景透明度と速度は設定画面で変更できます"
            ),
            badge: TickerTextStyler.announcementBadge
        )
    }

    @objc private func showSettings() {
        settingsController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func playNotificationSound(looping: Bool) {
        guard !isQuietHoursActive else { return }
        soundFadeTimer?.invalidate()
        soundFadeTimer = nil
        if activeSoundSelection != settings.soundSelection {
            activeSound?.stop()
            if settings.soundSelection.hasPrefix("file:") {
                let path = String(settings.soundSelection.dropFirst("file:".count))
                activeSound = NSSound(contentsOfFile: path, byReference: true)
            } else {
                let name = String(settings.soundSelection.dropFirst("system:".count))
                activeSound = NSSound(named: NSSound.Name(name))
            }
            activeSoundSelection = settings.soundSelection
        }
        if let activeSound {
            activeSound.volume = 1
            if looping && activeSound.isPlaying && activeSound.loops {
                return
            }
            activeSound.stop()
            activeSound.loops = looping
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
        updateQuietHoursState(force: true)
    }

    private func updateQuietHoursState(force: Bool) {
        let shouldPause = settings.isQuietHoursActive
        guard force || shouldPause != isQuietHoursActive else { return }
        isQuietHoursActive = shouldPause

        if shouldPause {
            tickerController.setSuppressed(true)
            fadeOutNotificationSound()
            monitor.pauseForQuietHours()
            feedMonitor.pauseForQuietHours()
            earthquakeMonitor.pauseForQuietHours()
            statusMenuItem.title = NotificationMonitor.Status.pausedForQuietHours.label
            settingsController.updateStatus(.pausedForQuietHours)
        } else {
            tickerController.setSuppressed(false)
            statusMenuItem.title = "監視を再開しています…"
            monitor.start()
            feedMonitor.configure()
            earthquakeMonitor.configure()
            previewNHKAfterFeedBehaviorUpgradeIfNeeded()
        }
    }
}

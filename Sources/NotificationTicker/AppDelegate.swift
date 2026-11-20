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
    /// 流したメッセージの記録。/tmp に置き、Mac の再起動で消える。
    private let history = DisplayHistory()
    private lazy var historyController = HistoryWindowController(history: history)
    private var activeSound: NotificationSoundPlaying?
    private var activeSoundSelection: String?
    /// いまの再生部品を、すき間なしループ用として作ったか。
    private var activeSoundWantsGapless = false
    /// 先頭メッセージに割り当てられた音。nil なら共通の通知音を使う。
    private var leadingSoundSelection: String?
    /// 先頭メッセージによるループの上書き。nil なら音源ごとの設定に従う。
    private var leadingSoundLoops: Bool?
    private var soundFadeTimer: Timer?
    private var quietHoursTimer: Timer?
    private var isQuietHoursActive = false
    /// 地震の知らせ（緊急地震速報・地震情報）を出している間だけ、睡眠時間帯の停止を上書きする期限。
    private var emergencyOverrideUntil: Date?
    private var isEmergencyOverrideActive: Bool {
        guard let until = emergencyOverrideUntil else { return false }
        return until > Date()
    }
    /// 先頭の項目が地震の知らせか。消音設定を越えて鳴らす。
    private var leadingSoundIsUrgent = false
    /// 地震の音を鳴らす間だけ、Mac 本体の消音・小さすぎる音量を解く。
    private let emergencyAudio = EmergencyAudioOverride(output: CoreAudioOutput())
    /// 地震の音の最低音量。アプリの音量を絞っていても、これより小さくはしない。
    static let urgentMinimumSoundVolume = 0.8
    /// 発信元をまたいで、同じ本文の24時間以内の再表示を防ぐ。
    private let deduplicator = MessageDeduplicator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保存先の外にある登録済みMP3を、保存先へ集約してから各画面を組み立てる。
        settings.consolidateSoundsIntoFolder()
        tickerController = TickerPanelController(settings: settings)
        tickerController.onTickerWillHide = { [weak self] in self?.fadeOutNotificationSound() }
        tickerController.onTickerDidShow = { [weak self] in
            guard let self, self.shouldPlayLeadingSound else { return }
            self.playNotificationSound(looping: true)
        }
        // 次のメッセージの表示が始まったら、そのフィードに割り当てた音へ切り替える。
        tickerController.tickerView.onLeadingSoundChange = { [weak self] selection, loops, urgent in
            guard let self else { return }
            self.leadingSoundSelection = selection
            self.leadingSoundLoops = loops
            self.leadingSoundIsUrgent = urgent
            guard self.tickerController.panel.isVisible else { return }
            if self.shouldPlayLeadingSound {
                self.playNotificationSound(looping: true)
            } else {
                // 消音中に地震の音が鳴っていたら、次の項目に替わった時点で止める。
                self.fadeOutNotificationSound()
            }
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
            self?.present(
                notificationText: notification.tickerText,
                appName: notification.appName,
                title: notification.title
            )
        }
        monitor.onStatusChange = { [weak self] status in
            guard let self else { return }
            let effectiveStatus: NotificationMonitor.Status = self.isQuietHoursActive ? .pausedForQuietHours : status
            self.statusMenuItem.title = effectiveStatus.label
            self.settingsController.updateStatus(effectiveStatus)
        }
        tickerController.onEnqueue = { [weak self] text, badge, link in
            self?.history.record(text: text, badge: badge, link: link)
        }

        feedMonitor.onHeadline = { [weak self] headline, urlString, link in
            guard let self else { return }
            guard !self.isQuietHoursActive else { return }
            guard self.deduplicator.shouldEmit(headline, allowsRecurring: false) else { return }
            self.tickerController.enqueue(
                headline,
                soundSelection: self.settings.soundSelection(forFeedURL: urlString),
                link: link
            )
        }
        feedMonitor.onStatusChange = { [weak self] status in
            self?.feedSettingsController.updateStatus(status)
        }
        earthquakeMonitor.onReport = { [weak self] report in
            guard let self else { return }
            let text = self.settings.effectiveLocalAreaName
                .map { report.tickerText(localArea: $0) } ?? report.tickerText
            guard self.deduplicator.shouldEmit(text, allowsRecurring: false) else { return }
            // 地震情報も、睡眠時間帯にかかわらず表示して鳴らす。
            self.beginEmergencyOverride()
            self.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: text),
                badge: TickerTextStyler.earthquakeBadge(forIntensity: report.maxIntensity),
                soundSelection: self.settings.effectiveEarthquakeSoundSelection,
                urgentSound: true,
                overridingSuppression: true
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
            self.beginEmergencyOverride()
            // 続報ごとに内容が変わるため、共通の重複判定は通さない。
            self.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: text),
                badge: TickerTextStyler.earthquakeEvacuationBadge,
                soundSelection: self.settings.effectiveEarthquakeSoundSelection,
                urgentSound: true,
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
        presentPendingTestMessageIfAny()
        presentPendingEarthquakeTestIfAny()
        previewNHKAfterFeedBehaviorUpgradeIfNeeded()
        if !monitor.isTrusted {
            settingsController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            monitor.requestPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 地震の音のために解いた Mac 本体の消音を、終了時にも戻しておく。
        emergencyAudio.end()
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

        let longTest = NSMenuItem(title: "テスト表示（長文・要約）", action: #selector(showLongTestMessage), keyEquivalent: "l")
        longTest.target = self
        menu.addItem(longTest)

        let earthquakeTest = NSMenuItem(
            title: "テスト表示（地震の音）",
            action: #selector(showEarthquakeTestMessage),
            keyEquivalent: "e"
        )
        earthquakeTest.target = self
        menu.addItem(earthquakeTest)

        let historyItem = NSMenuItem(title: "表示履歴…", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

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

    /// 通知の本文をティッカーへ流す共通経路。実通知とテスト表示の両方が通る。
    /// 状態判定と重複判定は全文で行い、表示だけを要約または切り詰める。
    private func present(
        notificationText fullText: String,
        appName: String?,
        title: String?,
        deduplicate: Bool = true
    ) {
        guard !isQuietHoursActive else { return }
        if deduplicate, !deduplicator.shouldEmit(fullText) { return }
        // Claude Code の状態（Bash実行待ち・許可待ち・入力待ち・応答完了）ごとに音を変えられる。
        // 通知の読み取りでアプリ名やタイトルが欠けることがあるため、AIツール判定には
        // 頼らず、本文の目印だけで状態を見分ける。目印は Clauminella 固有の文言なので
        // 他アプリと衝突しない。
        let status = ClaudeCodeStatus.detect(in: fullText)
        let statusSound = status.flatMap { settings.soundSelection(forClaudeStatus: $0) }
        let isAITool = status != nil || TickerTextStyler.isAIToolNotification(appName: appName, title: title)
        // 状態の知らせは1回鳴れば足りるので、ループさせない。
        let enqueue: (String) -> Void = { [weak self] text in
            self?.tickerController.enqueue(
                TickerTextLayout.insertingTime(Date(), into: text),
                badge: TickerTextStyler.notificationBadge,
                badgeColor: isAITool ? TickerTextStyler.aiBadgeColor : nil,
                soundSelection: statusSound,
                soundLoops: statusSound != nil ? false : nil
            )
        }
        // 長文は要約を試みる（Apple Intelligence またはローカル LLM。端末内処理）。
        // 使えない・失敗・時間切れなら従来どおり切り詰める。
        let backend = NotificationSummarizer.backend(localModel: settings.effectiveLocalSummarizerModel)
        if fullText.count > TickerTextLayout.longTextThreshold, let backend {
            Task { @MainActor in
                if let summary = await NotificationSummarizer.summarize(fullText, using: backend) {
                    enqueue("〔要約〕" + summary)
                } else {
                    enqueue(TickerTextLayout.condensed(fullText))
                }
            }
        } else {
            enqueue(TickerTextLayout.condensed(fullText))
        }
    }

    /// 長文の要約経路を確かめるための架空ニュース（約200字）。実在の出来事ではない。
    static let longTestMessage = """
    架空ニュース  •  練馬区は本日、区内すべての小中学校で給食のメニューを児童が投票で選ぶ新制度を来年4月から始めると発表した。\
    月に一度、候補3案から選ぶ形式で、初回の候補にはカレーライス、鶏の唐揚げ、焼きそばが挙がっている。\
    区教育委員会は「食への関心を高めたい」としており、投票結果は各校の掲示板と区の公式サイトで毎月公表される。\
    保護者向けの説明会は今月20日に区役所で開かれる。
    """

    /// 地震の知らせと同じ扱い（消音や睡眠時間帯を越えて鳴らす）で、テスト文を流す。
    @objc private func showEarthquakeTestMessage() {
        beginEmergencyOverride()
        tickerController.enqueue(
            TickerTextLayout.insertingTime(
                Date(),
                into: "テスト  •  地震の知らせの音の確認です。実際の地震ではありません"
            ),
            badge: TickerTextStyler.earthquakeBadge(forIntensity: "3"),
            soundSelection: settings.effectiveEarthquakeSoundSelection,
            urgentSound: true,
            overridingSuppression: true
        )
    }

    /// 地震の知らせを出す前に呼ぶ。しばらくの間、睡眠時間帯でも音を鳴らせるようにする。
    private func beginEmergencyOverride() {
        emergencyOverrideUntil = Date().addingTimeInterval(60)
    }

    @objc private func showLongTestMessage() {
        present(notificationText: Self.longTestMessage, appName: "テスト", title: "架空ニュース", deduplicate: false)
    }

    /// 起動時に一度だけ、地震の音のテストを流す。読んだら消す。
    private func presentPendingEarthquakeTestIfAny() {
        let key = "pendingEarthquakeTest"
        guard UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.showEarthquakeTestMessage()
        }
    }

    /// 起動時に一度だけ読む、外部から流し込むテスト文面。読んだら消す。
    /// 同じユーザーの defaults 書き込み権限が要るので、設定画面と同じ信頼範囲。
    private func presentPendingTestMessageIfAny() {
        let key = "pendingTestMessage"
        guard let text = UserDefaults.standard.string(forKey: key),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.present(notificationText: text, appName: "テスト", title: nil, deduplicate: false)
        }
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

    @objc private func showHistory() {
        historyController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 先頭の項目の音を鳴らすか。地震の知らせは「音を鳴らす」がオフでも鳴らす。
    private var shouldPlayLeadingSound: Bool {
        settings.soundEnabled || leadingSoundIsUrgent
    }

    /// いま鳴らす音の音量。地震の知らせは、アプリの音量を絞っていても最低限の大きさで鳴らす。
    private func soundVolume(urgent: Bool) -> Float {
        let volume = settings.soundVolume
        return Float(urgent ? max(volume, Self.urgentMinimumSoundVolume) : volume)
    }

    /// `overriding` を渡すと、先頭メッセージの割り当てを無視して指定の音を鳴らす（試聴用）。
    private func playNotificationSound(looping: Bool, overriding: String? = nil) {
        guard !isQuietHoursActive || isEmergencyOverrideActive else { return }
        // 試聴は利用者の操作なので、消音を越える扱いにしない。
        let urgent = overriding == nil && leadingSoundIsUrgent
        if urgent { emergencyAudio.begin() } else { emergencyAudio.end() }
        soundFadeTimer?.invalidate()
        soundFadeTimer = nil
        let selection = overriding ?? leadingSoundSelection ?? settings.soundSelection
        // ループは、先頭メッセージに上書きがあればそれを、無ければ音源ごとの設定に従う。
        // 試聴（overriding 指定）のときは上書きを無視する。
        let itemLoops = overriding == nil ? leadingSoundLoops : nil
        let shouldLoop = looping && (itemLoops ?? settings.loopsSound(selection))
        // 取り込んだ音声ファイルをループするときは、継ぎ目に空白が出ないよう専用の部品で鳴らす。
        let wantsGapless = shouldLoop && selection.hasPrefix("file:")
        if activeSoundSelection != selection || activeSoundWantsGapless != wantsGapless {
            activeSound?.stop()
            activeSound = makeSound(for: selection, gapless: wantsGapless)
            activeSoundSelection = selection
            activeSoundWantsGapless = wantsGapless
        }
        if let activeSound {
            activeSound.volume = soundVolume(urgent: urgent)
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

    private func makeSound(for selection: String, gapless: Bool) -> NotificationSoundPlaying? {
        if selection.hasPrefix("file:") {
            let path = String(selection.dropFirst("file:".count))
            if gapless, let player = GaplessLoopPlayer(url: URL(fileURLWithPath: path)) {
                return player
            }
            return NSSound(contentsOfFile: path, byReference: true)
        }
        let name = String(selection.dropFirst("system:".count))
        return NSSound(named: NSSound.Name(name))
    }

    private func fadeOutNotificationSound(duration: TimeInterval = 0.45) {
        guard let activeSound, activeSound.isPlaying else {
            emergencyAudio.end()
            return
        }
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
                activeSound.volume = Float(self.settings.soundVolume)
                self.soundFadeTimer = nil
                self.emergencyAudio.end()
                // すき間なしループ用の部品は曲全体を展開して持つ（70秒で約27MB）。
                // 鳴らし終えたら手放し、次に鳴らすときに読み直す。
                if activeSound is GaplessLoopPlayer {
                    self.activeSound = nil
                    self.activeSoundSelection = nil
                }
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
        // 再生中の音にも音量変更を即時反映する（フェード中は触らない）。
        if soundFadeTimer == nil {
            activeSound?.volume = soundVolume(urgent: leadingSoundIsUrgent)
        }
        if !shouldPlayLeadingSound {
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
            // 地震の知らせ（地震情報・緊急地震速報）は止めない。寝ている間にも知らせる。
            earthquakeMonitor.configure()
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

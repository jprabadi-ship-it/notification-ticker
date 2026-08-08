import AppKit

final class FeedSettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let nhkNewsURL = "https://www3.nhk.or.jp/rss/news/cat0.xml"

    private let settings: TickerSettings
    private let tableView = NSTableView()
    private let urlField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let enabledCheckbox = NSButton(checkboxWithTitle: "ニュースフィードを表示する", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onRefresh: (() -> Void)?
    var onRefreshURL: ((String) -> Void)?
    /// 効果音を選び直したときの試聴。nil は共通の通知音。
    var onPreviewSound: ((String?) -> Void)?

    init(settings: TickerSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 470),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ニュース／RSSフィード"
        window.minSize = NSSize(width: 700, height: 360)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    func updateStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    func numberOfRows(in tableView: NSTableView) -> Int { settings.feedURLs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let urlString = settings.feedURLs[row]
        if tableColumn?.identifier.rawValue == "sound" {
            return makeSoundPopup(forFeedAt: row, urlString: urlString)
        }
        if tableColumn?.identifier.rawValue == "loop" {
            return makeLoopCheckbox(forFeedAt: row, urlString: urlString)
        }
        // 途中を省略するとドメインが読めなくなるため、末尾側を省略する。
        let field = NSTextField(labelWithString: urlString)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = urlString
        return field
    }

    /// フィード1件ぶんの効果音ポップアップ。先頭は共通の通知音を使う選択肢。
    private func makeSoundPopup(forFeedAt row: Int, urlString: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "共通の通知音")
        popup.lastItem?.representedObject = ""

        for name in Self.availableSystemSoundNames() {
            popup.addItem(withTitle: name)
            popup.lastItem?.representedObject = "system:\(name)"
        }
        let customPaths = settings.customSoundPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !customPaths.isEmpty {
            popup.menu?.addItem(.separator())
            for path in customPaths {
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                popup.addItem(withTitle: "MP3: \(name)")
                popup.lastItem?.representedObject = "file:\(path)"
            }
        }

        let selection = settings.soundSelection(forFeedURL: urlString) ?? ""
        if let selected = popup.itemArray.first(where: { ($0.representedObject as? String) == selection }) {
            popup.select(selected)
        } else {
            popup.selectItem(at: 0)
        }
        popup.tag = row
        popup.target = self
        popup.action = #selector(soundChanged(_:))
        return popup
    }

    /// 通知音の選択肢は設定画面と同じ一覧（システムサウンド＋登録したMP3）。
    private static func availableSystemSoundNames() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/System/Library/Sounds"),
            includingPropertiesForKeys: nil
        )) ?? []
        var names = Set(urls
            .filter { ["aiff", "wav", "caf"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent })
        names.insert("Glass")
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// ループ設定は音源ごとの共有設定。同じ音を使う他のフィードにも反映される。
    private func makeLoopCheckbox(forFeedAt row: Int, urlString: String) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(loopChanged(_:)))
        let selection = settings.soundSelection(forFeedURL: urlString) ?? settings.soundSelection
        checkbox.state = settings.loopsSound(selection) ? .on : .off
        checkbox.toolTip = "この音源をループ再生します。同じ音を使う他のフィードにも同じ設定が適用されます。"
        checkbox.tag = row
        return checkbox
    }

    @objc private func loopChanged(_ sender: NSButton) {
        guard settings.feedURLs.indices.contains(sender.tag) else { return }
        let urlString = settings.feedURLs[sender.tag]
        let selection = settings.soundSelection(forFeedURL: urlString) ?? settings.soundSelection
        settings.setLoops(sender.state == .on, forSound: selection)
        tableView.reloadData()
    }

    @objc private func soundChanged(_ sender: NSPopUpButton) {
        guard settings.feedURLs.indices.contains(sender.tag),
              let selection = sender.selectedItem?.representedObject as? String else { return }
        let urlString = settings.feedURLs[sender.tag]
        if selection.isEmpty {
            settings.feedSoundSelections.removeValue(forKey: urlString)
        } else {
            settings.feedSoundSelections[urlString] = selection
        }
        tableView.reloadData()
        onPreviewSound?(selection.isEmpty ? nil : selection)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        enabledCheckbox.state = settings.feedsEnabled ? .on : .off

        let intervalLabel = NSTextField(labelWithString: "更新間隔")
        for minutes in [5, 10, 15, 30] {
            intervalPopup.addItem(withTitle: "\(minutes)分")
            intervalPopup.lastItem?.representedObject = NSNumber(value: minutes)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged(_:))
        let selectedInterval = intervalPopup.itemArray.firstIndex {
            ($0.representedObject as? NSNumber)?.doubleValue == settings.feedIntervalMinutes
        } ?? 0
        intervalPopup.selectItem(at: selectedInterval)

        let topRow = NSStackView(views: [enabledCheckbox, intervalLabel, intervalPopup])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        enabledCheckbox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // URLが読めることを優先し、幅の変動はURL列だけが受け持つ。
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        column.title = "登録済みフィードURL"
        column.resizingMask = .autoresizingMask
        column.minWidth = 380
        column.width = 620
        tableView.addTableColumn(column)

        let soundColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sound"))
        soundColumn.title = "効果音"
        soundColumn.resizingMask = .userResizingMask
        soundColumn.width = 170
        soundColumn.minWidth = 150
        soundColumn.maxWidth = 220
        tableView.addTableColumn(soundColumn)

        let loopColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("loop"))
        loopColumn.title = "ループ"
        loopColumn.resizingMask = []
        loopColumn.width = 60
        loopColumn.minWidth = 60
        loopColumn.maxWidth = 60
        tableView.addTableColumn(loopColumn)
        // 2列になったので、どちらの列か分かるようヘッダを出す。
        tableView.rowHeight = 26
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        urlField.placeholderString = "https://example.com/feed.xml"
        urlField.target = self
        urlField.action = #selector(addURL)
        let addButton = NSButton(title: "追加", target: self, action: #selector(addURL))
        let inputRow = NSStackView(views: [urlField, addButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let nhkButton = NSButton(title: "NHKニュースを追加", target: self, action: #selector(addNHK))
        let removeButton = NSButton(title: "選択項目を削除", target: self, action: #selector(removeSelected))
        let refreshButton = NSButton(title: "最新見出しを表示", target: self, action: #selector(refreshNow))
        let actionRow = NSStackView(views: [nhkButton, removeButton, refreshButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = settings.feedURLs.isEmpty ? "フィードURLを追加してください" : "登録済み: \(settings.feedURLs.count)件"

        let note = NSTextField(wrappingLabelWithString: "RSS 2.0とAtomに対応しています。自動更新では初回の既存記事を表示せず、その後の新着だけを表示します。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [topRow, scrollView, inputRow, actionRow, statusLabel, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        settings.feedsEnabled = sender.state == .on
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? NSNumber else { return }
        settings.feedIntervalMinutes = value.doubleValue
    }

    @objc private func addURL() {
        add(urlField.stringValue, displayLatest: true)
        urlField.stringValue = ""
    }

    @objc private func addNHK() {
        add(Self.nhkNewsURL, displayLatest: true)
    }

    private func add(_ rawValue: String, displayLatest: Bool) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            statusLabel.stringValue = "httpまたはhttpsのフィードURLを入力してください"
            return
        }
        guard !settings.feedURLs.contains(value) else {
            if displayLatest {
                statusLabel.stringValue = "登録済みフィードの最新見出しを取得しています…"
                onRefreshURL?(value)
            } else {
                statusLabel.stringValue = "このURLは登録済みです"
            }
            return
        }
        settings.feedURLs.append(value)
        tableView.reloadData()
        if displayLatest {
            statusLabel.stringValue = "追加しました。最新見出しを取得しています…"
            onRefreshURL?(value)
        } else {
            statusLabel.stringValue = "追加しました: \(value)"
        }
    }

    @objc private func removeSelected() {
        let indexes = tableView.selectedRowIndexes
        guard !indexes.isEmpty else {
            statusLabel.stringValue = "削除するURLを選択してください"
            return
        }
        for index in indexes {
            settings.feedSoundSelections.removeValue(forKey: settings.feedURLs[index])
        }
        settings.feedURLs.remove(atOffsets: indexes)
        tableView.reloadData()
        statusLabel.stringValue = "選択したフィードを削除しました"
    }

    @objc private func refreshNow() {
        statusLabel.stringValue = "フィードを取得しています…"
        onRefresh?()
    }
}

private extension Array {
    mutating func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where indices.contains(index) {
            remove(at: index)
        }
    }
}

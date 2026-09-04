import AppKit

/// ティッカーに流したメッセージの一覧。流れて消えたあとに読み返すための窓。
/// 行をダブルクリックすると、リンクのある見出し（フィードの記事）はページを開く。
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let history: DisplayHistory
    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(history: DisplayHistory) {
        self.history = history
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "表示履歴"
        window.minSize = NSSize(width: 520, height: 260)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        history.onChange = { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { history.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < history.entries.count else { return nil }
        let entry = history.entries[row]
        let field: NSTextField
        switch tableColumn?.identifier.rawValue {
        case "time":
            field = NSTextField(labelWithString: Self.timeFormatter.string(from: entry.date))
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case "kind":
            field = NSTextField(labelWithString: entry.kind)
        default:
            field = NSTextField(labelWithString: entry.text)
            field.lineBreakMode = .byTruncatingTail
            // リンクのある行は下線で示し、ツールチップで開き先を出す。
            if let link = entry.link {
                field.attributedStringValue = NSAttributedString(
                    string: entry.text,
                    attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
                )
                field.toolTip = link.absoluteString
            } else {
                field.toolTip = entry.text
            }
        }
        return field
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < history.entries.count,
              let link = history.entries[row].link else { return }
        NSWorkspace.shared.open(link)
    }

    @objc private func clearHistory() {
        history.clear()
    }

    private func reload() {
        tableView.reloadData()
        countLabel.stringValue = history.entries.isEmpty
            ? "まだ何も流れていません"
            : "\(history.entries.count)件（新しい順。上限 \(history.limit) 件）"
    }

    // MARK: - Layout

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.title = "時刻"
        timeColumn.resizingMask = []
        timeColumn.width = 72
        timeColumn.minWidth = 72
        timeColumn.maxWidth = 72
        tableView.addTableColumn(timeColumn)

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "種別"
        kindColumn.resizingMask = []
        kindColumn.width = 52
        kindColumn.minWidth = 52
        kindColumn.maxWidth = 52
        tableView.addTableColumn(kindColumn)

        // 内容が読めることを優先し、幅の変動は内容列だけが受け持つ。
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "内容"
        textColumn.resizingMask = .autoresizingMask
        textColumn.minWidth = 300
        textColumn.width = 600
        tableView.addTableColumn(textColumn)

        tableView.rowHeight = 24
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        let clearButton = NSButton(title: "履歴を消去", target: self, action: #selector(clearHistory))
        let bottomRow = NSStackView(views: [countLabel, clearButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let note = NSTextField(
            wrappingLabelWithString: "下線のある行をダブルクリックすると記事ページを開きます。履歴はこのアプリを終了すると消えます（内容を保存しません）。"
        )
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [scrollView, bottomRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reload()
    }
}

import Foundation

struct FeedItem: Equatable {
    let title: String
    let identifier: String
    var publishedAt: Date?
}

enum FeedDateParser {
    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) { return date }
        return rfc822.date(from: trimmed)
    }

    static func displayTime(for date: Date) -> String {
        displayFormatter.string(from: date)
    }
}

struct ParsedFeed: Equatable {
    let title: String
    let items: [FeedItem]
}

final class FeedXMLParser: NSObject, XMLParserDelegate {
    private var feedTitle = "フィード"
    private var items: [FeedItem] = []
    private var insideItem = false
    private var elementName = ""
    private var buffer = ""
    private var itemTitle = ""
    private var itemLink = ""
    private var itemIdentifier = ""
    private var itemPublishedAt: Date?

    static func parse(data: Data) -> ParsedFeed? {
        let delegate = FeedXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.items.isEmpty else { return nil }
        return ParsedFeed(title: delegate.feedTitle, items: delegate.items)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalized(elementName)
        self.elementName = name
        buffer = ""

        if name == "item" || name == "entry" {
            insideItem = true
            itemTitle = ""
            itemLink = ""
            itemIdentifier = ""
            itemPublishedAt = nil
        } else if insideItem, name == "link", let href = attributeDict["href"] {
            itemLink = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    // CDATA（ギズモード等）は foundCharacters では届かないので明示的に拾う。
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        buffer += text
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalized(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "title" {
            if insideItem { itemTitle += text } else if !text.isEmpty { feedTitle = text }
        } else if insideItem, name == "link", itemLink.isEmpty {
            itemLink = text
        } else if insideItem && (name == "guid" || name == "id") {
            itemIdentifier = text
        } else if insideItem, ["pubdate", "published", "updated", "date"].contains(name) {
            if itemPublishedAt == nil { itemPublishedAt = FeedDateParser.date(from: text) }
        } else if name == "item" || name == "entry" {
            let title = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let identifier = !itemIdentifier.isEmpty ? itemIdentifier : (!itemLink.isEmpty ? itemLink : title)
                items.append(FeedItem(title: title, identifier: identifier, publishedAt: itemPublishedAt))
            }
            insideItem = false
        }

        self.elementName = ""
        buffer = ""
    }

    private func normalized(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }
}

final class FeedMonitor {
    /// 見出しと、その取得元のフィードURL。
    var onHeadline: ((String, String) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private let settings: TickerSettings
    private let queue = DispatchQueue(label: "jp.local.NotificationTicker.feeds", qos: .utility)
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private var seenIdentifiers = Set<String>()
    private var primedURLs = Set<String>()
    private var isPausedForQuietHours = false

    init(settings: TickerSettings) {
        self.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func configure() {
        let enabled = settings.feedsEnabled
        let urls = settings.feedURLs
        let interval = max(1, settings.feedIntervalMinutes) * 60

        queue.async { [weak self] in
            guard let self else { return }
            self.isPausedForQuietHours = false
            self.timer?.cancel()
            self.timer = nil
            guard enabled, !urls.isEmpty else {
                self.publishStatus(enabled ? "フィードURLを追加してください" : "フィードは停止中")
                return
            }

            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now(), repeating: interval, leeway: .seconds(5))
            source.setEventHandler { [weak self] in self?.fetch(urlStrings: urls, showLatest: false) }
            self.timer = source
            source.resume()
            self.publishStatus("\(urls.count)件のフィードを監視中")
        }
    }

    func refreshNow(showLatest: Bool = true) {
        let urls = settings.feedURLs
        guard !urls.isEmpty else {
            publishStatus("フィードURLを追加してください")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isPausedForQuietHours else {
                self.publishStatus("睡眠時間帯のためフィード停止中")
                return
            }
            self.fetch(urlStrings: urls, showLatest: showLatest)
        }
    }

    func refreshNow(urlString: String, showLatest: Bool = true) {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            publishStatus("無効なURL: \(urlString)")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isPausedForQuietHours else {
                self.publishStatus("睡眠時間帯のためフィード停止中")
                return
            }
            self.fetch(urlStrings: [urlString], showLatest: showLatest)
        }
    }

    func pauseForQuietHours() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isPausedForQuietHours = true
            self.timer?.cancel()
            self.timer = nil
            self.publishStatus("睡眠時間帯のためフィード停止中")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.session.invalidateAndCancel()
        }
    }

    private func fetch(urlStrings: [String], showLatest: Bool) {
        for urlString in urlStrings {
            guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                publishStatus("無効なURL: \(urlString)")
                continue
            }

            session.dataTask(with: url) { [weak self] data, _, error in
                guard let self else { return }
                self.queue.async {
                    guard !self.isPausedForQuietHours else { return }
                    if let error {
                        self.publishStatus("取得失敗: \(error.localizedDescription)")
                        return
                    }
                    guard let data, let feed = FeedXMLParser.parse(data: data) else {
                        self.publishStatus("RSS/Atomを解析できませんでした")
                        return
                    }
                    self.consume(feed: feed, urlString: urlString, showLatest: showLatest)
                }
            }.resume()
        }
    }

    private func consume(feed: ParsedFeed, urlString: String, showLatest: Bool) {
        if showLatest {
            for item in feed.items.prefix(5).reversed() {
                seenIdentifiers.insert(item.identifier)
                publishHeadline(Self.headline(feedTitle: feed.title, item: item), urlString: urlString)
            }
        } else if !primedURLs.contains(urlString) {
            feed.items.forEach { seenIdentifiers.insert($0.identifier) }
            primedURLs.insert(urlString)
        } else {
            let newItems = feed.items.filter { !seenIdentifiers.contains($0.identifier) }
            for item in newItems.prefix(10).reversed() {
                seenIdentifiers.insert(item.identifier)
                publishHeadline(Self.headline(feedTitle: feed.title, item: item), urlString: urlString)
            }
        }
        publishStatus("最終取得: \(feed.title)（\(feed.items.count)件）")
    }

    /// 「発行時刻 • 見出し」の1行を組み立てる。フィード名は表示しない。
    static func headline(feedTitle: String, item: FeedItem) -> String {
        let parts = [
            item.publishedAt.map(FeedDateParser.displayTime),
            item.title
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: "  •  ")
    }

    private func publishHeadline(_ headline: String, urlString: String) {
        DispatchQueue.main.async { [weak self] in self?.onHeadline?(headline, urlString) }
    }

    private func publishStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(status) }
    }
}

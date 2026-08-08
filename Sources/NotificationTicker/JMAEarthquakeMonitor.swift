import AppKit
import Foundation

struct JMAFeedEntry: Equatable {
    let id: String
    let link: String
    let title: String
    let updated: Date?
}

final class JMAFeedParser: NSObject, XMLParserDelegate {
    private var entries: [JMAFeedEntry] = []
    private var inEntry = false
    private var buffer = ""
    private var entryID = ""
    private var entryLink = ""
    private var entryTitle = ""
    private var entryUpdated: Date?

    static func parse(data: Data) -> [JMAFeedEntry]? {
        let delegate = JMAFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalized(elementName)
        buffer = ""
        if name == "entry" {
            inEntry = true
            entryID = ""
            entryLink = ""
            entryTitle = ""
            entryUpdated = nil
        } else if inEntry, name == "link", let href = attributeDict["href"] {
            entryLink = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalized(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if inEntry, name == "id" { entryID = text }
        if inEntry, name == "title" { entryTitle = text }
        if inEntry, name == "updated" { entryUpdated = ISO8601DateFormatter().date(from: text) }
        if name == "entry" {
            if !entryID.isEmpty, !entryLink.isEmpty {
                entries.append(JMAFeedEntry(
                    id: entryID,
                    link: entryLink,
                    title: entryTitle,
                    updated: entryUpdated
                ))
            }
            inEntry = false
        }
        buffer = ""
    }

    private func normalized(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }
}

struct JMAEarthquakeReport: Equatable {
    let eventID: String
    let hypocenter: String
    let magnitude: String
    let maxIntensity: String
    let tsunamiStatus: String

    var tickerText: String {
        "【地震】最大震度\(maxIntensity)  •  震源 \(hypocenter)  •  M\(magnitude)  •  津波\(tsunamiStatus)"
    }

    /// 設定された下限震度に達しているか。
    func meetsAlertThreshold(minimumIntensity: String) -> Bool {
        Self.intensityRank(maxIntensity) >= Self.intensityRank(minimumIntensity)
    }

    /// 設定画面に並べる震度の選択肢。表示名と保存値を兼ねる。
    static let selectableIntensities = ["1", "2", "3", "4", "5弱", "5強", "6弱", "6強", "7"]

    static func intensityRank(_ intensity: String) -> Int {
        switch intensity.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return 1
        case "2": return 2
        case "3": return 3
        case "4": return 4
        case "5-", "5弱": return 5
        case "5+", "5強": return 6
        case "6-", "6弱": return 7
        case "6+", "6強": return 8
        case "7": return 9
        default: return 0
        }
    }
}

final class JMAEarthquakeXMLParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var buffer = ""
    private var eventID = ""
    private var hypocenter = "不明"
    private var magnitude = "不明"
    private var maxIntensity = "0"
    private var forecastComment = ""

    static func parse(data: Data) -> JMAEarthquakeReport? {
        let delegate = JMAEarthquakeXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), JMAEarthquakeReport.intensityRank(delegate.maxIntensity) > 0 else { return nil }
        return JMAEarthquakeReport(
            eventID: delegate.eventID,
            hypocenter: delegate.hypocenter,
            magnitude: delegate.magnitude,
            maxIntensity: delegate.displayIntensity(delegate.maxIntensity),
            tsunamiStatus: delegate.tsunamiStatus(delegate.forecastComment)
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(normalized(elementName))
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalized(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "eventid", !text.isEmpty { eventID = text }
        if name == "name", stack.contains("hypocenter"), !text.isEmpty { hypocenter = text }
        if name == "magnitude", !text.isEmpty { magnitude = text }
        if name == "maxint", JMAEarthquakeReport.intensityRank(text) > JMAEarthquakeReport.intensityRank(maxIntensity) {
            maxIntensity = text
        }
        if name == "text", stack.contains("forecastcomment"), !text.isEmpty { forecastComment += text }

        if !stack.isEmpty { stack.removeLast() }
        buffer = ""
    }

    private func tsunamiStatus(_ comment: String) -> String {
        if comment.contains("津波の心配はありません") { return "なし" }
        if comment.contains("海面変動") && comment.contains("被害の心配はありません") { return "なし（海面変動の可能性）" }
        if comment.contains("津波警報") || comment.contains("津波注意報") || comment.contains("津波が発生") { return "あり" }
        return "確認中"
    }

    private func displayIntensity(_ value: String) -> String {
        switch value {
        case "5-": return "5弱"
        case "5+": return "5強"
        case "6-": return "6弱"
        case "6+": return "6強"
        default: return value
        }
    }

    private func normalized(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }
}

final class JMAEarthquakeMonitor {
    var onReport: ((JMAEarthquakeReport) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private let feedURL = URL(string: "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml")!
    private let settings: TickerSettings
    private let queue = DispatchQueue(label: "jp.local.NotificationTicker.earthquake", qos: .utility)
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private var seenEntryIDs: [String]
    private let seenKey = "jmaSeenEarthquakeEntryIDs"
    private let startedAt = Date()
    private var etag: String?
    private var lastModified: String?
    private var consecutiveFailures = 0
    private var isRequestInFlight = false
    private var monitoringEnabled = false
    private var wakeObserver: NSObjectProtocol?

    init(settings: TickerSettings) {
        self.settings = settings
        seenEntryIDs = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: configuration)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.queue.async {
                guard let self, self.monitoringEnabled else { return }
                self.timer?.cancel()
                self.timer = nil
                self.scheduleNext(after: 0)
            }
        }
    }

    func configure() {
        let enabled = settings.earthquakeAlertsEnabled
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.monitoringEnabled = enabled
            guard enabled else {
                self.publishStatus("地震速報は停止中")
                return
            }
            self.consecutiveFailures = 0
            self.scheduleNext(after: 0)
            self.publishStatus("震度4以上を監視中（60秒間隔）")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.monitoringEnabled = false
            self?.timer?.cancel()
            self?.timer = nil
            self?.session.invalidateAndCancel()
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func pauseForQuietHours() {
        queue.async { [weak self] in
            guard let self else { return }
            self.monitoringEnabled = false
            self.timer?.cancel()
            self.timer = nil
            self.publishStatus("睡眠時間帯のため地震速報停止中")
        }
    }

    private func scheduleNext(after delay: TimeInterval) {
        guard monitoringEnabled else { return }
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, leeway: .seconds(3))
        source.setEventHandler { [weak self] in
            self?.timer = nil
            self?.fetchFeed()
        }
        timer = source
        source.resume()
    }

    private func fetchFeed() {
        guard monitoringEnabled, !isRequestInFlight else { return }
        isRequestInFlight = true

        var request = URLRequest(url: feedURL)
        request.cachePolicy = .useProtocolCachePolicy
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.isRequestInFlight = false
                guard self.monitoringEnabled else { return }
                if let error {
                    self.handleFailure("地震情報取得失敗: \(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.handleFailure("気象庁から無効な応答を受信しました")
                    return
                }
                if let value = httpResponse.value(forHTTPHeaderField: "ETag") { self.etag = value }
                if let value = httpResponse.value(forHTTPHeaderField: "Last-Modified") { self.lastModified = value }

                if httpResponse.statusCode == 304 {
                    self.handleSuccess(status: "気象庁フィード変更なし")
                    return
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    self.handleFailure("気象庁HTTPエラー: \(httpResponse.statusCode)")
                    return
                }
                guard let data, let entries = JMAFeedParser.parse(data: data) else {
                    self.handleFailure("気象庁フィードを解析できませんでした")
                    return
                }
                self.process(entries: entries)
                self.handleSuccess(status: "気象庁フィード確認済み")
            }
        }.resume()
    }

    private func handleSuccess(status: String) {
        consecutiveFailures = 0
        publishStatus(status)
        scheduleNext(after: 60 + Double.random(in: 0...5))
    }

    private func handleFailure(_ status: String) {
        consecutiveFailures += 1
        let delays: [TimeInterval] = [60, 120, 300, 600]
        let index = min(consecutiveFailures - 1, delays.count - 1)
        let delay = delays[index] + Double.random(in: 0...5)
        publishStatus("\(status)（\(Int(delay))秒後に再試行）")
        scheduleNext(after: delay)
    }

    private func process(entries: [JMAFeedEntry]) {
        let candidates = entries.filter {
            $0.title == "震源・震度に関する情報" && !seenEntryIDs.contains($0.id)
        }
        for entry in candidates {
            remember(entry.id)
            // On a fresh installation, only replay reports issued within the last five minutes.
            if let updated = entry.updated, updated < startedAt.addingTimeInterval(-300) { continue }
            guard let url = URL(string: entry.link) else { continue }
            fetchReport(url: url)
        }
    }

    private func fetchReport(url: URL) {
        session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            self.queue.async {
                guard self.monitoringEnabled else { return }
                guard error == nil, let data, let report = JMAEarthquakeXMLParser.parse(data: data) else { return }
                guard report.meetsAlertThreshold(minimumIntensity: self.settings.earthquakeMinimumIntensity) else { return }
                DispatchQueue.main.async { [weak self] in self?.onReport?(report) }
            }
        }.resume()
    }

    private func remember(_ id: String) {
        seenEntryIDs.removeAll { $0 == id }
        seenEntryIDs.insert(id, at: 0)
        if seenEntryIDs.count > 100 { seenEntryIDs.removeLast(seenEntryIDs.count - 100) }
        UserDefaults.standard.set(seenEntryIDs, forKey: seenKey)
    }

    private func publishStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(status) }
    }
}

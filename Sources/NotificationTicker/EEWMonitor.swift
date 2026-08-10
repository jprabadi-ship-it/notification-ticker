import Foundation

/// 緊急地震速報（P2PQuake の code 556）。揺れが来る前に出すため、
/// 定期取得ではなく WebSocket で押し出されたものを受け取る。
struct EEWReport: Equatable {
    struct Area: Equatable {
        let name: String
        let pref: String
        /// 予測震度（10=1, 20=2, … 45=5弱, 70=7）。不明は -1。
        let scale: Int
        /// S波の到達予測時刻。分からなければ nil。
        let arrivalTime: Date?
    }

    let eventID: String
    /// 同じ地震に対する報数。第1報ほど精度が低い。
    let serial: String
    let cancelled: Bool
    let hypocenter: String
    let magnitude: String
    let areas: [Area]

    /// 予測震度の表示名。気象庁の震度階級に合わせる。
    static func intensityText(forScale scale: Int) -> String? {
        switch scale {
        case 10: return "1"
        case 20: return "2"
        case 30: return "3"
        case 40: return "4"
        case 45: return "5弱"
        case 50: return "5強"
        case 55: return "6弱"
        case 60: return "6強"
        case 70: return "7"
        default: return nil
        }
    }

    /// 自分の地点に一番近い予測。市区町村や都道府県の名前を含む地域を探す。
    /// 見つからなければ、発表された中で最も大きい予測を返す。
    func prediction(matching area: String?) -> Area? {
        let key = (area ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let words = key.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
            for word in words.reversed() where !word.isEmpty {
                // 「東京都」と予報区の「東京」を突き合わせるため、末尾の都道府県名は落として比べる。
                let bare = word.replacingOccurrences(
                    of: "(都|道|府|県)$",
                    with: "",
                    options: .regularExpression
                )
                if let hit = areas.first(where: { $0.name.contains(bare) || $0.pref.contains(bare) }) {
                    return hit
                }
            }
        }
        return areas.max { $0.scale < $1.scale }
    }

    /// ティッカーへ流す1行。到達までの秒数は受信時点から数える。
    func tickerText(localArea: String?, now: Date = Date()) -> String? {
        if cancelled {
            return "【緊急地震速報】取り消し  •  先ほどの緊急地震速報は取り消されました"
        }
        guard let target = prediction(matching: localArea),
              let intensity = Self.intensityText(forScale: target.scale) else { return nil }

        var parts = ["【緊急地震速報】予測震度\(intensity)", target.name]
        if let arrival = target.arrivalTime {
            let seconds = Int(arrival.timeIntervalSince(now).rounded())
            parts.append(seconds > 0 ? "あと約\(seconds)秒" : "まもなく到達")
        }
        parts.append("震源 \(hypocenter)")
        parts.append("M\(magnitude)")
        parts.append("第\(serial)報・予測値")
        return parts.joined(separator: "  •  ")
    }

    /// 予測震度が下限に達しているか。取り消し報は常に通す。
    func meetsThreshold(minimumIntensity: String, localArea: String?) -> Bool {
        if cancelled { return true }
        guard let target = prediction(matching: localArea),
              let intensity = Self.intensityText(forScale: target.scale) else { return false }
        return JMAEarthquakeReport.intensityRank(intensity)
            >= JMAEarthquakeReport.intensityRank(minimumIntensity)
    }

    private static let timeParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    static func parse(data: Data) -> EEWReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? Int) == 556 else { return nil }

        let issue = root["issue"] as? [String: Any] ?? [:]
        let quake = root["earthquake"] as? [String: Any] ?? [:]
        let hypo = quake["hypocenter"] as? [String: Any] ?? [:]
        let rawAreas = root["areas"] as? [[String: Any]] ?? []

        let areas = rawAreas.map { item in
            Area(
                name: item["name"] as? String ?? "",
                pref: item["pref"] as? String ?? "",
                scale: item["scaleTo"] as? Int ?? item["scaleFrom"] as? Int ?? -1,
                arrivalTime: (item["arrivalTime"] as? String).flatMap { timeParser.date(from: $0) }
            )
        }

        let magnitude = (hypo["magnitude"] as? NSNumber).map { number -> String in
            let value = number.doubleValue
            return value < 0 ? "不明" : String(format: "%.1f", value)
        } ?? "不明"

        return EEWReport(
            eventID: issue["eventId"] as? String ?? (root["id"] as? String ?? ""),
            serial: issue["serial"] as? String ?? "1",
            cancelled: root["cancelled"] as? Bool ?? false,
            hypocenter: hypo["name"] as? String ?? "不明",
            magnitude: magnitude,
            areas: areas
        )
    }
}

/// P2PQuake の WebSocket に繋ぎ、緊急地震速報を受け取り続ける。
final class EEWMonitor {
    var onReport: ((EEWReport) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private let settings: TickerSettings
    private let endpoint = URL(string: "wss://api.p2pquake.net/v2/ws")!
    private let queue = DispatchQueue(label: "jp.local.NotificationTicker.eew")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private var isRunning = false
    /// 再接続の待ち時間。切れるたびに伸ばし、繋がったら戻す。
    private var retryDelay: TimeInterval = 2
    /// 同じ報を二重に流さないための記録（イベントID＋報数）。
    private var seenSerials = Set<String>()

    init(settings: TickerSettings) {
        self.settings = settings
    }

    func configure() {
        settings.eewEnabled ? start() : stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.teardown()
            self.publishStatus("緊急地震速報は停止中")
        }
    }

    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func connect() {
        teardown()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: endpoint)
        self.session = session
        self.task = task
        task.resume()
        publishStatus("緊急地震速報を受信待ち")
        receive()
        schedulePing()
    }

    /// 一定時間ごとに ping を送り、無通信で切られるのを防ぐ。
    private func schedulePing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.task?.sendPing { error in
                guard error != nil else { return }
                self?.scheduleReconnect()
            }
        }
        pingTimer = timer
        timer.resume()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect()
                case .success(let message):
                    self.retryDelay = 2
                    self.handle(message)
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let value): data = value
        case .string(let text): data = text.data(using: .utf8)
        @unknown default: data = nil
        }
        guard let data, let report = EEWReport.parse(data: data) else { return }

        // 同じ報を取りこぼしなく1回だけ流す。続報は震度が変わるので別扱いにする。
        let key = "\(report.eventID)-\(report.serial)-\(report.cancelled)"
        guard !seenSerials.contains(key) else { return }
        seenSerials.insert(key)
        if seenSerials.count > 200 { seenSerials.removeAll() }

        DispatchQueue.main.async { [weak self] in self?.onReport?(report) }
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        teardown()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        publishStatus("緊急地震速報に再接続します（\(Int(delay))秒後）")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning else { return }
            self.connect()
        }
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(text) }
    }
}

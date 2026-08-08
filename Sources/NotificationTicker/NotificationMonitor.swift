import AppKit
import ApplicationServices
import Foundation

struct CapturedNotification: Equatable {
    let appName: String?
    let title: String?
    let body: String

    /// アプリ名は表示せず、通知タイトルと本文だけを並べる。
    var tickerText: String {
        [title, body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "  •  ")
    }
}

enum NotificationTextParser {
    private static let ignoredControlTexts: Set<String> = [
        "Notification Center", "通知センター", "Close", "閉じる",
        "Clear", "消去", "Options", "オプション", "Show", "表示"
    ]

    private static let weatherTexts: Set<String> = [
        "晴れ", "曇り", "雨", "雪", "霧", "快晴",
        "Sunny", "Cloudy", "Rain", "Snow", "Fog", "Clear"
    ]

    private static let glancePatterns = [
        #"^(?:午前|午後)?\s*\d{1,2}[:：]\d{2}(?:[:：]\d{2})?(?:\s*(?:AM|PM|am|pm))?$"#,
        #"^(?:月|火|水|木|金|土|日)曜日$"#,
        #"^(?:月|火|水|木|金|土|日)曜日\s+-?\d{1,3}(?:\.\d+)?\s*(?:°\s*[CF]?|℃|℉)(?:\s+.*)?$"#,
        #"^\d{1,2}月\d{1,2}日(?:\s*[（(]?(?:月|火|水|木|金|土|日)曜日?[）)]?)?$"#,
        #"^(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)$"#,
        #"^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)$"#,
        #"^(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+-?\d{1,3}(?:\.\d+)?\s*(?:°\s*[CF]?|℃|℉)(?:\s+.*)?$"#,
        #"^-?\d{1,3}(?:\.\d+)?\s*(?:°\s*[CF]?|℃|℉)(?:\s+.*)?$"#
    ]

    private static let combinedGlancePatterns = [
        #"^(?:午前|午後)?\s*\d{1,2}[:：]\d{2}(?:[:：]\d{2})?\s+(?:月|火|水|木|金|土|日)曜日\s+-?\d{1,3}(?:\.\d+)?\s*(?:°\s*[CF]?|℃|℉)(?:\s+.*)?$"#,
        #"^\d{1,2}[:：]\d{2}(?:[:：]\d{2})?(?:\s*(?:AM|PM|am|pm))?\s+(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+-?\d{1,3}(?:\.\d+)?\s*(?:°\s*[CF]?|℃|℉)(?:\s+.*)?$"#
    ]

    private static let temperaturePattern = #"-?\d{1,3}(?:\.\d+)?\s*(?:°\s*[CF]?|℃|℉)"#

    static func parse(
        _ rawTexts: [String],
        ignoringClockWeatherWidgets: Bool = true
    ) -> CapturedNotification? {
        let normalizedTexts = rawTexts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if ignoringClockWeatherWidgets,
           (normalizedTexts.contains(where: isCombinedGlanceText)
            || containsTemperature(in: normalizedTexts)) {
            return nil
        }

        var seen = Set<String>()
        let texts = normalizedTexts
            .filter { !shouldIgnore($0, ignoringClockWeatherWidgets: ignoringClockWeatherWidgets) }
            .filter { seen.insert($0).inserted }

        guard !texts.isEmpty else { return nil }

        if texts.count == 1 {
            return CapturedNotification(appName: nil, title: nil, body: texts[0])
        }
        if texts.count == 2 {
            return CapturedNotification(appName: texts[0], title: nil, body: texts[1])
        }

        return CapturedNotification(
            appName: texts[0],
            title: texts[1],
            body: texts.dropFirst(2).joined(separator: "  ")
        )
    }

    private static func shouldIgnore(
        _ text: String,
        ignoringClockWeatherWidgets: Bool
    ) -> Bool {
        if ignoredControlTexts.contains(text) { return true }
        guard ignoringClockWeatherWidgets else { return false }
        if weatherTexts.contains(text) { return true }
        return glancePatterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func isCombinedGlanceText(_ text: String) -> Bool {
        combinedGlancePatterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func containsTemperature(in texts: [String]) -> Bool {
        texts.joined(separator: " ").range(
            of: temperaturePattern,
            options: .regularExpression
        ) != nil
    }
}

enum NotificationWidgetClassifier {
    static func isClockWeatherWidget(
        windowTitle: String?,
        elementMarkers: [String]
    ) -> Bool {
        ([windowTitle].compactMap { $0 } + elementMarkers).contains { marker in
            let normalized = marker.lowercased()
            return normalized.contains("widgy") || normalized.contains("com.woodsign.widgy")
        }
    }
}

final class NotificationMonitor {
    enum Status: Equatable {
        case permissionRequired
        case waitingForNotificationCenter
        case monitoring
        case pausedForQuietHours

        var label: String {
            switch self {
            case .permissionRequired: return "アクセシビリティ許可が必要です"
            case .waitingForNotificationCenter: return "通知センターの起動を待っています"
            case .monitoring: return "通知を監視中"
            case .pausedForQuietHours: return "睡眠時間帯のため停止中"
            }
        }
    }

    var onNotification: ((CapturedNotification) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private let settings: TickerSettings
    private let queue = DispatchQueue(label: "jp.local.NotificationTicker.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var activeFingerprints = Set<String>()
    private var didPrimeInitialState = false
    private var lastStatus: Status?

    var isTrusted: Bool { AXIsProcessTrusted() }

    init(settings: TickerSettings) {
        self.settings = settings
    }

    func requestPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        publishStatus(.permissionRequired)
    }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(650), leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func pauseForQuietHours() {
        stop()
        queue.async { [weak self] in
            guard let self else { return }
            self.activeFingerprints.removeAll()
            self.didPrimeInitialState = false
            self.publishStatus(.pausedForQuietHours)
        }
    }

    private func poll() {
        guard AXIsProcessTrusted() else {
            publishStatus(.permissionRequired)
            return
        }

        guard let app = notificationCenterApplication() else {
            publishStatus(.waitingForNotificationCenter)
            return
        }

        publishStatus(.monitoring)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = elements(for: kAXWindowsAttribute as String, in: root)
        var current = Set<String>()
        var captured: [(String, CapturedNotification)] = []

        for window in windows {
            if settings.ignoresClockWeatherWidgets,
               NotificationWidgetClassifier.isClockWeatherWidget(
                   windowTitle: string(for: kAXTitleAttribute as String, in: window),
                   elementMarkers: collectWidgetMarkers(from: window, depth: 0)
               ) {
                continue
            }
            let texts = collectTexts(from: window, depth: 0)
            guard let notification = NotificationTextParser.parse(
                texts,
                ignoringClockWeatherWidgets: settings.ignoresClockWeatherWidgets
            ) else { continue }
            let fingerprint = notification.tickerText
            guard fingerprint.count >= 2 else { continue }
            current.insert(fingerprint)
            captured.append((fingerprint, notification))
        }

        if !didPrimeInitialState {
            activeFingerprints = current
            didPrimeInitialState = true
            return
        }

        // 同一本文の再表示防止は AppDelegate 側の MessageDeduplicator が一括で担う。
        for (fingerprint, notification) in captured where !activeFingerprints.contains(fingerprint) {
            DispatchQueue.main.async { [weak self] in
                self?.onNotification?(notification)
            }
        }
        activeFingerprints = current
    }

    private func notificationCenterApplication() -> NSRunningApplication? {
        let knownBundleIdentifiers = [
            "com.apple.notificationcenterui",
            "com.apple.NotificationCenter"
        ]

        let applications = NSWorkspace.shared.runningApplications
        if let exact = applications.first(where: { app in
            guard let identifier = app.bundleIdentifier else { return false }
            return knownBundleIdentifiers.contains(identifier)
        }) {
            return exact
        }

        return applications.first { app in
            let identifier = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return identifier.contains("notificationcenter") || name == "notification center"
        }
    }

    private func elements(for attribute: String, in element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }

    private func string(for attribute: String, in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func collectTexts(from element: AXUIElement, depth: Int) -> [String] {
        guard depth <= 12 else { return [] }

        let role = string(for: kAXRoleAttribute as String, in: element)
        var result: [String] = []
        let textRoles = [kAXStaticTextRole as String, kAXButtonRole as String]

        if let role, textRoles.contains(role) {
            for attribute in [kAXTitleAttribute as String, kAXValueAttribute as String, kAXDescriptionAttribute as String] {
                if let text = string(for: attribute, in: element), !text.isEmpty {
                    result.append(text)
                }
            }
        }

        let children = elements(for: kAXChildrenAttribute as String, in: element)
        for child in children {
            result.append(contentsOf: collectTexts(from: child, depth: depth + 1))
        }
        return result
    }

    private func collectWidgetMarkers(from element: AXUIElement, depth: Int) -> [String] {
        guard depth <= 12 else { return [] }

        var result: [String] = []
        for attribute in [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXIdentifierAttribute as String
        ] {
            if let marker = string(for: attribute, in: element), !marker.isEmpty {
                result.append(marker)
            }
        }

        for child in elements(for: kAXChildrenAttribute as String, in: element) {
            result.append(contentsOf: collectWidgetMarkers(from: child, depth: depth + 1))
        }
        return result
    }

    private func publishStatus(_ status: Status) {
        guard status != lastStatus else { return }
        lastStatus = status
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }
}

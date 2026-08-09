import Foundation

enum TickerEdge: String, CaseIterable {
    case top
    case bottom
    case left
    case right

    var label: String {
        switch self {
        case .top: return "上"
        case .bottom: return "下"
        case .left: return "左"
        case .right: return "右"
        }
    }

    var isVertical: Bool { self == .left || self == .right }
}

struct QuietHoursSchedule: Equatable {
    let startMinutes: Int
    let endMinutes: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = normalized(startMinutes)
        let end = normalized(endMinutes)

        if start == end { return true }
        if start < end { return current >= start && current < end }
        return current >= start || current < end
    }

    private func normalized(_ minutes: Int) -> Int {
        min(max(minutes, 0), 23 * 60 + 59)
    }
}

final class TickerSettings {
    static let boldMinchoFontFamily = "__bold_mincho__"
    /// 旧バージョンで保存された識別子。読み込み時に現行の値へ読み替える。
    private static let legacyBoldMinchoFontFamily = "__eva_mincho__"

    private enum Key {
        static let backgroundOpacity = "backgroundOpacity"
        static let speed = "tickerSpeed"
        static let fontSize = "fontSize"
        static let fontFamily = "fontFamily"
        static let ignoresMouse = "ignoresMouse"
        static let enabled = "tickerEnabled"
        static let edge = "tickerEdge"
        static let displayID = "displayID"
        static let soundEnabled = "soundEnabled"
        static let soundName = "soundName"
        static let soundSelection = "soundSelection"
        static let soundLoopSelections = "soundLoopSelections"
        static let customSoundPaths = "customSoundPaths"
        static let feedsEnabled = "feedsEnabled"
        static let feedURLs = "feedURLs"
        static let feedIntervalMinutes = "feedIntervalMinutes"
        static let feedSoundSelections = "feedSoundSelections"
        static let feedIgnoresEarthquakeNews = "feedIgnoresEarthquakeNews"
        static let earthquakeAlertsEnabled = "earthquakeAlertsEnabled"
        static let earthquakeMinimumIntensity = "earthquakeMinimumIntensity"
        static let earthquakeSoundSelection = "earthquakeSoundSelection"
        static let ignoresClockWeatherWidgets = "ignoresClockWeatherWidgets"
        static let quietHoursEnabled = "quietHoursEnabled"
        static let quietHoursStartMinutes = "quietHoursStartMinutes"
        static let quietHoursEndMinutes = "quietHoursEndMinutes"
    }

    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?

    var backgroundOpacity: Double {
        didSet { save(Key.backgroundOpacity, backgroundOpacity) }
    }

    var speed: Double {
        didSet { save(Key.speed, speed) }
    }

    var fontSize: Double {
        didSet { save(Key.fontSize, fontSize) }
    }

    var fontFamily: String {
        didSet { save(Key.fontFamily, fontFamily) }
    }

    var ignoresMouse: Bool {
        didSet { save(Key.ignoresMouse, ignoresMouse) }
    }

    var isEnabled: Bool {
        didSet { save(Key.enabled, isEnabled) }
    }

    var edge: TickerEdge {
        didSet { save(Key.edge, edge.rawValue) }
    }

    /// Zero means the current main display. Otherwise this is a CGDirectDisplayID.
    var displayID: UInt32 {
        didSet { save(Key.displayID, Int(displayID)) }
    }

    var soundEnabled: Bool {
        didSet { save(Key.soundEnabled, soundEnabled) }
    }

    var soundName: String {
        didSet { save(Key.soundName, soundName) }
    }

    var soundSelection: String {
        didSet { save(Key.soundSelection, soundSelection) }
    }

    /// 音源（"system:Glass" や "file:/path"）ごとのループ設定。未登録はループする。
    var soundLoopSelections: [String: Bool] {
        didSet { save(Key.soundLoopSelections, soundLoopSelections) }
    }

    func loopsSound(_ selection: String) -> Bool {
        soundLoopSelections[selection] ?? true
    }

    func setLoops(_ loops: Bool, forSound selection: String) {
        soundLoopSelections[selection] = loops
    }

    var customSoundPaths: [String] {
        didSet { save(Key.customSoundPaths, customSoundPaths) }
    }

    var feedsEnabled: Bool {
        didSet { save(Key.feedsEnabled, feedsEnabled) }
    }

    var feedURLs: [String] {
        didSet { save(Key.feedURLs, feedURLs) }
    }

    var feedIntervalMinutes: Double {
        didSet { save(Key.feedIntervalMinutes, feedIntervalMinutes) }
    }

    /// フィードURL → 効果音の選択文字列。未設定のフィードは共通の通知音を使う。
    var feedSoundSelections: [String: String] {
        didSet { save(Key.feedSoundSelections, feedSoundSelections) }
    }

    func soundSelection(forFeedURL urlString: String) -> String? {
        feedSoundSelections[urlString]
    }

    /// ニュースフィードの地震関連の見出しを捨てるか。地震は気象庁の速報が担当する。
    var feedIgnoresEarthquakeNews: Bool {
        didSet { save(Key.feedIgnoresEarthquakeNews, feedIgnoresEarthquakeNews) }
    }

    var earthquakeAlertsEnabled: Bool {
        didSet { save(Key.earthquakeAlertsEnabled, earthquakeAlertsEnabled) }
    }

    /// 表示する下限の震度。`JMAEarthquakeReport.selectableIntensities` の値を保存する。
    var earthquakeMinimumIntensity: String {
        didSet { save(Key.earthquakeMinimumIntensity, earthquakeMinimumIntensity) }
    }

    /// 地震速報に使う効果音。空文字なら共通の通知音を使う。
    var earthquakeSoundSelection: String {
        didSet { save(Key.earthquakeSoundSelection, earthquakeSoundSelection) }
    }

    var effectiveEarthquakeSoundSelection: String? {
        earthquakeSoundSelection.isEmpty ? nil : earthquakeSoundSelection
    }

    var ignoresClockWeatherWidgets: Bool {
        didSet { save(Key.ignoresClockWeatherWidgets, ignoresClockWeatherWidgets) }
    }

    var quietHoursEnabled: Bool {
        didSet { save(Key.quietHoursEnabled, quietHoursEnabled) }
    }

    var quietHoursStartMinutes: Int {
        didSet { save(Key.quietHoursStartMinutes, quietHoursStartMinutes) }
    }

    var quietHoursEndMinutes: Int {
        didSet { save(Key.quietHoursEndMinutes, quietHoursEndMinutes) }
    }

    var isQuietHoursActive: Bool {
        quietHoursEnabled && QuietHoursSchedule(
            startMinutes: quietHoursStartMinutes,
            endMinutes: quietHoursEndMinutes
        ).contains(Date())
    }

    init() {
        // 要素数が多い [String: Any] のリテラルは型推論が指数的に重くなるため、
        // 明示的に型を書いてビルド時間を抑える。
        let registered: [String: Any] = [
            Key.backgroundOpacity: 0.62,
            Key.speed: 105.0,
            Key.fontSize: 18.0,
            Key.fontFamily: Self.boldMinchoFontFamily,
            Key.ignoresMouse: true,
            Key.enabled: true,
            Key.edge: TickerEdge.bottom.rawValue,
            Key.displayID: 0,
            Key.soundEnabled: false,
            Key.soundName: "Glass",
            Key.soundSelection: "system:Glass",
            Key.soundLoopSelections: [String: Bool](),
            Key.customSoundPaths: [],
            Key.feedsEnabled: false,
            Key.feedURLs: [],
            Key.feedIntervalMinutes: 5.0,
            Key.feedSoundSelections: [String: String](),
            Key.feedIgnoresEarthquakeNews: false,
            Key.earthquakeAlertsEnabled: true,
            Key.earthquakeMinimumIntensity: "4",
            Key.earthquakeSoundSelection: "",
            Key.ignoresClockWeatherWidgets: true,
            Key.quietHoursEnabled: false,
            Key.quietHoursStartMinutes: 23 * 60,
            Key.quietHoursEndMinutes: 7 * 60
        ]
        defaults.register(defaults: registered)

        backgroundOpacity = defaults.double(forKey: Key.backgroundOpacity)
        speed = defaults.double(forKey: Key.speed)
        fontSize = defaults.double(forKey: Key.fontSize)
        let minchoMigrationKey = "didApplyBoldMinchoV1"
        if !defaults.bool(forKey: minchoMigrationKey) {
            defaults.set(Self.boldMinchoFontFamily, forKey: Key.fontFamily)
            defaults.set(true, forKey: minchoMigrationKey)
        }
        let storedFontFamily = defaults.string(forKey: Key.fontFamily) ?? Self.boldMinchoFontFamily
        if storedFontFamily == Self.legacyBoldMinchoFontFamily {
            // 保存済みの値も現行の識別子へ書き換えておく。
            defaults.set(Self.boldMinchoFontFamily, forKey: Key.fontFamily)
            fontFamily = Self.boldMinchoFontFamily
        } else {
            fontFamily = storedFontFamily
        }
        ignoresMouse = defaults.bool(forKey: Key.ignoresMouse)
        isEnabled = defaults.bool(forKey: Key.enabled)
        edge = TickerEdge(rawValue: defaults.string(forKey: Key.edge) ?? "") ?? .bottom
        displayID = UInt32(clamping: defaults.integer(forKey: Key.displayID))
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        soundName = defaults.string(forKey: Key.soundName) ?? "Glass"
        soundSelection = defaults.string(forKey: Key.soundSelection) ?? "system:Glass"
        soundLoopSelections = defaults.dictionary(forKey: Key.soundLoopSelections) as? [String: Bool] ?? [:]
        customSoundPaths = defaults.stringArray(forKey: Key.customSoundPaths) ?? []
        feedsEnabled = defaults.bool(forKey: Key.feedsEnabled)
        feedURLs = defaults.stringArray(forKey: Key.feedURLs) ?? []
        feedIntervalMinutes = defaults.double(forKey: Key.feedIntervalMinutes)
        feedSoundSelections = defaults.dictionary(forKey: Key.feedSoundSelections) as? [String: String] ?? [:]
        feedIgnoresEarthquakeNews = defaults.bool(forKey: Key.feedIgnoresEarthquakeNews)
        earthquakeAlertsEnabled = defaults.bool(forKey: Key.earthquakeAlertsEnabled)
        earthquakeMinimumIntensity = defaults.string(forKey: Key.earthquakeMinimumIntensity) ?? "4"
        earthquakeSoundSelection = defaults.string(forKey: Key.earthquakeSoundSelection) ?? ""
        ignoresClockWeatherWidgets = defaults.bool(forKey: Key.ignoresClockWeatherWidgets)
        quietHoursEnabled = defaults.bool(forKey: Key.quietHoursEnabled)
        quietHoursStartMinutes = defaults.integer(forKey: Key.quietHoursStartMinutes)
        quietHoursEndMinutes = defaults.integer(forKey: Key.quietHoursEndMinutes)
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}

import CryptoKit
import Foundation

/// 発信元によらず、同じ本文を24時間以内に再表示しないための記録。
/// 表示直前に時刻を差し込む前の本文で判定する（時刻を含めると毎回別物になるため）。
final class MessageDeduplicator {
    static let defaultWindow: TimeInterval = 24 * 60 * 60
    /// 「待ち」系の通知は、繰り返し起きること自体が知らせたい内容なので、
    /// 24時間ブロックすると用をなさない。連投だけを抑える短い間隔にする。
    static let recurringWindow: TimeInterval = 3 * 60

    private static let recurringMarkers = [
        "待ち", "待っています", "待機中", "waiting", "waits for"
    ]

    /// 繰り返し流したい通知かどうか。
    static func isRecurring(_ text: String) -> Bool {
        let normalized = normalize(text).lowercased()
        return recurringMarkers.contains { normalized.contains($0.lowercased()) }
    }

    private let window: TimeInterval
    private let defaults: UserDefaults
    private let storageKey = "recentMessageDigests"
    /// 本文のダイジェスト → 最後に表示した時刻。
    private var seen: [String: Date]

    init(
        window: TimeInterval = MessageDeduplicator.defaultWindow,
        defaults: UserDefaults = .standard
    ) {
        self.window = window
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        self.seen = stored.mapValues { Date(timeIntervalSince1970: $0) }
        prune(now: Date())
    }

    /// 表示してよければ true を返し、その時点で表示済みとして記録する。
    func shouldEmit(_ text: String, now: Date = Date()) -> Bool {
        let digest = Self.digest(for: text)
        guard !digest.isEmpty else { return false }

        prune(now: now)
        let effectiveWindow = Self.isRecurring(text) ? Self.recurringWindow : window
        if let lastSeen = seen[digest], now.timeIntervalSince(lastSeen) < effectiveWindow {
            return false
        }
        seen[digest] = now
        persist()
        return true
    }

    /// 空白の違いだけの本文を同一とみなす。
    static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func digest(for text: String) -> String {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return "" }
        let hash = SHA256.hash(data: Data(normalized.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func prune(now: Date) {
        let before = seen.count
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        if seen.count != before { persist() }
    }

    private func persist() {
        defaults.set(seen.mapValues { $0.timeIntervalSince1970 }, forKey: storageKey)
    }
}

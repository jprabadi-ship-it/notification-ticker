import Foundation

/// ティッカーに流したメッセージの記録。新しいものが先頭。
/// /tmp 配下のファイルに保存する。アプリを再起動しても残るが、Mac を再起動すると
/// 消える。通知の本文を長く残さないための落としどころ。
final class DisplayHistory {
    struct Entry: Equatable, Codable {
        let date: Date
        /// 「通達」「通知」「地震」など。行頭バッジの文字から余白を除いたもの。
        let kind: String
        let text: String
        let link: URL?
    }

    /// 既定の保存先。/tmp は Mac の再起動で空になる。
    static let defaultStorageURL = URL(fileURLWithPath: "/tmp/NotificationTicker/history.json")

    /// 保持する上限。超えた分は古いものから捨てる。
    let limit: Int
    /// nil ならメモリ上だけに持つ（テスト用）。
    private let storageURL: URL?
    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    init(limit: Int = 20, storageURL: URL? = DisplayHistory.defaultStorageURL) {
        self.limit = limit
        self.storageURL = storageURL
        load()
    }

    func record(text: String, badge: String, link: URL?, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = Entry(
            date: date,
            kind: badge.trimmingCharacters(in: .whitespaces),
            text: trimmed,
            link: link
        )
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        persist()
        onChange?()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
        onChange?()
    }

    private func load() {
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = Array(decoded.prefix(limit))
    }

    /// /tmp は他のユーザーからも見える場所なので、ディレクトリは 700、ファイルは 600 にする。
    /// 原子的書き込みは新しいファイルを作るため、書いたあとに権限を付け直す。
    private func persist() {
        guard let storageURL else { return }
        let manager = FileManager.default
        let directory = storageURL.deletingLastPathComponent()
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storageURL, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
}

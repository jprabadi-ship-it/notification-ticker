import Foundation

/// ティッカーに流したメッセージの記録。新しいものが先頭。
/// メモリ上だけに持ち、アプリを終了すると消える。通知の本文をファイルへ
/// 保存しないという方針（README のプライバシー）を守るため、永続化はしない。
final class DisplayHistory {
    struct Entry: Equatable {
        let date: Date
        /// 「通達」「通知」「地震」など。行頭バッジの文字から余白を除いたもの。
        let kind: String
        let text: String
        let link: URL?
    }

    /// 保持する上限。超えた分は古いものから捨てる。
    let limit: Int
    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    init(limit: Int = 300) {
        self.limit = limit
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
        onChange?()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        onChange?()
    }
}

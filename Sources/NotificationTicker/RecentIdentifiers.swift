import Foundation

/// 表示済みの記事IDを、見た順に上限つきで覚える。
/// Set だけで持って `suffix` で切ると、順序が無いため直近に見たIDが
/// 落ちることがあり、その記事が取得のたびに「新着」へ戻ってしまう。
/// 古いものから捨てるために順序を保つ。
struct RecentIdentifiers: Equatable {
    let limit: Int
    /// 見た順（古い → 新しい）。
    private(set) var ordered: [String] = []
    private var members: Set<String> = []

    init(limit: Int, initial: [String] = []) {
        self.limit = max(1, limit)
        initial.forEach { insert($0) }
    }

    var count: Int { ordered.count }

    func contains(_ identifier: String) -> Bool { members.contains(identifier) }

    /// 新しく見たIDを末尾に足す。既に知っているIDは位置を動かさない。
    /// 上限を超えたら、いちばん古いものから捨てる。
    mutating func insert(_ identifier: String) {
        guard !identifier.isEmpty, members.insert(identifier).inserted else { return }
        ordered.append(identifier)
        while ordered.count > limit {
            members.remove(ordered.removeFirst())
        }
    }
}

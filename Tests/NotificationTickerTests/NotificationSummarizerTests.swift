import XCTest
@testable import NotificationTicker

final class NotificationSummarizerTests: XCTestCase {
    private let longText = """
    本日午後、東京都内で開催された記者会見において、新型スマートフォンの発表が行われました。\
    新モデルは従来機種と比較してバッテリー持続時間が約30パーセント向上し、カメラ性能も大幅に\
    強化されています。価格は12万円からで、来月15日より全国の家電量販店およびオンラインストアで\
    販売が開始される予定です。予約受付は今週金曜日から始まります。
    """

    /// Ollama が起動しているときだけ実行する。CI や未導入環境では省略。
    private func requireOllama() throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        request.timeoutInterval = 2
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        try XCTSkipUnless(reachable, "Ollama が起動していないため省略")
    }

    func testSummarizesWithLocalLLM() async throws {
        try requireOllama()
        let summary = await NotificationSummarizer.summarize(
            longText, using: .localLLM(model: "gemma3:4b"), limit: 50
        )
        let unwrapped = try XCTUnwrap(summary, "ローカルLLMが要約を返さなかった")
        XCTAssertFalse(unwrapped.isEmpty)
        // 元の本文よりは確実に短い。
        XCTAssertLessThan(unwrapped.count, longText.count)
        // 保険が効いて、上限の2倍を超えて長いままにはならない。
        XCTAssertLessThanOrEqual(unwrapped.count, 51)
        XCTAssertFalse(unwrapped.contains("\n"))
    }

    func testReturnsNilWhenModelIsUnknown() async throws {
        try requireOllama()
        let summary = await NotificationSummarizer.summarize(
            longText, using: .localLLM(model: "存在しないモデル:0b"), limit: 50
        )
        XCTAssertNil(summary)
    }

    func testBackendPrefersAppleIntelligenceThenFallsBack() {
        // Apple Intelligence が使えない環境では、設定されたローカルモデルへ回る。
        if !NotificationSummarizer.isUsable {
            switch NotificationSummarizer.backend(localModel: "gemma3:4b") {
            case .localLLM(let model): XCTAssertEqual(model, "gemma3:4b")
            default: XCTFail("ローカルLLMが選ばれるべき")
            }
            // 未設定なら要約しない（呼び出し側が切り詰めに落とす）。
            XCTAssertNil(NotificationSummarizer.backend(localModel: nil))
            XCTAssertNil(NotificationSummarizer.backend(localModel: "   "))
        }
    }

    func testTidyTrimsAndCapsOverlongOutput() {
        XCTAssertNil(NotificationSummarizer.tidy("   ", limit: 50))
        XCTAssertNil(NotificationSummarizer.tidy(nil, limit: 50))
        XCTAssertEqual(NotificationSummarizer.tidy(" 要約\nです ", limit: 50), "要約 です")

        let overlong = String(repeating: "あ", count: 200)
        let tidied = try? XCTUnwrap(NotificationSummarizer.tidy(overlong, limit: 50))
        XCTAssertEqual(tidied, String(repeating: "あ", count: 50) + "…")
    }
}

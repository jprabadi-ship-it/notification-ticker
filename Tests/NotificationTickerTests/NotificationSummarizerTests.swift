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
    /// モデルが解放されていると最初の要求が読み込み待ちで時間切れになり、アプリの
    /// 論理ではなく Ollama の状態を測ることになるので、確認のあとで先に載せておく。
    private func requireOllama() throws {
        try requireOllamaReachable()
        warmModel()
    }

    private func warmModel() {
        var request = URLRequest(url: NotificationSummarizer.ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gemma3:4b",
            "keep_alive": "30m",
            "options": ["num_ctx": NotificationSummarizer.contextLength]
        ])
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 120)
    }

    private func requireOllamaReachable() throws {
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
        let limit = NotificationSummarizer.defaultLimit
        let summary = await NotificationSummarizer.summarize(
            longText, using: .localLLM(model: "gemma3:4b"), limit: limit
        )
        let unwrapped = try XCTUnwrap(summary, "ローカルLLMが要約を返さなかった")
        XCTAssertFalse(unwrapped.isEmpty)
        // 元の本文よりは確実に短い。
        XCTAssertLessThan(unwrapped.count, longText.count)
        // モデルは指示した字数を守らないことがある（実測で60字指定に66字を返した）。
        // アプリが保証するのは tidy による「上限の2倍で丸める」ところまで。
        XCTAssertLessThanOrEqual(unwrapped.count, limit * 2)
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

    func testRecordsOutcomeAfterLocalLLMAttempt() async throws {
        try requireOllama()
        _ = await NotificationSummarizer.summarize(longText, using: .localLLM(model: "gemma3:4b"))
        let outcome = try XCTUnwrap(NotificationSummarizer.lastOutcome)
        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertTrue(outcome.detail.hasPrefix("成功"))

        _ = await NotificationSummarizer.summarize(longText, using: .localLLM(model: "存在しないモデル:0b"))
        let failed = try XCTUnwrap(NotificationSummarizer.lastOutcome)
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(failed.detail.contains("HTTP"), failed.detail)
    }

    func testModelNameMatchingIgnoresDefaultTag() {
        XCTAssertTrue(NotificationSummarizer.modelNameMatches(listed: "gemma3:4b", wanted: "gemma3:4b"))
        XCTAssertTrue(NotificationSummarizer.modelNameMatches(listed: "gemma3:latest", wanted: "gemma3"))
        XCTAssertTrue(NotificationSummarizer.modelNameMatches(listed: "gemma3:4b", wanted: " gemma3:4b "))
        XCTAssertFalse(NotificationSummarizer.modelNameMatches(listed: "gemma3:4b", wanted: "gemma3:12b"))
        XCTAssertFalse(NotificationSummarizer.modelNameMatches(listed: "gemma3:4b", wanted: "gemma3"))
    }

    func testIsLoadedReflectsOllamaState() async throws {
        try requireOllama()
        // 本番と同じコンテキスト長で載せてから確かめる。
        _ = await NotificationSummarizer.summarize(longText, using: .localLLM(model: "gemma3:4b"))
        let loaded = await NotificationSummarizer.isLoaded(model: "gemma3:4b")
        XCTAssertTrue(loaded)
        let missing = await NotificationSummarizer.isLoaded(model: "存在しないモデル:0b")
        XCTAssertFalse(missing)
    }

    func testTidyTrimsAndCapsOverlongOutput() {
        XCTAssertNil(NotificationSummarizer.tidy("   ", limit: 50))
        XCTAssertNil(NotificationSummarizer.tidy(nil, limit: 50))
        XCTAssertEqual(NotificationSummarizer.tidy(" 要約\nです ", limit: 50), "要約 です")

        let overlong = String(repeating: "あ", count: 200)
        let tidied = try? XCTUnwrap(NotificationSummarizer.tidy(overlong, limit: 50))
        XCTAssertEqual(tidied, String(repeating: "あ", count: 50) + "…")
    }

    func testTidyDropsTrailingSentencesBeyondLimit() {
        // TinySwallow の実際の返答（83字）。上限60字なら3文目以降を捨てる。
        let raw = "2026年分の生命保険料控除証明書を発送しました。年末調整時に勤務先へ提出してください。"
            + "11月20日までにカスタマーセンターへ連絡。マイページからもダウンロード可能。"
        XCTAssertEqual(
            NotificationSummarizer.tidy(raw, limit: 60),
            "2026年分の生命保険料控除証明書を発送しました。年末調整時に勤務先へ提出してください。"
        )
        // 上限以内ならそのまま。
        XCTAssertEqual(NotificationSummarizer.tidy("短い要約。二文目。", limit: 60), "短い要約。二文目。")
    }

    func testTidyKeepsNextSentenceWhenFirstIsTooShort() {
        // 「ビルド失敗。」だけでは何も分からないので、上限の2倍までは次の文も残す。
        let second = "Sources/App/Main.swift の 142 行目で型 'String' の値を 'Int' に変換できません。"
        let raw = "ビルド失敗。" + second + "警告が3件。"
        XCTAssertEqual(NotificationSummarizer.tidy(raw, limit: 60), "ビルド失敗。" + second)
    }

    func testSentencesSplitAfterTerminators() {
        XCTAssertEqual(
            NotificationSummarizer.sentences(of: "一。二！三？末尾"),
            ["一。", "二！", "三？", "末尾"]
        )
    }

    func testPromptStyleDependsOnModelSize() {
        XCTAssertEqual(NotificationSummarizer.promptStyle(parameterCount: 1_543_714_304), .compact)  // TinySwallow
        XCTAssertEqual(NotificationSummarizer.promptStyle(parameterCount: 1_728_801_536), .compact)  // LFM3
        XCTAssertEqual(NotificationSummarizer.promptStyle(parameterCount: 4_299_915_632), .detailed) // gemma3:4b
        // 分からなければ、大きいモデルで実績のある詳しい指示に倒す。
        XCTAssertEqual(NotificationSummarizer.promptStyle(parameterCount: nil), .detailed)
        XCTAssertEqual(NotificationSummarizer.promptStyle(parameterCount: 0), .detailed)
    }

    func testCompactPromptAsksForShorterTargetAndCarriesText() {
        let prompt = NotificationSummarizer.compactPrompt(for: "本文テキスト", limit: 60)
        XCTAssertTrue(prompt.contains("40文字以内"))
        XCTAssertTrue(prompt.hasSuffix("本文テキスト"))
    }

    func testPresetsCoverGemmaAndTinySwallow() {
        XCTAssertEqual(NotificationSummarizer.preset(matching: "gemma3:4b")?.model, "gemma3:4b")
        XCTAssertEqual(
            NotificationSummarizer.preset(matching: " hf.co/SakanaAI/TinySwallow-1.5B-Instruct-GGUF:Q8_0 ")?.model,
            "hf.co/SakanaAI/TinySwallow-1.5B-Instruct-GGUF:Q8_0"
        )
        // 一覧にないモデルは「その他」扱い。
        XCTAssertNil(NotificationSummarizer.preset(matching: "qwen3:8b"))
        XCTAssertNil(NotificationSummarizer.preset(matching: ""))
    }

    func testInstalledModelsListsPresetsWhenOllamaIsUp() async throws {
        try requireOllamaReachable()
        let listed = await NotificationSummarizer.installedModels()
        let installed = try XCTUnwrap(listed)
        for preset in NotificationSummarizer.localModelPresets {
            XCTAssertTrue(
                installed.contains { NotificationSummarizer.modelNameMatches(listed: $0, wanted: preset.model) },
                "\(preset.model) が一覧にない"
            )
        }
    }

    func testParameterCountComesFromOllama() async throws {
        try requireOllamaReachable()
        let count = await NotificationSummarizer.parameterCount(model: "gemma3:4b")
        try XCTSkipIf(count == nil, "gemma3:4b が入っていないため省略")
        XCTAssertEqual(NotificationSummarizer.promptStyle(parameterCount: count), .detailed)
        let unknown = await NotificationSummarizer.parameterCount(model: "存在しないモデル:0b")
        XCTAssertNil(unknown)
    }
}

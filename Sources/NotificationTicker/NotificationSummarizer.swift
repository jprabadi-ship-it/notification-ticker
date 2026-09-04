import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 長文通知の要約（実験的）。Apple Intelligence のオンデバイスモデルを使う。
/// 処理はすべて端末内で完結し、外部への送信は発生しない。
/// Apple Intelligence が使えない環境向けに、ローカルで動く Ollama を
/// 代替として選べる（実験用）。どちらも端末内で完結し、外部送信はない。
/// モデルが使えない環境・失敗・時間切れのときは nil を返し、呼び出し側が
/// 従来の切り詰め表示に落とす。
enum NotificationSummarizer {
    /// 要約を担う実体。
    enum Backend {
        case appleIntelligence
        case localLLM(model: String)
    }

    /// Ollama の待ち受け先。localhost 固定で、外部へは出さない。
    static let ollamaEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

    /// いまこの環境で要約できるか。Apple Intelligence が無効、モデル未ダウンロード、
    /// macOS 26 未満のいずれでも false。
    static var isUsable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// 人が読める、使えない理由。設定画面の状態表示に使う。
    static var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "要約に使用できます"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence が無効です"
            case .unavailable(.modelNotReady):
                return "モデルを準備中です（ダウンロード待ち）"
            case .unavailable(.deviceNotEligible):
                return "この Mac では利用できません"
            case .unavailable:
                return "利用できません"
            }
        }
        #endif
        return "macOS 26 以降が必要です"
    }

    /// 実際に使う実体を決める。Apple Intelligence を優先し、
    /// 使えなければ設定で有効にされたローカル LLM に回す。
    static func backend(localModel: String?) -> Backend? {
        if isUsable { return .appleIntelligence }
        if let localModel, !localModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return .localLLM(model: localModel)
        }
        return nil
    }

    /// 要約に許す長さ。50字まで詰めさせると、複数の事実をひとつに丸めた
    /// 取り違えが起きた（「生命保険料控除証明書」→「保険証券」など）ため、
    /// 少し緩めて「収まらないなら捨てる」を明示する方が安全だった。
    static let defaultLimit = 60

    /// 要約の指示文。実体によらず同じ条件を課す。
    /// 字数を詰めるための言い換え・統合が事実の取り違えを生むので、
    /// 「丸めずに捨てる」ことを最優先で命じる。
    static func instructions(limit: Int) -> String {
        """
        次の通知を、画面を一度だけ流れるテロップ用に短くしてください。

        制約:
        - 日本語、全角\(limit)文字以内、1〜2文。
        - 冒頭に結論（何が起きたか／利用者が何をすべきか）を置く。原因や経緯は結論の後に回す。
        - 日付・時刻・金額・件数・書類名・製品名・行番号などの固有名詞と数値は、原文にある表記をそのまま使う。
        - \(limit)文字に収まらないときは、重要度の低い事実を丸ごと捨てる。
          複数の事実をひとつにまとめたり、上位概念に置き換えたりしてはいけない。
          悪い例:「生命保険料控除証明書」を「保険証券」と書く。
          悪い例:「予約は今週金曜」と「発売は来月15日」を「来月」とまとめる。
          良い例: 収まらないなら発売日のほうを書かずに落とす。
        - 原文にない語を足さない。推測で補わない。
        - 敬語・挨拶・前置きは削る。文末は言い切る。

        出力は要約本文のみ。前置きや説明を書かないこと。
        """
    }

    /// 長すぎる返答を丸める。モデルが指定を守らないことがあるため。
    static func tidy(_ raw: String?, limit: Int) -> String? {
        guard let summary = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " "),
            !summary.isEmpty else { return nil }
        return summary.count > limit * 2 ? String(summary.prefix(limit)) + "…" : summary
    }

    /// 指定の実体で要約する。
    static func summarize(
        _ text: String,
        using backend: Backend,
        limit: Int = defaultLimit,
        timeout: TimeInterval = 20
    ) async -> String? {
        switch backend {
        case .appleIntelligence:
            return await summarize(text, limit: limit, timeout: timeout)
        case .localLLM(let model):
            return await summarizeWithOllama(text, model: model, limit: limit, timeout: timeout)
        }
    }

    /// ローカルの Ollama に要約させる。起動していなければ即座に失敗して nil。
    private static func summarizeWithOllama(
        _ text: String,
        model: String,
        limit: Int,
        timeout: TimeInterval
    ) async -> String? {
        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        let payload: [String: Any] = [
            "model": model,
            "system": instructions(limit: limit),
            "prompt": text,
            "stream": false,
            // 思考過程を出すモデルでも要約だけを受け取る。
            "think": false,
            // 読み込み済みのモデルを保持し、間が空いたあとの初回で待たされないようにする。
            "keep_alive": "30m",
            "options": ["temperature": 0.2, "num_predict": 160]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return tidy(object["response"] as? String, limit: limit)
    }

    /// 本文を指定文字数以内へ要約する。失敗・時間切れは nil。
    /// ティッカーを待たせないよう、応答が遅ければ諦める。
    static func summarize(_ text: String, limit: Int = defaultLimit, timeout: TimeInterval = 10) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isUsable else { return nil }
        let work = Task { () -> String? in
            let session = LanguageModelSession(instructions: instructions(limit: limit))
            let response = try? await session.respond(to: text)
            return tidy(response?.content, limit: limit)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            work.cancel()
        }
        let result = await work.value
        timeoutTask.cancel()
        return result
        #else
        return nil
        #endif
    }
}

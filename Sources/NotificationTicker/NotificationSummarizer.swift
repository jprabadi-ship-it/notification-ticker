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

    /// Ollama に渡すコンテキスト長。通知は短いので小さくてよい。
    /// Ollama 0.33 の既定（65536）だとモデルの読み込みに 29 秒かかり、時間切れに
    /// なった。先読みと本番で値が違うと読み直しが起きるため、必ず同じ値を使う。
    static let contextLength = 2048

    /// 直近の要約の結果。設定画面で「なぜ要約されなかったか」を見せるため。
    struct Outcome {
        let date: Date
        let succeeded: Bool
        let detail: String
    }
    /// メインスレッドからだけ触る。
    static private(set) var lastOutcome: Outcome?

    /// 設定画面で選べるローカルモデル。使用メモリは num_ctx 2048 で読み込んだときの実測。
    struct LocalModelPreset: Equatable {
        /// 状態表示に使う短い名前。正式名は長く、設定画面の幅を押し広げるため。
        let name: String
        let note: String
        let model: String
        var title: String { "\(name)（\(note)）" }
    }
    static let localModelPresets = [
        LocalModelPreset(name: "gemma3:4b", note: "要約の質を優先・約2.9GB", model: "gemma3:4b"),
        LocalModelPreset(
            name: "TinySwallow 1.5B",
            note: "省メモリ・約1.8GB",
            model: "hf.co/SakanaAI/TinySwallow-1.5B-Instruct-GGUF:Q8_0"
        ),
    ]

    static func preset(matching model: String) -> LocalModelPreset? {
        localModelPresets.first { modelNameMatches(listed: $0.model, wanted: model) }
    }

    /// Ollama に入っているモデルの一覧。
    static let ollamaTagsEndpoint = URL(string: "http://127.0.0.1:11434/api/tags")!

    /// 入っているモデル名。Ollama に繋がらなければ nil（入っているか分からない）。
    static func installedModels() async -> [String]? {
        var request = URLRequest(url: ollamaTagsEndpoint)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else { return nil }
        return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
    }

    /// Ollama が保持しているモデルの一覧。
    static let ollamaProcessesEndpoint = URL(string: "http://127.0.0.1:11434/api/ps")!

    /// /api/ps に同名のモデルが、こちらと同じコンテキスト長で載っているか。
    /// コンテキスト長が違うと本番の要求で読み直しが起きるので、載っていない扱いにする。
    static func isLoaded(model: String) async -> Bool {
        var request = URLRequest(url: ollamaProcessesEndpoint)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else { return false }
        return models.contains { entry in
            let listed = (entry["name"] as? String) ?? (entry["model"] as? String) ?? ""
            let context = (entry["context_length"] as? Int) ?? 0
            return modelNameMatches(listed: listed, wanted: model) && context == contextLength
        }
    }

    /// 「gemma3:4b」と「gemma3:4b」、タグ省略の「gemma3」と「gemma3:latest」を同じとみなす。
    static func modelNameMatches(listed: String, wanted: String) -> Bool {
        func normalized(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.contains(":") ? trimmed : trimmed + ":latest"
        }
        return normalized(listed) == normalized(wanted)
    }

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

    /// 指示文の書き方。小さいモデルは長い規則の羅列に従えず、原文をほぼ写して返す。
    enum PromptStyle: Equatable {
        /// 規則と悪い例を並べた詳しい指示。4B 以上のモデルと Apple Intelligence 向け。
        case detailed
        /// 依頼文に通知を同居させた短い指示。1〜2B 級のモデル向け。
        case compact
    }

    /// これ未満のパラメータ数なら短い指示を使う。
    /// 実測（2026-10-30）: TinySwallow 1.5B・LFM3 1.7B は短い指示で合格が増え、
    /// gemma3:4b は短い指示だと事実を落とし表記を変えた（「11月3日」→「11/1～3日」）。
    static let compactPromptParameterLimit = 3_000_000_000

    static func promptStyle(parameterCount: Int?) -> PromptStyle {
        guard let parameterCount, parameterCount > 0 else { return .detailed }
        return parameterCount < compactPromptParameterLimit ? .compact : .detailed
    }

    /// 小さいモデル向けの依頼文。末尾に通知の本文を続ける。
    /// 小さいモデルは指定より長く書くので、目標を上限の 2/3 にして伝える。
    static func compactPrompt(for text: String, limit: Int) -> String {
        let target = max(limit * 2 / 3, 20)
        return """
        次の通知を、\(target)文字以内の1文に要約してください。
        - 最初に、何が起きたかを書く。
        - 通知に出てくる名前・日付・時刻・金額・番号・ファイル名・行番号は、そのまま写す。
        - 要約だけを出力する。

        通知:
        \(text)
        """
    }

    /// Ollama のモデル情報。パラメータ数はモデル名から分からないので問い合わせる。
    static let ollamaShowEndpoint = URL(string: "http://127.0.0.1:11434/api/show")!

    private static let parameterCountLock = NSLock()
    private static var parameterCountCache: [String: Int] = [:]

    /// モデルのパラメータ数。取れなければ nil（呼び出し側は詳しい指示に倒す）。
    static func parameterCount(model: String) async -> Int? {
        let key = model.trimmingCharacters(in: .whitespaces)
        parameterCountLock.lock()
        let cached = parameterCountCache[key]
        parameterCountLock.unlock()
        if let cached { return cached }

        var request = URLRequest(url: ollamaShowEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": key])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["model_info"] as? [String: Any],
              let count = (info["general.parameter_count"] as? NSNumber)?.intValue,
              count > 0
        else { return nil }

        parameterCountLock.lock()
        parameterCountCache[key] = count
        parameterCountLock.unlock()
        return count
    }

    /// 長すぎる返答を整える。モデルが指定を守らないことがあるため。
    /// 上限を超えたら文の単位で後ろから捨てる（「丸めずに捨てる」と同じ考え方）。
    /// 残りが短すぎるときだけ、上限の2倍までは次の文も残す。
    /// 1文目だけで上限の2倍を超えるときは、上限で切って「…」を付ける。
    static func tidy(_ raw: String?, limit: Int) -> String? {
        guard let summary = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces),
            !summary.isEmpty else { return nil }
        if summary.count <= limit { return summary }

        var kept = ""
        for sentence in sentences(of: summary) {
            let fits = kept.count + sentence.count <= limit
            let tooShort = kept.count < limit / 2 && kept.count + sentence.count <= limit * 2
            guard kept.isEmpty || fits || tooShort else { break }
            kept += sentence
        }
        kept = kept.trimmingCharacters(in: .whitespaces)
        return kept.count > limit * 2 ? String(kept.prefix(limit)) + "…" : kept
    }

    /// 句点・感嘆符・疑問符の直後で区切る。区切り記号は前の文に含める。
    static func sentences(of text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?"]
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if terminators.contains(character) {
                result.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result
    }

    /// 指定の実体で要約する。結果の成否と理由を lastOutcome に残す。
    static func summarize(
        _ text: String,
        using backend: Backend,
        limit: Int = defaultLimit,
        timeout: TimeInterval = 30
    ) async -> String? {
        let summary: String?
        let detail: String
        switch backend {
        case .appleIntelligence:
            summary = await summarize(text, limit: limit, timeout: timeout)
            detail = summary == nil ? "Apple Intelligence が応答しませんでした" : "成功（Apple Intelligence）"
        case .localLLM(let model):
            (summary, detail) = await summarizeWithOllama(text, model: model, limit: limit, timeout: timeout)
        }
        let outcome = Outcome(date: Date(), succeeded: summary != nil, detail: detail)
        await MainActor.run { lastOutcome = outcome }
        tickerLog.notice("summarize: \(outcome.succeeded ? "ok" : "failed", privacy: .public) \(detail, privacy: .public)")
        return summary
    }

    /// ローカルの Ollama に要約させる。失敗したときは理由を文字列で返す。
    /// 接続できない場合だけ 2 秒後に 1 回再試行する。Ollama.app が自動更新や
    /// 再起動で数秒落ちている間を越えるため。時間切れは再試行しない。
    private static func summarizeWithOllama(
        _ text: String,
        model: String,
        limit: Int,
        timeout: TimeInterval
    ) async -> (String?, String) {
        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        let style = promptStyle(parameterCount: await parameterCount(model: model))
        var payload: [String: Any] = [
            "model": model,
            "stream": false,
            // 思考過程を出すモデルでも要約だけを受け取る。
            "think": false,
            // 常時先読みはメモリを数 GB 占有しスワップ枯渇の一因になった（2026-10-18）。
            // 要約のたびに読み込み、直後の連続通知だけ温かいまま受ける。
            "keep_alive": "2m"
        ]
        switch style {
        case .detailed:
            payload["system"] = instructions(limit: limit)
            payload["prompt"] = text
            payload["options"] = ["temperature": 0.2, "num_predict": 160, "num_ctx": contextLength]
        case .compact:
            // 小さいモデルは system より依頼文の中の指示に従う。揺れも大きいので温度 0。
            payload["prompt"] = compactPrompt(for: text, limit: limit)
            payload["options"] = ["temperature": 0, "num_predict": 160, "num_ctx": contextLength]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (nil, "要求の組み立てに失敗しました")
        }
        request.httpBody = body

        var failure = "Ollama に接続できません（Ollama.app は起動していますか？）"
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard http.statusCode == 200 else {
                    let message = (String(data: data, encoding: .utf8) ?? "").prefix(80)
                    return (nil, "Ollama がエラーを返しました（HTTP \(http.statusCode)）\(message)")
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let summary = tidy(object["response"] as? String, limit: limit)
                else { return (nil, "Ollama の応答が空でした") }
                let load = ((object["load_duration"] as? Double) ?? 0) / 1_000_000_000
                var notes: [String] = []
                if style == .compact { notes.append("小型モデル向けの指示") }
                if load >= 1 { notes.append("モデル読み込みに \(Int(load))秒") }
                return (summary, notes.isEmpty ? "成功" : "成功（\(notes.joined(separator: "・"))）")
            } catch let error as URLError where error.code == .timedOut {
                return (nil, "時間切れ（\(Int(timeout))秒）。モデルの読み込み待ちの可能性があります")
            } catch {
                failure = "Ollama に接続できません（Ollama.app は起動していますか？）"
            }
        }
        return (nil, failure)
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

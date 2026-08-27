import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 長文通知の要約（実験的）。Apple Intelligence のオンデバイスモデルを使う。
/// 処理はすべて端末内で完結し、外部への送信は発生しない。
/// モデルが使えない環境・失敗・時間切れのときは nil を返し、呼び出し側が
/// 従来の切り詰め表示に落とす。
enum NotificationSummarizer {
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

    /// 本文を指定文字数以内へ要約する。失敗・時間切れは nil。
    /// ティッカーを待たせないよう、応答が遅ければ諦める。
    static func summarize(_ text: String, limit: Int = 50, timeout: TimeInterval = 10) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isUsable else { return nil }
        let instructions = """
        与えられた通知の本文を、日本語で\(limit)文字以内の1文に要約してください。
        要約文だけを出力し、前置き・引用符・改行は付けないでください。
        """
        let work = Task { () -> String? in
            let session = LanguageModelSession(instructions: instructions)
            let response = try? await session.respond(to: text)
            let summary = response?.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard let summary, !summary.isEmpty else { return nil }
            // モデルが指定を超えて喋った場合の保険。
            return summary.count > limit * 2 ? String(summary.prefix(limit)) + "…" : summary
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

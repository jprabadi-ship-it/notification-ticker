import AppKit
import AVFoundation

/// 通知音として使う再生部品。NSSound と、すき間なくループする GaplessLoopPlayer を同じ形で扱う。
protocol NotificationSoundPlaying: AnyObject {
    var volume: Float { get set }
    var isPlaying: Bool { get }
    var loops: Bool { get set }
    @discardableResult func play() -> Bool
    @discardableResult func stop() -> Bool
}

extension NSSound: NotificationSoundPlaying {}

/// 音声ファイルを、頭と最後の無音を切り落としてすき間なく繰り返す。
///
/// NSSound の loops は、曲の最後の無音と MP3 の詰め物（エンコーダの前後の余白）を
/// 毎回そのまま鳴らすため、ループの継ぎ目に空白ができる。ここではファイルを PCM に
/// 展開して聞こえる範囲だけを残し、AVAudioPlayerNode の .loops でサンプル単位でつなぐ。
/// 展開には時間がかかる（70秒の曲で約0.1秒）ので裏で行い、終わり次第鳴らし始める。
///
/// 操作は `callbackQueue` の上で行う前提で、読み込みの完了などもそこへ返す。
/// アプリでは SoundPlayback の専用キューを渡し、メインスレッドでは鳴らさない。
final class GaplessLoopPlayer: NotificationSoundPlaying {
    /// これより小さい振幅を無音とみなす（約 -50 dBFS）。
    static let silenceThreshold: Float = 0.00316

    private let url: URL
    private let callbackQueue: DispatchQueue
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var isLoading = false
    /// 鳴らすよう求められている間 true。読み込み中も含む。
    private var wantsPlaying = false
    private var configurationObserver: NSObjectProtocol?
    private static let loadQueue = DispatchQueue(label: "jp.local.NotificationTicker.gapless-load", qos: .userInitiated)

    var loops = true

    var volume: Float {
        get { node.volume }
        set { node.volume = newValue }
    }

    var isPlaying: Bool { wantsPlaying }

    /// 読めない形式なら nil。呼び出し側は NSSound に切り替える。
    init?(url: URL, callbackQueue: DispatchQueue = .main) {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        self.url = url
        self.callbackQueue = callbackQueue
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        // 出力装置が切り替わるとエンジンは止まる。鳴らしている途中なら付け直す。
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            callbackQueue.async {
                guard let self, self.wantsPlaying else { return }
                self.node.stop()
                self.startIfReady()
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        node.stop()
        engine.stop()
    }

    @discardableResult
    func play() -> Bool {
        wantsPlaying = true
        if buffer != nil {
            node.stop()
            startIfReady()
        } else {
            load()
        }
        return true
    }

    @discardableResult
    func stop() -> Bool {
        wantsPlaying = false
        node.stop()
        engine.stop()
        return true
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        let url = url
        let callbackQueue = callbackQueue
        Self.loadQueue.async { [weak self] in
            let trimmed = Self.loadTrimmedBuffer(url: url)
            callbackQueue.async {
                guard let self else { return }
                self.isLoading = false
                guard let trimmed else {
                    tickerLog.error("gapless: failed to load \(url.lastPathComponent, privacy: .public)")
                    self.wantsPlaying = false
                    return
                }
                self.buffer = trimmed
                self.startIfReady()
            }
        }
    }

    private func startIfReady() {
        guard wantsPlaying, let buffer else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            tickerLog.error("gapless: engine start failed \(error.localizedDescription, privacy: .public)")
            wantsPlaying = false
            return
        }
        if loops {
            node.scheduleBuffer(buffer, at: nil, options: .loops)
        } else {
            node.scheduleBuffer(buffer, at: nil) { [weak self, callbackQueue] in
                callbackQueue.async { self?.wantsPlaying = false }
            }
        }
        node.play()
    }

    /// ファイルを読み、聞こえる範囲だけの PCM バッファにする。
    static func loadTrimmedBuffer(url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let full = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ),
              (try? file.read(into: full)) != nil,
              let channels = full.floatChannelData
        else { return nil }

        let channelCount = Int(full.format.channelCount)
        let range = audibleFrameRange(frameCount: Int(full.frameLength)) { index in
            var peak: Float = 0
            for channel in 0..<channelCount { peak = max(peak, abs(channels[channel][index])) }
            return peak
        }
        guard let range, range.count < Int(full.frameLength) else { return full }

        guard let trimmed = AVAudioPCMBuffer(
            pcmFormat: full.format,
            frameCapacity: AVAudioFrameCount(range.count)
        ), let destination = trimmed.floatChannelData else { return full }
        for channel in 0..<channelCount {
            destination[channel].update(from: channels[channel] + range.lowerBound, count: range.count)
        }
        trimmed.frameLength = AVAudioFrameCount(range.count)
        return trimmed
    }

    /// 無音でない最初のフレームから最後のフレームまで。全部無音なら nil。
    /// `peak(i)` は i 番目のフレームの全チャンネル中の最大振幅。
    static func audibleFrameRange(
        frameCount: Int,
        threshold: Float = silenceThreshold,
        peak: (Int) -> Float
    ) -> Range<Int>? {
        guard frameCount > 0 else { return nil }
        guard let first = (0..<frameCount).first(where: { peak($0) > threshold }),
              let last = (0..<frameCount).reversed().first(where: { peak($0) > threshold })
        else { return nil }
        return first..<(last + 1)
    }
}

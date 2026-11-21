import AppKit

/// 通知音の再生を、画面とは別の流れ（専用のキュー）で行う。
///
/// 音を鳴らす・止める・音量を変えるといった操作は、どれも裏で音声サービス（coreaudiod）に
/// 問い合わせる。音声サービスが応答しなくなると、その問い合わせは返ってこない。
/// メインスレッドで呼ぶとティッカーの描画まで止まってしまうので、ここに閉じ込める。
///
/// 呼び出し側（メインスレッド）は頼むだけで、待たずに戻る。音声サービスが止まっている間に
/// 頼みごとが溜まっても、再生と停止は最後に頼まれたものだけを行い、音量も最新の値だけを使う。
/// 戻ったときに古い音が立て続けに鳴ることはない。
final class SoundPlayback {
    typealias SoundFactory = (_ selection: String, _ gapless: Bool, _ queue: DispatchQueue) -> NotificationSoundPlaying?

    /// 一つの操作にこれ以上かかったら、音声サービスの遅れとして記録する。
    static let stallThreshold: TimeInterval = 2

    let queue: DispatchQueue
    private let makeSound: SoundFactory
    private let emergencyAudio: EmergencyAudioOverride

    // ここから下は queue の上でだけ触る。
    private var activeSound: NotificationSoundPlaying?
    private var activeSelection: String?
    private var activeWantsGapless = false
    private var fadeTimer: DispatchSourceTimer?

    // 呼び出し側と queue の両方から触るので lock で守る。
    private let lock = NSLock()
    private var latestCommand = 0
    private var pendingVolume: Float?
    private var _isFading = false

    init(
        queue: DispatchQueue = DispatchQueue(label: "jp.local.NotificationTicker.sound", qos: .userInitiated),
        emergencyAudio: EmergencyAudioOverride = EmergencyAudioOverride(output: CoreAudioOutput()),
        makeSound: @escaping SoundFactory = SoundPlayback.makeSystemSound
    ) {
        self.queue = queue
        self.emergencyAudio = emergencyAudio
        self.makeSound = makeSound
    }

    /// フェードアウトの途中か。途中なら、音量の変更でフェードを邪魔しない。
    var isFading: Bool {
        lock.withLock { _isFading }
    }

    /// 鳴らす。`loops` が true で、同じ音がすでにループ中なら鳴らし直さない。
    func play(selection: String, loops: Bool, gapless: Bool, volume: Float, urgent: Bool) {
        let command = nextCommand()
        lock.withLock { _isFading = false }
        perform("play") { [self] in
            guard isLatest(command) else { return }
            cancelFade()
            if urgent { emergencyAudio.begin() } else { emergencyAudio.end() }
            if activeSelection != selection || activeWantsGapless != gapless {
                activeSound?.stop()
                activeSound = makeSound(selection, gapless, queue)
                activeSelection = selection
                activeWantsGapless = gapless
            }
            guard let activeSound else {
                NSSound.beep()
                return
            }
            activeSound.volume = volume
            if loops && activeSound.isPlaying && activeSound.loops { return }
            activeSound.stop()
            activeSound.loops = loops
            activeSound.play()
        }
    }

    /// 少しずつ音を小さくして止める。止めたあとは音量を `restoreVolume` に戻しておく。
    func fadeOut(duration: TimeInterval = 0.45, restoreVolume: Float) {
        let command = nextCommand()
        lock.withLock { _isFading = true }
        perform("fadeOut") { [self] in
            guard isLatest(command) else { return }
            cancelFade()
            guard let sound = activeSound, sound.isPlaying else {
                emergencyAudio.end()
                finishFade(command)
                return
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let startingVolume = sound.volume
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { [weak self, weak sound] in
                guard let self else { return }
                guard let sound, self.isLatest(command) else {
                    self.cancelFade()
                    return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / duration)
                sound.volume = Float(Double(startingVolume) * (1 - progress))
                guard progress >= 1 else { return }
                self.cancelFade()
                sound.stop()
                sound.loops = false
                sound.volume = restoreVolume
                self.emergencyAudio.end()
                // すき間なしループ用の部品は曲全体を展開して持つ（70秒で約27MB）。
                // 鳴らし終えたら手放し、次に鳴らすときに読み直す。
                if sound is GaplessLoopPlayer {
                    self.activeSound = nil
                    self.activeSelection = nil
                }
                self.finishFade(command)
            }
            fadeTimer = timer
            timer.resume()
        }
    }

    /// 鳴っている音の音量を変える。溜まったときは最新の値だけを使う。
    func setVolume(_ volume: Float) {
        let isFirst = lock.withLock { () -> Bool in
            defer { pendingVolume = volume }
            return pendingVolume == nil
        }
        guard isFirst else { return }
        perform("setVolume") { [self] in
            let volume = lock.withLock { () -> Float? in
                defer { pendingVolume = nil }
                return pendingVolume
            }
            guard let volume, fadeTimer == nil else { return }
            activeSound?.volume = volume
        }
    }

    /// 終了時に、地震の音のために解いた消音を戻す。音声サービスが応答しなければ待ちきらずに諦める。
    @discardableResult
    func restoreSystemOutput(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            emergencyAudio.end()
            done.signal()
        }
        let finished = done.wait(timeout: .now() + timeout) == .success
        if !finished { tickerLog.error("sound: audio service did not respond while quitting") }
        return finished
    }

    private func nextCommand() -> Int {
        lock.withLock {
            latestCommand += 1
            return latestCommand
        }
    }

    private func isLatest(_ command: Int) -> Bool {
        lock.withLock { latestCommand == command }
    }

    private func finishFade(_ command: Int) {
        lock.withLock { if latestCommand == command { _isFading = false } }
    }

    private func cancelFade() {
        fadeTimer?.cancel()
        fadeTimer = nil
    }

    /// queue で実行し、時間がかかりすぎたら記録する。
    private func perform(_ name: String, _ work: @escaping () -> Void) {
        queue.async {
            let started = ProcessInfo.processInfo.systemUptime
            work()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed > Self.stallThreshold {
                tickerLog.error("sound: \(name, privacy: .public) took \(elapsed, format: .fixed(precision: 1), privacy: .public)s (audio service slow?)")
            }
        }
    }

    static func makeSystemSound(selection: String, gapless: Bool, queue: DispatchQueue) -> NotificationSoundPlaying? {
        if selection.hasPrefix("file:") {
            let path = String(selection.dropFirst("file:".count))
            if gapless, let player = GaplessLoopPlayer(url: URL(fileURLWithPath: path), callbackQueue: queue) {
                return player
            }
            return NSSound(contentsOfFile: path, byReference: true)
        }
        let name = String(selection.dropFirst("system:".count))
        return NSSound(named: NSSound.Name(name))
    }
}

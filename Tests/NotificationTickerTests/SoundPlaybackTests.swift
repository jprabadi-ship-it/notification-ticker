import XCTest
@testable import NotificationTicker

/// 本物の音の代わり。鳴らした記録だけを残す。
private final class FakeSound: NotificationSoundPlaying {
    let selection: String
    var volume: Float = 1
    var isPlaying = false
    var loops = false
    var playCount = 0
    init(selection: String) { self.selection = selection }
    func play() -> Bool { isPlaying = true; playCount += 1; return true }
    func stop() -> Bool { isPlaying = false; return true }
}

private final class FakeOutput: SystemOutputControlling {
    var isMuted: Bool? = false
    var volume: Float? = 1
}

final class SoundPlaybackTests: XCTestCase {
    /// 音声サービスが応答しない状態をまねる。gate が開くまで、音の部品を作る処理が戻らない。
    private func makeBlockedPlayback(gate: DispatchSemaphore, made: @escaping (FakeSound) -> Void) -> SoundPlayback {
        SoundPlayback(
            emergencyAudio: EmergencyAudioOverride(output: FakeOutput()),
            makeSound: { selection, _, _ in
                gate.wait()
                gate.signal()
                let sound = FakeSound(selection: selection)
                made(sound)
                return sound
            }
        )
    }

    private func drain(_ playback: SoundPlayback) {
        playback.queue.sync {}
    }

    func testCallerDoesNotWaitWhileAudioServiceIsStuck() {
        let gate = DispatchSemaphore(value: 0)
        let playback = makeBlockedPlayback(gate: gate) { _ in }
        let started = Date()
        playback.play(selection: "system:Glass", loops: true, gapless: false, volume: 0.5, urgent: false)
        playback.setVolume(0.3)
        playback.fadeOut(duration: 0.01, restoreVolume: 0.5)
        playback.play(selection: "system:Ping", loops: false, gapless: false, volume: 0.5, urgent: false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "頼むだけで、すぐ戻る")
        gate.signal()
        drain(playback)
    }

    func testOnlyLatestRequestRunsAfterStall() {
        // 一件目で詰まっている間に頼まれた音は、最後の一つだけ鳴らす。
        let gate = DispatchSemaphore(value: 0)
        var made: [FakeSound] = []
        let playback = makeBlockedPlayback(gate: gate) { made.append($0) }
        playback.play(selection: "system:Glass", loops: false, gapless: false, volume: 0.5, urgent: false)
        // 一件目が queue に乗るのを待つ。
        Thread.sleep(forTimeInterval: 0.05)
        for name in ["Ping", "Pop", "Tink", "Hero"] {
            playback.play(selection: "system:\(name)", loops: false, gapless: false, volume: 0.5, urgent: false)
        }
        gate.signal()
        drain(playback)
        XCTAssertEqual(made.map(\.selection), ["system:Glass", "system:Hero"])
        XCTAssertEqual(made.last?.playCount, 1)
    }

    func testLoopingSameSoundIsNotRestarted() {
        var made: [FakeSound] = []
        let playback = SoundPlayback(
            emergencyAudio: EmergencyAudioOverride(output: FakeOutput()),
            makeSound: { selection, _, _ in
                let sound = FakeSound(selection: selection)
                made.append(sound)
                return sound
            }
        )
        playback.play(selection: "system:Glass", loops: true, gapless: false, volume: 0.5, urgent: false)
        drain(playback)
        playback.play(selection: "system:Glass", loops: true, gapless: false, volume: 0.7, urgent: false)
        drain(playback)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made.first?.playCount, 1, "ループ中の同じ音は鳴らし直さない")
        XCTAssertEqual(made.first?.volume, 0.7)
    }

    func testFadeOutStopsAndRestoresVolume() {
        var made: [FakeSound] = []
        let playback = SoundPlayback(
            emergencyAudio: EmergencyAudioOverride(output: FakeOutput()),
            makeSound: { selection, _, _ in
                let sound = FakeSound(selection: selection)
                made.append(sound)
                return sound
            }
        )
        playback.play(selection: "system:Glass", loops: true, gapless: false, volume: 0.9, urgent: false)
        // 鳴り始める前に止めると、鳴らす頼みは飛ばされる（最後の頼みだけ行う）。鳴るのを待つ。
        drain(playback)
        XCTAssertEqual(made.first?.isPlaying, true)
        playback.fadeOut(duration: 0.05, restoreVolume: 0.4)
        XCTAssertTrue(playback.isFading)
        let finished = expectation(description: "フェードが終わる")
        func check() {
            playback.queue.asyncAfter(deadline: .now() + 0.02) {
                if made.first?.isPlaying == false { finished.fulfill() } else { check() }
            }
        }
        check()
        wait(for: [finished], timeout: 2)
        drain(playback)
        XCTAssertEqual(made.first?.volume, 0.4)
        XCTAssertFalse(playback.isFading)
    }

    func testUrgentSoundUnmutesAndFadeRestores() {
        let output = FakeOutput()
        output.isMuted = true
        let playback = SoundPlayback(
            emergencyAudio: EmergencyAudioOverride(output: output),
            makeSound: { selection, _, _ in FakeSound(selection: selection) }
        )
        playback.play(selection: "system:Glass", loops: true, gapless: false, volume: 0.8, urgent: true)
        drain(playback)
        XCTAssertEqual(output.isMuted, false)
        playback.fadeOut(duration: 0.01, restoreVolume: 0.5)
        let restored = expectation(description: "消音に戻る")
        func check() {
            playback.queue.asyncAfter(deadline: .now() + 0.02) {
                if output.isMuted == true { restored.fulfill() } else { check() }
            }
        }
        check()
        wait(for: [restored], timeout: 2)
    }

    func testStopRequestedBeforeStartSkipsPlaying() {
        // 詰まっている間に「鳴らす→止める」と頼まれたら、鳴らさずに終える。
        var made: [FakeSound] = []
        let playback = SoundPlayback(
            emergencyAudio: EmergencyAudioOverride(output: FakeOutput()),
            makeSound: { selection, _, _ in
                let sound = FakeSound(selection: selection)
                made.append(sound)
                return sound
            }
        )
        playback.queue.suspend()
        playback.play(selection: "system:Glass", loops: true, gapless: false, volume: 0.9, urgent: false)
        playback.fadeOut(duration: 0.01, restoreVolume: 0.4)
        playback.queue.resume()
        drain(playback)
        XCTAssertTrue(made.isEmpty)
        XCTAssertFalse(playback.isFading)
    }

    func testRestoreGivesUpWhenAudioServiceIsStuck() {
        let gate = DispatchSemaphore(value: 0)
        let playback = makeBlockedPlayback(gate: gate) { _ in }
        playback.play(selection: "system:Glass", loops: false, gapless: false, volume: 0.5, urgent: false)
        let started = Date()
        XCTAssertFalse(playback.restoreSystemOutput(timeout: 0.1), "終了処理は待ちきらずに進む")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        gate.signal()
        drain(playback)
    }
}

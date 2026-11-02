import AppKit
import XCTest
@testable import NotificationTicker

/// 本物の出力装置の代わり。テストで Mac の音量を変えないため。
private final class FakeOutput: SystemOutputControlling {
    var isMuted: Bool?
    var volume: Float?
    init(isMuted: Bool?, volume: Float?) {
        self.isMuted = isMuted
        self.volume = volume
    }
}

final class EmergencyAudioTests: XCTestCase {
    func testUnmutesWhileSoundingAndRestoresAfterwards() {
        let output = FakeOutput(isMuted: true, volume: 0.9)
        let override = EmergencyAudioOverride(output: output)
        override.begin()
        XCTAssertEqual(output.isMuted, false)
        XCTAssertEqual(output.volume, 0.9, "十分な音量は変えない")
        override.end()
        XCTAssertEqual(output.isMuted, true)
        XCTAssertFalse(override.isActive)
    }

    func testRaisesHalfVolumeToEightyPercentDuringEarthquake() {
        // 普段の 50% は、地震の間だけ 80% にして、終われば 50% に戻す。
        let output = FakeOutput(isMuted: false, volume: 0.5)
        let override = EmergencyAudioOverride(output: output)
        override.begin()
        XCTAssertEqual(output.volume, 0.8)
        override.end()
        XCTAssertEqual(output.volume, 0.5)
    }

    func testRaisesTooQuietVolumeAndRestoresIt() {
        let output = FakeOutput(isMuted: false, volume: 0.05)
        let override = EmergencyAudioOverride(output: output)
        override.begin()
        XCTAssertEqual(output.volume, EmergencyAudioOverride.minimumVolume)
        XCTAssertEqual(output.isMuted, false)
        override.end()
        XCTAssertEqual(output.volume, 0.05)
    }

    func testLeavesNormalStateUntouched() {
        let output = FakeOutput(isMuted: false, volume: 0.85)
        let override = EmergencyAudioOverride(output: output)
        override.begin()
        XCTAssertFalse(override.isActive)
        override.end()
        XCTAssertEqual(output.isMuted, false)
        XCTAssertEqual(output.volume, 0.85)
    }

    func testRespectsUserChangesMadeWhileSounding() {
        let output = FakeOutput(isMuted: true, volume: 0.1)
        let override = EmergencyAudioOverride(output: output)
        override.begin()
        // 鳴っている間に利用者が自分で音量を変え、消音し直した。
        output.volume = 1.0
        output.isMuted = true
        override.end()
        XCTAssertEqual(output.volume, 1.0, "利用者の操作を上書きしない")
        XCTAssertEqual(output.isMuted, true)
    }

    func testBeginTwiceKeepsOriginalState() {
        let output = FakeOutput(isMuted: true, volume: 0.1)
        let override = EmergencyAudioOverride(output: output)
        override.begin()
        override.begin()
        override.end()
        XCTAssertEqual(output.isMuted, true)
        XCTAssertEqual(output.volume, 0.1)
    }

    func testDevicesWithoutMuteOrVolumeAreIgnored() {
        let output = FakeOutput(isMuted: nil, volume: nil)
        let override = EmergencyAudioOverride(output: output)
        override.begin()
        XCTAssertFalse(override.isActive)
        override.end()
        XCTAssertNil(output.isMuted)
        XCTAssertNil(output.volume)
    }

    func testCoreAudioOutputCanBeRead() {
        // 読むだけ。値は環境次第なので、範囲だけ確かめる。
        let output = CoreAudioOutput()
        if let volume = output.volume {
            XCTAssertGreaterThanOrEqual(volume, 0)
            XCTAssertLessThanOrEqual(volume, 1)
        }
    }

    @MainActor
    func testTickerReportsUrgencyOfLeadingSound() {
        let view = TickerView(frame: NSRect(x: 0, y: 0, width: 800, height: 60), settings: TickerSettings())
        var reports: [(String?, Bool)] = []
        view.onLeadingSoundChange = { selection, _, urgent in reports.append((selection, urgent)) }

        view.enqueue("地震のテスト", soundSelection: "system:Glass", urgentSound: true)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0, "system:Glass")
        XCTAssertEqual(reports.first?.1, true)
        XCTAssertTrue(view.leadingSoundIsUrgent)

        // 後ろに並んだ普通の項目では、先頭は替わらない。
        view.enqueue("普通の通知", soundSelection: "system:Glass")
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(view.leadingSoundIsUrgent)
    }

    @MainActor
    func testUrgencyAloneChangesLeadingSoundReport() {
        // 地震の音が共通の通知音と同じでも、緊急かどうかが変われば知らせる。
        let view = TickerView(frame: NSRect(x: 0, y: 0, width: 800, height: 60), settings: TickerSettings())
        var urgencies: [Bool] = []
        view.onLeadingSoundChange = { _, _, urgent in urgencies.append(urgent) }
        view.enqueue("普通の通知", soundSelection: nil)
        view.clear()
        view.enqueue("地震のテスト", soundSelection: nil, urgentSound: true)
        XCTAssertEqual(urgencies, [false, true])
    }
}

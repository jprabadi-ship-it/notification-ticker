import AVFoundation
import XCTest
@testable import NotificationTicker

final class GaplessLoopPlayerTests: XCTestCase {
    func testAudibleRangeSkipsLeadingAndTrailingSilence() {
        let samples: [Float] = [0, 0.001, 0.2, 0.5, 0.0005, 0.3, 0.002, 0, 0]
        let range = GaplessLoopPlayer.audibleFrameRange(frameCount: samples.count) { samples[$0] }
        // 途中の小さな値（0.0005）は曲の一部なので残し、両端の無音だけを落とす。
        XCTAssertEqual(range, 2..<6)
    }

    func testAudibleRangeIsNilForSilence() {
        XCTAssertNil(GaplessLoopPlayer.audibleFrameRange(frameCount: 4) { _ in 0 })
        XCTAssertNil(GaplessLoopPlayer.audibleFrameRange(frameCount: 0) { _ in 1 })
    }

    func testLoadTrimmedBufferDropsSilenceAtBothEnds() throws {
        // 0.5 秒の無音 + 1 秒の 440Hz + 1.25 秒の無音（経済ニュース速報の末尾と同じくらい）。
        let rate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let lead = Int(rate * 0.5), tone = Int(rate * 1.0), tail = Int(rate * 1.25)
        let total = lead + tone + tail
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
        buffer.frameLength = AVAudioFrameCount(total)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for index in 0..<total {
                let inTone = index >= lead && index < lead + tone
                // 振幅が閾値を超える最初のサンプルから数えられるよう、位相 0 から始まる正弦波を
                // 0.5 振幅で置く。
                data[channel][index] = inTone ? 0.5 * sin(Float(index - lead) * 2 * .pi * 440 / Float(rate)) : 0
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gapless-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let trimmed = try XCTUnwrap(GaplessLoopPlayer.loadTrimmedBuffer(url: url))
        let seconds = Double(trimmed.frameLength) / rate
        // 正弦波の最初と最後の数サンプルは振幅が閾値未満なので、1 秒よりわずかに短くなる。
        XCTAssertEqual(seconds, 1.0, accuracy: 0.002, "無音を落として音の部分だけになる")
        XCTAssertEqual(trimmed.format.channelCount, 2)
    }

    func testPlayerRejectsUnreadableFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        FileManager.default.createFile(atPath: url.path, contents: Data("not audio".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(GaplessLoopPlayer(url: url), "読めないファイルは NSSound に任せる")
    }
}

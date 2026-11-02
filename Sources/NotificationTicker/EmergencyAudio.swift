import AudioToolbox
import CoreAudio
import Foundation

/// Mac 本体の出力装置の消音と音量。テストで差し替えられるよう抽象化する。
/// nil は「その装置では扱えない」（HDMI 出力など、消音や音量を持たない装置がある）。
protocol SystemOutputControlling: AnyObject {
    var isMuted: Bool? { get set }
    var volume: Float? { get set }
}

/// 地震の音を鳴らしている間だけ、Mac 本体の消音・小さすぎる音量を一時的に解く。
/// 鳴り終えたら元に戻す。ただし途中で利用者が自分で変えていたら、その操作を優先して戻さない。
final class EmergencyAudioOverride {
    /// これ未満の音量なら、鳴らす間だけこの値まで上げる（80%）。
    static let minimumVolume: Float = 0.8

    private let output: SystemOutputControlling
    /// こちらが消音を解いたときだけ true。
    private var didUnmute = false
    /// こちらが音量を上げたときだけ、上げる前の値。
    private var volumeBeforeRaise: Float?

    var isActive: Bool { didUnmute || volumeBeforeRaise != nil }

    init(output: SystemOutputControlling) {
        self.output = output
    }

    func begin() {
        guard !isActive else { return }
        if output.isMuted == true {
            output.isMuted = false
            didUnmute = output.isMuted == false
        }
        if let volume = output.volume, volume < Self.minimumVolume {
            output.volume = Self.minimumVolume
            if let raised = output.volume, abs(raised - Self.minimumVolume) < 0.02 {
                volumeBeforeRaise = volume
            }
        }
        if isActive {
            tickerLog.notice("emergency audio: unmute=\(self.didUnmute, privacy: .public) raised=\(self.volumeBeforeRaise != nil, privacy: .public)")
        }
    }

    func end() {
        guard isActive else { return }
        if let previous = volumeBeforeRaise,
           let current = output.volume,
           abs(current - Self.minimumVolume) < 0.02 {
            output.volume = previous
        }
        if didUnmute, output.isMuted == false {
            output.isMuted = true
        }
        didUnmute = false
        volumeBeforeRaise = nil
    }
}

/// 既定の出力装置を CoreAudio で操作する。装置は切り替わることがあるので毎回取り直す。
final class CoreAudioOutput: SystemOutputControlling {
    var isMuted: Bool? {
        get {
            guard let device = Self.defaultOutputDevice(),
                  let value: UInt32 = Self.read(device, Self.muteAddress) else { return nil }
            return value != 0
        }
        set {
            guard let newValue, let device = Self.defaultOutputDevice() else { return }
            Self.write(device, Self.muteAddress, UInt32(newValue ? 1 : 0))
        }
    }

    var volume: Float? {
        get {
            guard let device = Self.defaultOutputDevice(),
                  let value: Float32 = Self.read(device, Self.volumeAddress) else { return nil }
            return value
        }
        set {
            guard let newValue, let device = Self.defaultOutputDevice() else { return }
            Self.write(device, Self.volumeAddress, Float32(min(max(newValue, 0), 1)))
        }
    }

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private static func read<T: BitwiseCopyable>(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> T? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func write<T: BitwiseCopyable>(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress, _ newValue: T) {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return }
        var value = newValue
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value
        )
        if status != noErr {
            tickerLog.error("emergency audio: set property failed \(status, privacy: .public)")
        }
    }
}

import CoreAudio
import Foundation

/// Observes whether the default input device reports itself muted. Some USB
/// microphones omit this CoreAudio property; those deliberately stay silent.
final class MicrophoneProvider {
    var onMuteChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var lastMuted: Bool?

    func start() {
        refresh(publishChanges: false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh(publishChanges: true)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func isMuted() -> Bool? {
        guard let device = defaultInputDeviceID() else { return nil }
        for element: UInt32 in [0, kAudioObjectPropertyElementMain] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { continue }
            return muted != 0
        }
        return nil
    }

    private func refresh(publishChanges: Bool) {
        let muted = isMuted()
        defer { lastMuted = muted }
        guard publishChanges, let muted, muted != lastMuted else { return }
        onMuteChanged?(muted)
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}

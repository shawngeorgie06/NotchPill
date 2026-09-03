import AppKit
import Combine
import CoreAudio

/// One device the system can send sound to.
struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    /// A `kAudioDevicePropertyTransportType` value, kept so the menu can show
    /// what kind of thing this is without parsing its name.
    let transport: UInt32

    /// The symbol that says how the sound gets there.
    ///
    /// Names are unreliable for this -- "MacBook Pro Speakers" and a pair of
    /// headphones called "MacBook" are indistinguishable -- so it goes by the
    /// transport the driver reports.
    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "airpods"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return "hifispeaker"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return "speaker.wave.2"
        }
    }
}

/// The list of output devices, and which one the system is using.
///
/// This is a mirror of CoreAudio rather than a poller: the hardware tells us
/// when a device appears, disappears, or becomes the default, and those are
/// the only three moments the list can change. Polling a device list once a
/// second to catch an event that happens twice a day is the wrong trade.
@MainActor
final class AudioOutputStore: ObservableObject {
    static let shared = AudioOutputStore()

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var currentID: AudioDeviceID?

    var current: AudioOutputDevice? {
        devices.first { $0.id == currentID }
    }

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {}

    func start() {
        guard listeners.isEmpty else { return }
        refresh()
        listen(kAudioHardwarePropertyDevices)
        listen(kAudioHardwarePropertyDefaultOutputDevice)
    }

    func stop() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block
            )
        }
        listeners = []
    }

    /// Makes `device` the system output.
    ///
    /// Nothing is published here: the default-device listener fires either way,
    /// so trusting the write and updating optimistically would only invent a
    /// state that disagrees with CoreAudio when the write is refused.
    func select(_ device: AudioOutputDevice) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        if status != noErr {
            LogStore.log("audio", "could not switch to \(device.name): OSStatus \(status)")
        }
    }

    func refresh() {
        devices = Self.outputDevices()
        currentID = Self.defaultOutputDeviceID()
    }

    private func listen(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        )
        guard status == noErr else { return }
        listeners.append((address, block))
    }

    // MARK: - CoreAudio

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            // Every input device is in this list too; a device with no output
            // channels is a microphone, not somewhere to send sound.
            guard hasOutputChannels(id), let name = name(of: id) else { return nil }
            return AudioOutputDevice(id: id, name: name, transport: transport(of: id))
        }
    }

    private static func hasOutputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        // AudioBufferList is variable-length, so it has to be read into raw
        // memory sized by the property rather than into a fixed struct.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name = name as String? , !name.isEmpty else { return nil }
        return name
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }
}

import AppKit
import CoreAudio
import Foundation

/// Controls macOS **system output volume** (menu-bar speaker level).
final class VolumeProvider {
    private let stepScalar: Float = 0.0625
    private let stepPercent = 6
    var onVolumeChanged: ((Int) -> Void)?

    private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_766C
    private static let logVolume = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    func start() {}

    func volumeUp() {
        applyChange(up: true)
    }

    func volumeDown() {
        applyChange(up: false)
    }

    func currentVolume() -> Int? {
        guard let device = defaultOutputDeviceID(),
              let scalar = readOutputVolumeScalar(for: device) else {
            return readVolumeViaAppleScript()
        }
        return level(from: scalar)
    }

    private func applyChange(up: Bool) {
        // Step off the keyboard-event path before touching audio / HID.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.applyChangeNow(up: up)
        }
    }

    private func applyChangeNow(up: Bool) {
        if Self.logVolume { print("VOL apply \(up ? "up" : "down")") }

        if let device = defaultOutputDeviceID(), let current = readOutputVolumeScalar(for: device) {
            let next = min(max(current + (up ? stepScalar : -stepScalar), 0), 1)
            if writeOutputVolumeScalar(next, to: device) {
                publish(level: level(from: next))
                return
            }
        }

        if let current = readVolumeViaAppleScript() {
            let next = min(max(current + (up ? stepPercent : -stepPercent), 0), 100)
            if writeVolumeViaAppleScript(next) {
                publish(level: next)
                return
            }
        }

        postSystemVolumeKey(up: up)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let level = self.currentVolume() else { return }
            self.publish(level: level)
        }
    }

    private func publish(level: Int) {
        if Self.logVolume { print("VOL level \(level)") }
        onVolumeChanged?(level)
    }

    // MARK: - CoreAudio

    private func level(from scalar: Float) -> Int {
        Int((min(max(scalar, 0), 1) * 100).rounded())
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

    private func readOutputVolumeScalar(for deviceID: AudioDeviceID) -> Float? {
        for selector in [virtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            for element: UInt32 in [0, kAudioObjectPropertyElementMain] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                var volume = Float32(0)
                var size = UInt32(MemoryLayout<Float32>.size)
                let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
                if status == noErr { return min(max(volume, 0), 1) }
            }
        }
        return nil
    }

    @discardableResult
    private func writeOutputVolumeScalar(_ value: Float, to deviceID: AudioDeviceID) -> Bool {
        let clamped = min(max(value, 0), 1)
        var volume = Float32(clamped)
        let size = UInt32(MemoryLayout<Float32>.size)
        for selector in [virtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            for element: UInt32 in [0, kAudioObjectPropertyElementMain] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - AppleScript fallback

    private func readVolumeViaAppleScript() -> Int? {
        guard let text = runOsascript("output volume of (get volume settings)"), let level = Int(text) else {
            return nil
        }
        return level
    }

    @discardableResult
    private func writeVolumeViaAppleScript(_ level: Int) -> Bool {
        runOsascript("set volume output volume \(level)") != nil
    }

    @discardableResult
    private func runOsascript(_ source: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : "ok"
    }

    // MARK: - Native volume-key fallback (shows Apple HUD)

    private func postSystemVolumeKey(up: Bool) {
        let key = up ? 0 : 1
        for data1 in [(key << 16) | (0x0A << 8), (key << 16) | (0x0B << 8)] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ), let cgEvent = event.cgEvent else { continue }
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}

import AppKit

/// Reads and adjusts system output volume via AppleScript.
final class VolumeProvider {
    private let step = 6
    var onVolumeChanged: ((Int) -> Void)?

    @discardableResult
    func volumeUp() -> Int? {
        adjust(by: step)
    }

    @discardableResult
    func volumeDown() -> Int? {
        adjust(by: -step)
    }

    func currentVolume() -> Int? {
        let source = "output volume of (get volume settings)"
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              error == nil else { return nil }
        return Int(result.int32Value)
    }

    @discardableResult
    private func adjust(by delta: Int) -> Int? {
        let source = """
        set currentVol to output volume of (get volume settings)
        set newVol to currentVol + \(delta)
        if newVol > 100 then set newVol to 100
        if newVol < 0 then set newVol to 0
        set volume output volume newVol
        return newVol
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              error == nil else { return nil }
        let level = Int(result.int32Value)
        DispatchQueue.main.async { [weak self] in self?.onVolumeChanged?(level) }
        return level
    }
}

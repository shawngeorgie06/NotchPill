import Foundation
import IOKit.graphics

/// Observes the brightness of a display that exposes macOS's public IOKit
/// brightness parameter. External displays often do not, so absence is normal.
final class BrightnessProvider {
    var onBrightnessChanged: ((Int) -> Void)?

    private var timer: Timer?
    private var lastLevel: Int?

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

    func currentBrightness() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }

            var value: Float = 0
            let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value)
            guard result == kIOReturnSuccess else { continue }
            return Self.percent(from: value)
        }
    }

    private func refresh(publishChanges: Bool) {
        let level = currentBrightness()
        defer { lastLevel = level }
        guard publishChanges, let level, level != lastLevel else { return }
        onBrightnessChanged?(level)
    }

    static func percent(from scalar: Float) -> Int {
        Int((min(max(scalar, 0), 1) * 100).rounded())
    }
}

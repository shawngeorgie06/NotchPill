import Foundation
import IOKit.ps

/// Reads battery percentage and charging state via IOKit power sources, and
/// pushes updates whenever the power source changes (plug/unplug, level).
final class BatteryProvider {
    var onUpdate: ((BatteryInfo?) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?

    func start() {
        // Notify on any power-source change.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let provider = Unmanaged<BatteryProvider>.fromOpaque(ctx).takeUnretainedValue()
            provider.emit()
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        // Periodic refresh so the percentage stays current even without events.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.emit()
        }
        emit()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    private func emit() {
        let info = read()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(info) }
    }

    private func read() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let percent = Int((Double(current) / Double(max) * 100).rounded())
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = (state == kIOPSACPowerValue)
            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            return BatteryInfo(percent: percent, isCharging: isCharging, isPluggedIn: isPluggedIn)
        }
        return nil
    }
}

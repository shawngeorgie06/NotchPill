import Foundation
import IOKit.ps

/// Reads laptop battery level when a power source is available.
final class BatteryProvider {
    var onUpdate: ((BatteryStatus?) -> Void)?

    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.publish()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        publish()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func publish() {
        let status = readBattery()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(status) }
    }

    private func readBattery() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int
            let maxCapacity = description[kIOPSMaxCapacityKey] as? Int
            guard let currentCapacity, let maxCapacity, maxCapacity > 0, maxCapacity < 101 else { continue }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let level = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
            return BatteryStatus(level: min(max(level, 0), 100), isCharging: isCharging)
        }
        return nil
    }
}

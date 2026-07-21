import Foundation
import Darwin

/// Polls CPU and memory usage for system stat cards.
final class SystemStatsProvider {
    var onUpdate: ((SystemStats?) -> Void)?

    private var timer: Timer?
    private var lastCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let stats = SystemStats(cpuPercent: readCPUPercent(), memoryPercent: readMemoryPercent())
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(stats) }
    }

    private func readMemoryPercent() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let usedPages = Double(stats.active_count + stats.inactive_count + stats.wire_count)
        let totalPages = usedPages + Double(stats.free_count)
        guard totalPages > 0 else { return 0 }
        return Int((usedPages / totalPages * 100.0).rounded())
    }

    private func readCPUPercent() -> Int {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let ticks = (
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )

        guard let previous = lastCPUTicks else {
            lastCPUTicks = ticks
            return 0
        }

        let user = Double(ticks.user &- previous.user)
        let system = Double(ticks.system &- previous.system)
        let idle = Double(ticks.idle &- previous.idle)
        let nice = Double(ticks.nice &- previous.nice)
        let total = user + system + idle + nice
        lastCPUTicks = ticks
        guard total > 0 else { return 0 }
        return Int(((user + system + nice) / total * 100.0).rounded())
    }
}

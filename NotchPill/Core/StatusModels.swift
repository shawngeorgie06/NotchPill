import Foundation

struct SystemStats: Equatable {
    var cpuPercent: Int
    var memoryPercent: Int
}

struct BatteryStatus: Equatable {
    var level: Int
    var isCharging: Bool
}

struct ActiveTimer: Equatable {
    var label: String
    var endDate: Date

    /// Focus sessions are still ordinary timers, but carry a stable semantic
    /// label so every surface can use the focused visual treatment.
    var isFocusSession: Bool { label == "Focus" }

    func remaining(at date: Date = Date()) -> TimeInterval {
        max(0, endDate.timeIntervalSince(date))
    }

    var isActive: Bool { remaining() > 0 }
}

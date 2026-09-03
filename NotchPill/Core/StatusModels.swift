import Foundation

struct SystemStats: Equatable {
    var cpuPercent: Int
    var memoryPercent: Int
}

struct BatteryStatus: Equatable {
    var level: Int
    var isCharging: Bool
    /// Whether macOS is in Low Power Mode. Readable from any process; only
    /// root can change it, which is why the card offers a shortcut to the
    /// Battery settings pane rather than a switch of its own.
    var isLowPower: Bool = false
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

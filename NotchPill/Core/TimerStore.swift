import Foundation
import Combine

/// Simple countdown timer surfaced in the notch.
@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    @Published private(set) var active: ActiveTimer?

    private var tickTimer: Timer?

    var isActive: Bool { active?.isActive == true }

    private init() {}

    func start(minutes: Int, label: String = "Timer") {
        active = ActiveTimer(label: label, endDate: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        startTicking()
    }

    func cancel() {
        active = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.active?.isActive != true {
                self.active = nil
                self.tickTimer?.invalidate()
                self.tickTimer = nil
            }
            self.objectWillChange.send()
        }
        if let tickTimer {
            RunLoop.main.add(tickTimer, forMode: .common)
        }
    }
}

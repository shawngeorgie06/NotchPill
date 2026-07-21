import AppKit

/// Detects pointer hover over the notch hot zone using the live cursor position.
///
/// The overlay window sits below the menu bar so status items stay clickable;
/// that means AppKit tracking areas on the window never see events in the notch
/// band. Polling `NSEvent.mouseLocation` against the hot-zone screen rect fixes
/// that without stealing menu bar clicks.
@MainActor
final class HoverMonitor {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    /// Fired every tick with whether the pointer is inside the shortcut/hover zone.
    var onTick: ((Bool) -> Void)?

    /// Screen-coordinate rect (AppKit bottom-left origin) of the interactive zone.
    var hotZoneScreenRect: () -> CGRect = { .zero }

    private var timer: Timer?
    private var isInside = false
    private var insideTicks = 0
    private var outsideTicks = 0

    /// Consecutive poll ticks required before toggling expand/collapse (not shortcuts).
    private let enterTicksRequired = 2
    private let exitTicksRequired = 4

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        insideTicks = 0
        outsideTicks = 0
        if isInside {
            isInside = false
            onExit()
        }
        onTick?(false)
    }

    private func tick() {
        let rect = hotZoneScreenRect()
        guard rect.width > 0, rect.height > 0 else { return }

        let mouse = NSEvent.mouseLocation
        // Generous zone for shortcut arming — independent of expand/collapse hysteresis.
        let shortcutZone = rect.insetBy(dx: -16, dy: -10).contains(mouse)
        // Keep shortcuts armed while inside the hover session, not only on tight edge ticks.
        onTick?(shortcutZone || isInside)

        // Tighter hysteresis only drives expand/collapse so the pill doesn't flutter.
        let insideForEnter = rect.insetBy(dx: -12, dy: -8).contains(mouse)
        let insideForExit = rect.insetBy(dx: -4, dy: -2).contains(mouse)
        let inside = isInside ? insideForExit : insideForEnter

        if inside {
            outsideTicks = 0
            insideTicks += 1
            if !isInside, insideTicks >= enterTicksRequired {
                isInside = true
                onEnter()
            }
        } else {
            insideTicks = 0
            outsideTicks += 1
            if isInside, outsideTicks >= exitTicksRequired {
                isInside = false
                onExit()
            }
        }
    }
}

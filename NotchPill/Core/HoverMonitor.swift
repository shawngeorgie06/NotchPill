import AppKit

/// Detects pointer hover over the notch hot zone using the live cursor position.
///
/// Expansion is limited to the physical notch column (not browser tab flanks).
/// Hover is detected via screen-space polling so the overlay can pass clicks through.
@MainActor
final class HoverMonitor {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    /// Fired every tick with whether keyboard shortcuts should arm.
    var onTick: ((Bool) -> Void)?

    /// Screen-coordinate rect that may trigger expand/collapse.
    var expandZoneScreenRect: () -> CGRect = { .zero }
    /// When true, the pointer is over browser tabs — never expand or arm shortcuts.
    var pointBlocksHover: (NSPoint) -> Bool = { _ in false }

    private var timer: Timer?
    private var isInside = false
    private var insideTicks = 0
    private var outsideTicks = 0

    /// Consecutive poll ticks required before toggling expand/collapse (not shortcuts).
    private let enterTicksRequired = 2
    private let exitTicksRequired = 3

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
        let mouse = NSEvent.mouseLocation

        if pointBlocksHover(mouse) {
            onTick?(false)
            insideTicks = 0
            if isInside {
                outsideTicks = exitTicksRequired
                isInside = false
                onExit()
            }
            return
        }

        let rect = expandZoneScreenRect()
        guard rect.width > 0, rect.height > 0 else { return }

        let shortcutZone = rect.insetBy(dx: -12, dy: -8).contains(mouse)
        onTick?(shortcutZone || isInside)

        let insideForEnter = rect.insetBy(dx: -6, dy: -4).contains(mouse)
        let insideForExit = rect.insetBy(dx: -2, dy: -1).contains(mouse)
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

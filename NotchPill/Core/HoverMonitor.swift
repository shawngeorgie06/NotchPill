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

    /// Poll rate while the pointer is anywhere near the notch, or the pill is
    /// open. Hover has to feel instant, so this stays at display rate.
    private static let activeInterval: TimeInterval = 0.016
    /// Poll rate when the pointer is nowhere near. Measured: the 60Hz poll was
    /// most of NotchPill's idle CPU, and it was spending it deciding, sixty
    /// times a second, that the mouse is still on the other side of the screen.
    private static let idleInterval: TimeInterval = 0.1
    /// How far outside the hover zone still counts as "near" — generous, so the
    /// rate is already back up before the pointer arrives. A fast mouse covers
    /// ~2000pt/s, so 420pt buys ~200ms — two idle polls — of warning.
    private static let nearMargin: CGFloat = 420

    private var currentInterval: TimeInterval = HoverMonitor.activeInterval

    func start() {
        guard timer == nil else { return }
        schedule(interval: Self.activeInterval)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        currentInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-rates the timer as the pointer approaches or leaves. Only swaps it when
    /// the rate actually changes — rescheduling every tick would cost more than
    /// it saves.
    private func adjustRate(mouse: NSPoint, zone: CGRect) {
        let near = zone.insetBy(dx: -Self.nearMargin, dy: -Self.nearMargin).contains(mouse)
        let wanted = (near || isInside) ? Self.activeInterval : Self.idleInterval
        guard wanted != currentInterval else { return }
        schedule(interval: wanted)
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
        adjustRate(mouse: mouse, zone: rect)

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

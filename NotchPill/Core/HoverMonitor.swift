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
    /// Fired every tick with whether the pointer is inside the hot zone.
    var onTick: ((Bool) -> Void)?

    /// Screen-coordinate rect (AppKit bottom-left origin) of the interactive zone.
    var hotZoneScreenRect: () -> CGRect = { .zero }

    private var timer: Timer?
    private var isInside = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
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
        if isInside {
            isInside = false
            onExit()
        }
    }

    private func tick() {
        let rect = hotZoneScreenRect()
        guard rect.width > 0, rect.height > 0 else { return }
        let inside = rect.contains(NSEvent.mouseLocation)
        if inside, !isInside {
            isInside = true
            onEnter()
        } else if !inside, isInside {
            isInside = false
            onExit()
        }
        onTick?(inside)
    }
}

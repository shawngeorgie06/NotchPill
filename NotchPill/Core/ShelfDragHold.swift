import AppKit

/// Keeps the pill open for the length of a shelf drag.
///
/// Dragging a file out means the pointer leaves the pill, which is exactly the
/// gesture that collapses it (`NotchController.handleHoverExit`). Collapsing
/// mid-drag tears the drag image out from under the cursor, so the notch has to
/// be pinned until the drop lands.
///
/// SwiftUI's `.onDrag` reports the start of a drag and nothing else -- there is
/// no completion callback -- so the end is taken from the next mouse-up, which
/// is what actually concludes a drag whether it was dropped or abandoned.
@MainActor
final class ShelfDragHold {
    static let shared = ShelfDragHold()

    private var monitors: [Any] = []
    private var release: ((Bool) -> Void)?

    /// - Parameter hold: the pill's interaction hold, called `true` now and
    ///   `false` when the drag concludes.
    func begin(hold: @escaping (Bool) -> Void) {
        // A second drag before the first resolved: keep the existing hold and
        // let the newer mouse-up end it, rather than stacking monitors.
        guard monitors.isEmpty else { return }
        release = hold
        hold(true)
        LogStore.shelf("drag started — holding notch open")

        // Local catches a mouse-up over our own panel; global catches the far
        // more common case of releasing over Finder. Either concludes it.
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.end()
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.end()
        }
        monitors = [local, global].compactMap { $0 }
    }

    private func end() {
        guard !monitors.isEmpty else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        LogStore.shelf("drag ended — releasing hold")
        // One turn of the run loop: releasing the hold in the same tick as the
        // mouse-up lets the collapse fire before AppKit finishes the drop.
        let release = self.release
        self.release = nil
        DispatchQueue.main.async { release?(false) }
    }
}

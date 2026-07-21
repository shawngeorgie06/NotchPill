import AppKit

/// Hosts the SwiftUI overlay and manages hover detection plus click-through.
///
/// Only the "hot" region reacts to the pointer: the notch rectangle while
/// collapsed, the full pill while expanded. Everywhere else `hitTest` returns
/// nil so clicks pass through to the app underneath.
final class NotchContainerView: NSView {
    var metrics: NotchMetrics {
        didSet { refreshTracking() }
    }
    var isExpandedProvider: () -> Bool = { false }
    var onHotEntered: () -> Void = {}
    var onHotExited: () -> Void = {}
    /// Called when a valid file drag begins/ends hovering the drop area.
    var onDragTargetingChanged: (Bool) -> Void = { _ in }
    /// Called with dropped file URLs.
    var onDropFiles: ([URL]) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?

    init(metrics: NotchMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Hot rect in this view's (non-flipped, bottom-left origin) coordinates.
    /// The notch/pill hug the top edge, centered horizontally.
    private var hotRect: CGRect {
        let w = bounds.width
        let h = bounds.height
        if isExpandedProvider() {
            let pw = min(metrics.expandedWidth, w)
            return CGRect(x: (w - pw) / 2, y: 0, width: pw, height: h)
        } else {
            let nw = metrics.notchWidth
            return CGRect(x: (w - nw) / 2, y: h - metrics.notchHeight,
                          width: nw, height: metrics.notchHeight)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates; convert to ours.
        let local = convert(point, from: superview)
        guard hotRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    /// Rebuilds the single tracking area to match the current hot rect.
    func refreshTracking() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: hotRect,
                                  options: [.activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHotEntered() }
    override func mouseExited(with event: NSEvent) { onHotExited() }

    // MARK: - File drag destination

    /// The footprint that accepts drops: the fully-expanded pill area, so a drag
    /// approaching the notch expands it and reveals the shelf.
    private var dropRect: CGRect {
        let w = bounds.width
        let pw = min(metrics.expandedWidth, w)
        return CGRect(x: (w - pw) / 2, y: 0, width: pw, height: bounds.height)
    }

    private func isFileDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    private func dragInDropZone(_ sender: NSDraggingInfo) -> Bool {
        let local = convert(sender.draggingLocation, from: nil)
        return dropRect.contains(local)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isFileDrag(sender), dragInDropZone(sender) else { return [] }
        onDragTargetingChanged(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isFileDrag(sender) else { return [] }
        let inside = dragInDropZone(sender)
        onDragTargetingChanged(inside)
        return inside ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetingChanged(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isFileDrag(sender) else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: options) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }
}

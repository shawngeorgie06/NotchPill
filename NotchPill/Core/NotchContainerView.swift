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

    private var trackingArea: NSTrackingArea?

    init(metrics: NotchMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
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
}

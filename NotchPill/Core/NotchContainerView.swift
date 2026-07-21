import AppKit

/// Hosts the SwiftUI overlay and manages hover detection plus click-through.
///
/// While collapsed, the window ignores mouse events so clicks reach apps underneath
/// (e.g. browser tabs). Hover is detected via screen-space polling instead.
/// While expanded, only the pill body receives clicks for controls.
final class NotchContainerView: NSView {
    var metrics: NotchMetrics {
        didSet { refreshTracking() }
    }
    var isExpandedProvider: () -> Bool = { false }
    var collapsedContentSizeProvider: () -> CGSize = { .zero }
    var expandedContentSizeProvider: () -> CGSize = { .zero }
    var onHotEntered: () -> Void = {}
    var onHotExited: () -> Void = {}
    var onSpacePressed: () -> Void = {}
    var onDragTargetingChanged: (Bool) -> Void = { _ in }
    var onDropFiles: ([URL]) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?
    private var isHoveringHot = false

    init(metrics: NotchMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Visible pill bounds in local coordinates (bottom-left origin).
    var hotRect: CGRect {
        let w = bounds.width
        let h = bounds.height
        if isExpandedProvider() {
            let size = expandedContentSizeProvider()
            let pw = min(size.width, w)
            // Full window height so the notch band counts as part of the pill.
            return CGRect(x: (w - pw) / 2, y: 0, width: pw, height: h)
        }
        let size = collapsedContentSizeProvider()
        return CGRect(x: (w - size.width) / 2, y: h - size.height,
                      width: size.width, height: size.height)
    }

    func isMouseInHotZone() -> Bool {
        guard let window else { return false }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return hotRect.contains(local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Expanded only: accept clicks on the pill so controls work. Collapsed
        // passes everything through via ignoresMouseEvents on the window.
        guard isExpandedProvider() else { return nil }
        let local = convert(point, from: superview)
        guard hotRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    func refreshTracking() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        // Hover-driven expand/collapse is handled by HoverMonitor (screen coords).
        // Do not sync hover callbacks here — window resizes would spuriously exit.
        isHoveringHot = isMouseInHotZone()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        switch event.keyCode {
        case 49: onSpacePressed()
        default: super.keyDown(with: event)
        }
    }

    private var dropRect: CGRect {
        hotRect
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

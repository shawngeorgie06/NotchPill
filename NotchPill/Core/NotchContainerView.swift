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
    /// Screen-coordinate test for browser tab flanks beside the notch.
    var browserFlankContains: (NSPoint) -> Bool = { _ in false }
    var onHotEntered: () -> Void = {}
    var onHotExited: () -> Void = {}
    var onPillEngaged: () -> Void = {}
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
        pillHitRect()
    }

    private func pillHitRect() -> CGRect {
        let w = bounds.width
        let h = bounds.height
        if isExpandedProvider() {
            return expandedInteractiveUnion()
        }
        let size = collapsedContentSizeProvider()
        return CGRect(x: (w - size.width) / 2, y: h - size.height,
                      width: size.width, height: size.height)
    }

    /// Expanded pill minus the browser tab "ears" beside the physical notch.
    private func expandedInteractiveUnion() -> CGRect {
        interactiveRectsLocal().reduce(CGRect.null) { $0.union($1) }
    }

    /// Regions that receive clicks when expanded. Top corners beside the notch
    /// are excluded so browser tabs stay accessible.
    private func interactiveRectsLocal() -> [CGRect] {
        let w = bounds.width
        let h = bounds.height
        let nw = metrics.notchWidth
        let nh = metrics.notchHeight
        let notchLeft = (w - nw) / 2

        guard isExpandedProvider() else { return [pillHitRect()] }

        let size = expandedContentSizeProvider()
        let pw = min(size.width, w)
        let pillX = (w - pw) / 2
        let body = CGRect(x: pillX, y: 0, width: pw, height: max(0, h - nh))
        let notchColumn = CGRect(x: notchLeft, y: h - nh, width: nw, height: nh)
        return [body, notchColumn]
    }

    private func isInTabEar(at local: NSPoint) -> Bool {
        guard isExpandedProvider() else { return false }
        let w = bounds.width
        let h = bounds.height
        let nw = metrics.notchWidth
        let nh = metrics.notchHeight
        let notchLeft = (w - nw) / 2
        let leftEar = CGRect(x: 0, y: h - nh, width: notchLeft, height: nh)
        let rightEar = CGRect(x: notchLeft + nw, y: h - nh,
                              width: w - (notchLeft + nw), height: nh)
        return leftEar.contains(local) || rightEar.contains(local)
    }

    func isPointOnInteractivePill(_ screenPoint: NSPoint) -> Bool {
        if browserFlankContains(screenPoint) { return false }
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        if isInTabEar(at: local) { return false }
        return interactiveRectsLocal().contains { $0.insetBy(dx: -2, dy: -2).contains(local) }
    }

    func isMouseInHotZone() -> Bool {
        guard let window else { return false }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return hotRect.contains(local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        if browserFlankContains(screenPoint) { return nil }
        // Pass clicks through to browser tabs / menu bar unless expanded over the pill.
        guard isExpandedProvider() else { return nil }
        let local = convert(point, from: superview)
        if isInTabEar(at: local) { return nil }
        guard interactiveRectsLocal().contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    /// Screen-space rect of the interactive pill body (for click capture when expanded).
    func pillScreenRect() -> CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(pillHitRect())
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

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if interactiveRectsLocal().contains(where: { $0.contains(local) }) {
            onPillEngaged()
        }
        super.mouseDown(with: event)
    }

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

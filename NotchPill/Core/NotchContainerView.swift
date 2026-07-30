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
    var onPillEngaged: () -> Void = {}
    var onSpacePressed: () -> Void = {}
    var onDragTargetingChanged: (Bool) -> Void = { _ in }
    var onDropFiles: ([URL]) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?
    private var isHoveringHot = false
    private var lastHitVerdict: Bool?

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

    /// Slack applied to the interactive rects, so a control flush against the
    /// pill's edge is still clickable a hair outside it. Applied by *both*
    /// `isPointOnInteractivePill` and `hitTest` — see `acceptsLocalPoint`.
    private static let hitSlack: CGFloat = 2

    /// The single hit rule. `updateMousePassthrough` (via
    /// `isPointOnInteractivePill`) decides whether the window accepts the event
    /// at all, and `hitTest` decides which view receives it — so they have to
    /// answer identically. They previously did not: the passthrough check grew
    /// the rects by 2pt and `hitTest` used them exact, leaving a 2pt band around
    /// every edge where the window swallowed a click and then routed it nowhere.
    /// The peek's trailing controls sit ~8pt from that edge, which is how the ✕
    /// ended up feeling unreliable.
    private func acceptsLocalPoint(_ local: NSPoint) -> Bool {
        let verdict = Self.accepts(
            local,
            bounds: bounds,
            notchWidth: metrics.notchWidth,
            notchHeight: metrics.notchHeight,
            expanded: isExpandedProvider(),
            collapsedSize: collapsedContentSizeProvider(),
            expandedSize: expandedContentSizeProvider())
        logHitVerdict(local, verdict)
        return verdict
    }

    /// The rule itself, with the view's state passed in.
    ///
    /// Extracted so the invariant both callers depend on — that the passthrough
    /// check and `hitTest` answer *identically* — is pinned by a test rather
    /// than by the two implementations happening to agree. They once did not,
    /// and the 2pt band it left is what made the peek's ✕ feel unreliable.
    static func accepts(_ local: NSPoint,
                        bounds: CGRect,
                        notchWidth: CGFloat,
                        notchHeight: CGFloat,
                        expanded: Bool,
                        collapsedSize: CGSize,
                        expandedSize: CGSize) -> Bool {
        let rects = interactiveRects(bounds: bounds,
                                     notchWidth: notchWidth, notchHeight: notchHeight,
                                     expanded: expanded,
                                     collapsedSize: collapsedSize,
                                     expandedSize: expandedSize)
        if expanded, inTabEar(local, bounds: bounds,
                              notchWidth: notchWidth, notchHeight: notchHeight) {
            return false
        }
            // The pill's own pixels win over the browser flank. The flank rects run
            // 52pt below the menu bar (for unified tab bars), and an expanded peek is
            // wider than the notch — so a blanket flank rejection here made the peek's
            // trailing controls (reply ↰, ✕) unclickable and dropped the click onto
            // the browser behind, pausing whatever was playing. `isInTabEar` already
            // protects the strip beside the notch, which is what tabs actually need.
        let slack = hitSlack
        return rects.contains { $0.insetBy(dx: -slack, dy: -slack).contains(local) }
    }

    /// Pure form of `interactiveRectsLocal`.
    static func interactiveRects(bounds: CGRect,
                                 notchWidth: CGFloat, notchHeight: CGFloat,
                                 expanded: Bool,
                                 collapsedSize: CGSize,
                                 expandedSize: CGSize) -> [CGRect] {
        let w = bounds.width, h = bounds.height
        guard expanded else {
            return [CGRect(x: (w - collapsedSize.width) / 2, y: h - collapsedSize.height,
                           width: collapsedSize.width, height: collapsedSize.height)]
        }
        let pw = min(expandedSize.width, w)
        return [CGRect(x: (w - pw) / 2, y: 0, width: pw, height: max(0, h - notchHeight)),
                CGRect(x: (w - notchWidth) / 2, y: h - notchHeight,
                       width: notchWidth, height: notchHeight)]
    }

    /// Pure form of `isInTabEar`.
    static func inTabEar(_ local: NSPoint, bounds: CGRect,
                         notchWidth: CGFloat, notchHeight: CGFloat) -> Bool {
        let w = bounds.width, h = bounds.height
        let notchLeft = (w - notchWidth) / 2
        let left = CGRect(x: 0, y: h - notchHeight, width: notchLeft, height: notchHeight)
        let right = CGRect(x: notchLeft + notchWidth, y: h - notchHeight,
                           width: w - (notchLeft + notchWidth), height: notchHeight)
        return left.contains(local) || right.contains(local)
    }

    /// Traces the hit rule (NOTCHPILL_LOG_HIT=1). "The button sometimes doesn't
    /// take the click" is invisible from outside — the window silently declining
    /// the event and a control simply being missed look identical. Logs only when
    /// the verdict flips, so hovering a control at 60Hz doesn't flood.
    private static let logHit = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HIT"] == "1"
    private func logHitVerdict(_ local: NSPoint, _ verdict: Bool) {
        guard Self.logHit, verdict != lastHitVerdict else { return }
        lastHitVerdict = verdict
        let rects = interactiveRectsLocal()
            .map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" }
            .joined(separator: " ")
        print("HIT \(verdict ? "ACCEPT" : "reject") at (\(Int(local.x)),\(Int(local.y))) "
            + "bounds=\(Int(bounds.width))×\(Int(bounds.height)) "
            + "tabEar=\(isInTabEar(at: local)) rects=\(rects)")
    }

    func isPointOnInteractivePill(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return acceptsLocalPoint(convert(windowPoint, from: nil))
    }

    func isMouseInHotZone() -> Bool {
        guard let window else { return false }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return hotRect.contains(local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Pass clicks through to browser tabs / menu bar unless expanded over the pill.
        guard isExpandedProvider() else { return nil }
        guard acceptsLocalPoint(convert(point, from: superview)) else { return nil }
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

    /// Same reason as `PassthroughHostingView`: the first click on an
    /// inactive accessory window must reach the control, not be spent
    /// activating the app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

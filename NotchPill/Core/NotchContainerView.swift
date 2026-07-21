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
    var onSpacePressed: () -> Void = {}
    /// Called when a valid file drag begins/ends hovering the drop area.
    var onDragTargetingChanged: (Bool) -> Void = { _ in }
    /// Called with dropped file URLs.
    var onDropFiles: ([URL]) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?
    private var isHoveringHot = false
    /// Suppresses enter/exit callbacks while the tracking area is being rebuilt.
    private var suppressTrackingCallbacks = false

    init(metrics: NotchMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The physical notch cutout at the top of the window.
    private var physicalNotchRect: CGRect {
        let w = bounds.width
        let h = bounds.height
        let nw = metrics.notchWidth
        return CGRect(x: (w - nw) / 2, y: h - metrics.notchHeight,
                      width: nw, height: metrics.notchHeight)
    }

    /// True for the full menu-bar height at the top of the window — always click-through.
    private func isMenuBarStrip(_ local: NSPoint) -> Bool {
        local.y >= bounds.height - metrics.notchHeight
    }

    /// Hot rect in this view's (non-flipped, bottom-left origin) coordinates.
    /// Excludes the menu-bar strip so status items stay clickable; only the pill
    /// body and collapsed preview row below the notch receive pointer events.
    var hotRect: CGRect {
        let w = bounds.width
        let h = bounds.height
        let nw = metrics.notchWidth
        if isExpandedProvider() {
            let pw = min(metrics.expandedWidth, w)
            return CGRect(x: (w - pw) / 2, y: 0, width: pw,
                          height: max(0, h - metrics.notchHeight))
        }
        // Collapsed: center notch cutout + preview chip row beneath it.
        let notch = CGRect(x: (w - nw) / 2, y: h - metrics.notchHeight, width: nw, height: metrics.notchHeight)
        let previewWidth = min(metrics.expandedWidth, max(nw + 24, metrics.collapsedPreviewSize(chipCount: 3).width))
        let chipHeight = max(0, metrics.collapsedPreviewSize(chipCount: 1).height - metrics.notchHeight)
        let chipRow = CGRect(x: (w - previewWidth) / 2, y: h - metrics.notchHeight - chipHeight,
                             width: previewWidth, height: chipHeight)
        return notch.union(chipRow)
    }

    /// Whether the pointer is currently inside the hot zone (notch or pill).
    func isMouseInHotZone() -> Bool {
        guard let window else { return false }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return hotRect.contains(local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Never intercept the menu bar strip — status items must stay clickable.
        if isMenuBarStrip(local) { return nil }
        guard hotRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    /// Rebuilds tracking and re-syncs hover from the live pointer position.
    /// Tracking-area teardown can spuriously fire `mouseExited` while the pointer
    /// is still over the pill, so we derive hover from geometry instead.
    func refreshTracking() {
        suppressTrackingCallbacks = true
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        suppressTrackingCallbacks = false
        syncHoverState()
    }

    private func syncHoverState() {
        let inside = isMouseInHotZone()
        if inside, !isHoveringHot {
            isHoveringHot = true
            onHotEntered()
        } else if !inside, isHoveringHot {
            isHoveringHot = false
            onHotExited()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseEntered(with event: NSEvent) { syncHoverState() }
    override func mouseExited(with event: NSEvent) { syncHoverState() }
    override func mouseMoved(with event: NSEvent) { syncHoverState() }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        switch event.keyCode {
        case 49: onSpacePressed()
        case 124: break // handled by HotZoneKeyMonitor local monitor
        case 123: break
        default: super.keyDown(with: event)
        }
    }

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

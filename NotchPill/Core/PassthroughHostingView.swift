import AppKit
import SwiftUI

/// NSHostingView that only participates in hit-testing over the interactive pill.
/// Prevents the full-size SwiftUI surface from swallowing clicks meant for browser tabs.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Screen-coordinate point test — return true only where pill controls should receive clicks.
    var acceptsScreenPoint: (NSPoint) -> Bool = { _ in false }

    /// Preserve SwiftUI's transparent top region. Without this, AppKit can
    /// flatten the whole hosting view to black, hiding the intentional notch
    /// cutout and making the overlay look like a wide rectangular banner.
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // The window drives the size here; the hosting view must not.
        //
        // By default an NSHostingView publishes its SwiftUI content's intrinsic
        // size to the window as constraints, and the window then resists
        // shrinking below it. `applyWindowFrame` sets an origin and a size in
        // one call, and AppKit applied the origin while refusing the shrink:
        // after a wide caption peek collapsed, the window kept its 1059pt width
        // at the *narrow* layout's origin, so its centre sat ~320pt right of
        // the notch and the pill drew there — visibly shifted right for about a
        // second until the next frame update corrected it.
        //
        // Invisible until captions made the width swing from ~389 to ~1058; the
        // pill's width barely moved before that, so the same lag shifted it by
        // a pixel or two.
        sizingOptions = []
    }

    /// Deliver the *first* click to the control under it.
    ///
    /// AppKit's default is to spend the first mouse-down on a non-active
    /// window activating it, and never pass it to the view. NotchPill is an
    /// accessory app, so it is almost never the active one — which made the
    /// peek's ✕ and reply button work only when it happened to be frontmost
    /// already, and look flaky the rest of the time. The pill is a transient
    /// overlay you click *at*, not a document window you focus first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        guard acceptsScreenPoint(screenPoint) else { return nil }
        return super.hitTest(point)
    }
}

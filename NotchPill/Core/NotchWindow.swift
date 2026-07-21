import AppKit

/// A borderless, non-activating floating panel over the notch.
/// Sits **below** the menu bar so status items and browser tabs stay clickable;
/// hover is detected via screen-space polling instead of window hit-testing.
final class NotchWindow: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // Above normal windows so the pill renders in the notch; tab flanks use
        // ignoresMouseEvents + hit-test pass-through (see NotchGeometry.browserFlankRects).
        level = .statusBar + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Borderless panels are non-key by default; allow key only so SwiftUI controls
    // (buttons) can receive clicks without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

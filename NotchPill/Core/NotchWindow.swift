import AppKit

/// A borderless, non-activating floating panel that sits above the menu bar and
/// never steals focus from the frontmost app.
final class NotchWindow: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // Above the menu bar so the pill renders in the notch; menu bar flanks stay
        // clickable via hit-test pass-through in NotchContainerView.
        level = .statusBar + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // Appear on every Space, stay put during Exposé/full-screen transitions.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Borderless panels are non-key by default; allow key only so SwiftUI controls
    // (buttons) can receive clicks without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
